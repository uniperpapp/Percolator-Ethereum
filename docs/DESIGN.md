# Percolator-Ethereum — Design

This document is the engineering source-of-truth for the Ethereum L1 port of the
Percolator perp risk engine. It captures the architecture, the Solana→EVM mapping,
the L1-specific decisions, and the porting plan for the risk engine.

Reference sources studied (Solana originals, not copied):
`percolator/spec.md` (normative engine spec), `percolator/src/percolator.rs` (engine),
`percolator-prog/src/percolator.rs` (on-chain program), `percolator-matcher` (the
oracle-anchored quoter), `percolator-sdk/src/math` (trading math).

---

## 1. Core thesis

Percolator is **not** an AMM and **not** a shared-LP house. It is a coin-margined
perp **risk ledger** that prices everything at an external "effective engine price,"
enforces one master invariant `V ≥ C_tot + I`, and makes positive PnL a **junior**
claim on `Residual = V − (C_tot + I)` via a single global haircut `H`.

All economically load-bearing logic (H, lazy A/K/F indices, warmup admission, the
per-step price envelope, the init-time solvency proof) is **chain-agnostic integer
math** that ports to Solidity *more* cleanly than it ran on Solana — EVM's native
256-bit word deletes the entire `wide_math`/`i128` emulation layer.

## 2. The five mechanisms (and their port status)

| Mechanism | Spec | Port status |
|---|---|---|
| Master invariant `V ≥ C_tot + I` | §0/§2.2 | ✅ `RiskEngine.assertConservation` |
| **H** — haircut; positive PnL junior to `Residual` | §3 | ✅ `RiskEngine.haircutRatio` / `effectiveMaturedPnl` |
| Equity lanes (withdraw / maintenance / net) | §3 | ✅ `RiskEngine.withdrawEquity` / `maintenanceEquity` / `netEquity` |
| Risk notional (ceil) + margin | §1.2/§7 | ✅ `RiskEngine.riskNotional` / `maintenanceReq` / `initialReq` |
| Per-risk-notional **solvency proof** (in seconds) | §1.6 | ✅ `SolvencyProof.validate`, called in `initialize` |
| Collateral custody (deposit/withdraw) | §8 | ✅ `PerpMarket` (SafeERC20 + balance-delta + nonReentrant/CEI) |
| **A/K/F** accrual math (mark→K, funding→F, staircase) | §5.3/§1.7 | ✅ `Accrual` (`accrue`, `staircaseNext`) |
| **A/K/F** per-account settlement (effective pos, pnl delta) | §5.1/§5.2 | ✅ `Settlement` (`effectivePosQ`, `kfPnlDelta`) |
| A/K/F wired into market (`_accrueMarket` + `_touch`) | §5/§6 | ⏳ milestone 2 (trade/liquidate paths) |
| **Warmup / admission** (`admit_h_min > 0`) | §4.3 | ⏳ milestone 2 (two-bucket reserve) |
| Liquidation + ADL socialization | §5.4/§7 | ⏳ milestone 2 |

### Margining unit convention (decided while porting §5)

The engine core uses **linear, quote-denominated** mark PnL: `K_side += A_side·ΔP` and
`pnl_delta = basis·ΔP / POS_SCALE` (= base_position · ΔP). It is unit-agnostic — the
"quote token" is whatever the vault holds. Coin-margining means **the vault token is the
traded coin**, so PnL and collateral are denominated in that coin. The SDK's display
helper `PerpMath.markPnl` uses the inverse form `(oracle−entry)·|pos|/oracle` (PnL measured
in the base coin); that is a *front-end display* convention, not the engine's internal
accounting. The engine port (`Accrual`/`Settlement`) faithfully reproduces the Rust engine's
linear K-model. The exact price representation fed to the engine (and thus the precise
coin-vs-USD margining semantics) is finalized when the `OracleAdapter` is wired — the engine
math does not change.

### K/F width

