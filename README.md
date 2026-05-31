# Percolator-Ethereum

> **Permissionless perpetual-futures launcher for Ethereum L1** — coin-margined, oracle-priced, isolated-per-market. A faithful Ethereum reimplementation of the [Percolator](https://github.com/dcccrypto/percolator) risk engine (original design by Anatoly Yakovenko), adapted for EVM and Ethereum L1's economics.

> **Status: pre-alpha, in active development.** This repository currently implements the chain-agnostic safety core (haircut `H`, conservation invariant, risk notional, margin) with tests; trading, accrual, oracle, vaults, and liquidation are in progress.

---

## What this is

Anyone can launch a leveraged perp market for an ERC-20 that has a Uniswap pool. The protocol is built around Percolator's risk engine, whose distinguishing property is the one every recently-exploited perp protocol lacked:

- **Senior principal, junior PnL.** Deposited collateral is senior and never haircut. Positive PnL is a **junior claim** on residual vault value via a single global haircut ratio `H = min(Residual, maturedPnL) / maturedPnL`, so the exchange can never pay out more than it holds (`V ≥ C_tot + I`).
- **Lazy `A/K/F` indices.** Mark moves, funding, and ADL overhang settle pro-rata via three global side indices; each account reconciles its share **only when touched**. No ADL queue, no per-account cranking.
- **Warmup admission.** Fresh positive PnL vests over time before it can be withdrawn — the core anti-oracle-manipulation defense.
- **Per-market isolation.** One engine + one LP vault + one insurance fund per market (EIP-1167 clone). A long-tail token's bad debt can never touch another market.

## Why Ethereum L1 (not an L2)

This design is unusually L1-friendly, and L1 is the *correct* venue for permissionless cold-start:

- **No continuous crank.** Accrual is lazy/on-demand — the trader funds their own accrual inside their own tx; idle/zero-OI markets cost **$0**. The recurring-crank cost that historically pushed perps to L2 doesn't exist here.
- **Real multi-block TWAP resistance.** Ethereum's decentralized, RANDAO-randomized block production makes multi-block Uniswap-TWAP manipulation exponentially improbable (a 15% staker proposes 3 consecutive blocks only ~2.7% of the time/epoch). A single-sequencer L2 orders every block and **collapses** that defense — which is exactly what a permissionless launcher pricing brand-new tokens off a TWAP cannot tolerate.
- **2026 gas makes it viable.** At sub-1-gwei base fees a lazy trade costs cents; the residual hazard is *gas spikes*, mitigated by the guardrails below.

### L1 guardrails (first-class protocol features)

1. Per-market **minimum position / minimum absolute liquidation fee** so liquidations stay gas-viable.
2. **OEV-funded liquidation incentive floor** (Chainlink SVR / Pyth Express Relay → insurance fund).
3. **Gas-spike circuit breaker** (widen margins / pause high-leverage opens above a base-fee threshold).
4. **Atomic pull-oracle bundling** + private orderflow (Flashbots Protect / MEV Blocker).
5. **Per-listing pool-depth / TWAP-window floor** with liquidity-gated OI caps.

## Architecture

```
PerpFactory (Safe + timelock owned)
  └─ createMarket(token, oracleCfg, marginBps, feeBps, seeds, bond)  → EIP-1167 clone
PerpMarket (one isolated clone per market; holds all storage)
  ├─ RiskEngine    (pure lib: H, A/K/F, warmup, liquidation, conservation)  ← the moat
  ├─ PerpMath      (pure lib: PnL, liq price, fees, fee split)
  ├─ OracleAdapter (capped staircase; tiered Chainlink / Pyth-RedStone / Uniswap-TWAP)
  ├─ Matcher       (oracle-anchored fixed-spread quoter; NOT a constant-product AMM)
  ├─ LpVault       (ERC-4626 counterparty)        ─ MILESTONE 3
  └─ InsuranceFund (ERC-4626 first-loss buffer)   ─ MILESTONE 3
```

Full design: [`docs/DESIGN.md`](docs/DESIGN.md).

## Solana → Ethereum mapping

Percolator's engine math is chain-agnostic; the work is in the runtime model. Key mappings (full table in [`docs/DESIGN.md`](docs/DESIGN.md)):

| Solana (Percolator) | Ethereum L1 (this repo) | Notes |
|---|---|---|
| 1.75 MB program-owned **slab** account per market | One **`PerpMarket`** clone + packed `Globals` struct | O(1) running aggregates carry over; a price move mutates only `Globals`, never iterates accounts |
| `[Account; N]` array + bitmap + size tiers | `mapping(uint256 => Account)` | mappings grow lazily; the 256/1024/4096 tiers disappear |
| `u128` / `i128` + hand-rolled 256-bit wide math | native `uint256` / `int256` + `FixedPointMath.mulDiv` | EVM's native 256-bit word **deletes ~3k lines** of emulation |
| slot time (~400 ms) | `block.timestamp` (seconds) | every budget re-derived in seconds; **§1.6 solvency proof re-run** for 12 s blocks |
| account rent + reclaim machinery | gas + EIP-3529 refunds | no rent; drop the recovery machinery |
| permissionless per-market **crank** loop | **lazy on-demand accrual** + searcher liquidations + low-freq heartbeat | biggest model change; idle markets cost $0 |
| PDA-owned vault ATA + `invoke_signed` SPL transfers | contract custody + `SafeERC20` | use `balanceAfter − balanceBefore` for fee-on-transfer / rebasing tokens |
| (no reentrancy guards — SVM prevents A→B→A) | `nonReentrant` + checks-effects-interactions | new EVM-only threat class |
| CPI to matcher (account-data side channel) | `IMatcher.price(...)` external call / internal lib | normal struct return |
| Pyth **push** (posted as an account) | Pyth **pull** bundled into the consuming tx | removes the standalone-oracle-tx sandwich surface |
| byte-offset DEX pool parsing (Raydium/Meteora) | Uniswap v3 `observe()` / `slot0()` | native, manipulation-resistant TWAP |
| position = Token-2022 NFT + transfer hook | **plain `Account` in a mapping** (no ERC-721 on L1) | saves ~15–40k gas/open; coin-margined needs no transferability |
| `InitMarket` admin taken from instruction data | `admin = msg.sender` | do **not** port the footgun |
| Kani formal proofs (~305) | Foundry invariants + Halmos + Certora + differential tests vs the Rust engine + audits | verification stack replacement |
| oracle "vAMM" = fixed-spread quoter | same: `Matcher` quotes `oracle × (1 ± spread)` | Uniswap is the **oracle + spot reference**, not the perp venue |

## Status / roadmap

| Milestone | Scope | State |
|---|---|---|
| 0 — Foundations | Foundry scaffold, fixed-point + rounding, constants, types, **safety-core math + tests** | ✅ |
| 1 — Custody + config | deposit/withdraw, account lifecycle, equity/margin lanes, reentrancy safety, **§1.6 solvency proof (seconds)** validated at init | ✅ |
| 2 — Accrual + trade + liquidate | lazy `accrueMarket`, A/K/F per-account settlement, matcher, oracle adapter, liquidation + ADL, warmup | ⏳ next |
| 3 — Vaults + factory | ERC-4626 LP + insurance, EIP-1167 factory, seeds + creator bond, fee split | ⏳ |
| 4 — Hardening | Foundry invariants, Halmos, differential tests vs the Rust engine, audits | ⏳ |

Implemented now: `Constants`, `FixedPointMath` (512-bit mulDiv), `Types`, `PerpMath`, `RiskEngine` (residual/conservation, `H`, effective matured PnL, risk notional, margin, equity lanes), **`SolvencyProof`** (the §1.6 bounded-breakpoint self-neutral-siphon proof, re-derived in seconds), and **`PerpMarket`** collateral custody (deposit/withdraw with `SafeERC20` + balance-delta accounting + `nonReentrant`/CEI, config + §1.6 validation at init). 67 passing tests including conservation fuzzing and a reentrancy attack. Trade/liquidate revert pending Milestone 2.

## Build & test

```bash
forge build
forge test -vvv
```

Requires [Foundry](https://book.getfoundry.sh/). `forge-std` is vendored as a submodule (`git clone --recurse-submodules`, or `git submodule update --init`).

**CI:** a GitHub Actions workflow (fmt + build + test) is staged at [`docs/ci-workflow.yml`](docs/ci-workflow.yml). To enable it, grant the `workflow` scope once and move it into place:

```bash
gh auth refresh -h github.com -s workflow
git mv docs/ci-workflow.yml .github/workflows/ci.yml && git commit -m "ci: enable workflow" && git push
```

## Acknowledgements & license

Risk-engine **design** adapted from [Percolator](https://github.com/dcccrypto/percolator) (engine by [Anatoly Yakovenko](https://github.com/aeyakovenko), Apache-2.0). This is an independent EVM reimplementation — no Solana/Rust source is copied. Licensed MIT (see [LICENSE](LICENSE)); the production license may move to BUSL-1.1 before mainnet.