`SideState.k` / `fNum` are `int256` here (the spec uses `i128` only because Solana lacks a
native 256-bit word). All intermediates use `int256`; persistent adds are checked (revert on
overflow = the spec's "fails conservatively"). EVM's native word removes the i128 overflow
pressure the spec's §1.6 budget was partly designed around.

### Milestone 1 notes

- **§1.6 proof port.** `SolvencyProof.validate` is a faithful port of the Rust
  `validate_exact_solvency_envelope` (engine `percolator.rs:1571–1941`): the analytic
  region decomposition (full-margin special case → floor region → linear / capped-fee
  tail bounds) plus bounded interval bisection with monotonicity certificates. Bounded
  work (≤96 intervals, ≤4096 steps); measured ~6k–15k gas on the pass path, cheap enough
  for the market-creation tx. It is re-established symbolically (Halmos/Certora) in M4.
- **CAVEAT — per-second rate granularity.** `maxPriceMoveBpsPerSec` is an integer bps
  per second (the spec used bps per 400 ms slot). The minimum nonzero rate (1 bps/s) is
  coarse over long `maxAccrualDtSec` windows (e.g. 3600 bps over 1 h). If finer control
  is needed at calibration, switch the rate unit to an e9-scaled fixed point (and divide
  by the scale in the envelope) — a localized change to `Types.MarketConfig` +
  `SolvencyProof` + the M2 accrual check. The proof math itself is unit-agnostic.

## 3. Smart-contract architecture

- **PerpFactory** (singleton, Safe + timelock): deploys EIP-1167 clones; one-tx market
  creation; pulls LP + insurance seeds (Permit2) and escrows a slashable creator bond.
- **PerpMarket** (one clone per market, holds storage): the engine wrapper. Globals in a
  packed struct; accounts in `mapping(uint256 => Account)`. A market-wide price move
  mutates ONLY `Globals` (lazy A/K/F) — it never iterates accounts.
- **RiskEngine / PerpMath** (pure libraries): the chain-agnostic math (the moat).
- **OracleAdapter**: capped-staircase wrapper producing the *effective engine price* from
  a tiered source; keeps raw target separate from effective price (spec §1.7).
- **Matcher**: default oracle-anchored fixed-spread quoter (`exec = oracle·(1 ± spread)`);
  pluggable RFQ/router. (Confirmed: Percolator's "vAMM" is this, not `xy=k`.)
- **LpVault / InsuranceFund**: ERC-4626 (virtual shares); LP is the trading counterparty,
  insurance is the first-loss buffer.

### Lazy / on-demand accrual (the L1 enabler)
1. `accrueMarket()` runs **inside the user's own tx** (trade/withdraw/liquidate); it mutates
   only `Globals` (mark→K, funding→F, advance `pLast`/`slotLast`), gated by the §5.3
   per-second price-move envelope. The interacting user funds their own accrual.
2. Per-account settlement is lazy in `_touch(positionId)` — O(1), only paid by touched accounts.
3. Idle / zero-OI markets cost **$0** (no crank).
4. Liquidation is the only mandatory keeper action; bots discover candidates off-chain and
   the contract re-validates `Eq_net_i ≤ MM_req_i` on-chain (anyone can liquidate).
5. A low-frequency **heartbeat** fires only as `block.timestamp − slotLast` nears
   `maxAccrualDtSec` so an idle exposed market never breaches its accrual window.

## 4. Solana → EVM mapping (key rows)

| Solana | EVM | Note |
|---|---|---|
| 1.75MB slab account | `PerpMarket` clone + packed `Globals` | storage-write-minimizing aggregates carry over |
| `[Account; N]` + bitmap + tiers | `mapping(uint256 => Account)` | tiers vanish; mappings grow lazily |
| `u128/i128` + wide-math shims | native `uint256/int256` + `FixedPointMath.mulDiv` | deletes ~3k LOC |
| slot time (~400ms) | `block.timestamp` (sec) | **re-derive every budget; re-prove §1.6** |
| rent / slab recovery | gas + EIP-3529 refunds | drop recovery machinery |
| permissionless crank | lazy on-demand accrual + searcher liquidations + heartbeat | biggest model change |
| PDA vault + `invoke_signed` | contract custody + `SafeERC20` | **`balanceAfter−balanceBefore`** for fee-on-transfer/rebasing |
| (no reentrancy guards) | `nonReentrant` + checks-effects-interactions | new EVM threat class |
| Pyth push | Pyth **pull** bundled in-tx | removes standalone-oracle-tx sandwich |
| byte-parsed DEX | Uniswap `observe()` / `slot0()` | native TWAP |
| position = Token-2022 NFT + hook | **plain mapping** (no ERC-721 on L1) | saves 15–40k gas/open; coin-margined needs no transferability |
| Kani proofs | Foundry invariants + Halmos + Certora + differential vs Rust | real verification downgrade — disclose it |
| admin from instruction data | `admin = msg.sender` | do NOT port the footgun |

## 5. Cold-start oracle (tiered)

| Tier | Assets | Source | OI cap |
|---|---|---|---|
| A | majors | **Chainlink Data Feeds** (free reads; 0.5% dev / 1h heartbeat) | highest |
| B | mid-caps | **Pyth / RedStone pull** (bundled in user tx) | medium |
| C | long-tail cold-start | **Uniswap v3 geomean TWAP** (≥30-min window) + capped staircase + warmup + liquidity-gated OI cap | lowest |

- **Graduation** C→B→A as liquidity grows / a pull feed agrees within band / a Chainlink feed lists.
  Monotone (no reversal except a divergence circuit-breaker).
- **Why L1:** the multi-block TWAP defense for Tier C only holds because L1 has decentralized,
  RANDAO-randomized proposers (no single party orders consecutive blocks). This is the decisive
  reason for the L1-only mandate.
- **OEV recapture:** liquidation OEV → insurance fund via Chainlink SVR / Pyth Express Relay (60–90%).

## 6. Risk-engine porting rules

- **Rounding is load-bearing:** floor for payouts, **ceil** for risk notional & fees,
  floor-toward-(−∞) for the A/K/F `pnl_delta`. Solidity `/` truncates toward zero — wrong
  direction for negative numerators; handle those explicitly.
- **Keep checked arithmetic** (Solidity ≥0.8 reverts on overflow); `unchecked` only at
  spec-proven-bounded sites. Forbid `int256` min as the spec forbids `i128::MIN`.
- **First-port simplifications (disclose):** use spec §5.4 K-shift ADL (not the v12.20.6
  phantom-dust B-residual machinery); single internal `oracle±spread` matcher; no compute tiers.
- **Verification stack** (replaces Kani): Foundry invariants (sum payouts ≤ Residual;
  `V ≥ C_tot + I`; no self-slippage-as-margin; price cap fires before any K/F/P mutation;
  `h ∈ [0,1]`; ADL conserves quantity) + Halmos on pure helpers + Certora on the top invariants +
  **differential testing against the Rust engine** (bit-identical) + ≥2 audits + a public contest.

## 7. Out of scope / known risks

- **Regulatory:** permissionless, no-KYC, retail leveraged derivatives needs a legal opinion +
  geofencing + asset perimeter before mainnet (CFTC / Ooki-DAO precedent). Chain choice doesn't change this.
- **Gas-spike dependency:** the L1 case assumes sustained low base fees; the circuit breaker is the backstop.
- **Single-block manipulation** and ≥15%-staker/builder collusion remain — defended by TWAP window
  length, pool-depth OI caps, and graduating off raw TWAP before OI scales.
