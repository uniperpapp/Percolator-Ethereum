// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Types} from "./libraries/Types.sol";
import {RiskEngine} from "./libraries/RiskEngine.sol";
import {Constants} from "./libraries/Constants.sol";
import {SolvencyProof} from "./libraries/SolvencyProof.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IMatcher} from "./interfaces/IMatcher.sol";

/// @title PerpMarket
/// @notice One isolated, coin-margined perpetual-futures market. Deployed as an
///         EIP-1167 clone by PerpFactory; holds all storage. The chain-agnostic
///         math lives in the RiskEngine / SolvencyProof / PerpMath libraries.
///
/// DESIGN (docs/DESIGN.md):
///  - LAZY ON-DEMAND ACCRUAL: `_accrueMarket()` runs inside any user tx that needs
///    fresh state; per-account A/K/F settles in `_touch()`. Idle / zero-OI markets
///    cost nothing — no continuous crank (the L1 enabler).
///  - Master invariant `V >= C_tot + I` asserted at the end of every mutating fn.
///  - Coin-margined: collateral == the traded ERC-20; PnL denominated in that token.
///  - ERC-20 safety: SafeERC20 + balanceAfter-balanceBefore accounting (fee-on-transfer
///    / rebasing tokens), nonReentrant + checks-effects-interactions on every payout.
///
/// MILESTONE 1 (this commit): collateral custody (deposit/withdraw), account lifecycle,
///   equity/margin checks, §1.6 solvency proof validated at init. Positions, lazy A/K/F
///   accrual, the matcher, and liquidation arrive in Milestone 2 (trade/liquidate revert).
contract PerpMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- config & wiring (set once via initialize) ---
    Types.MarketConfig public config;
    IOracleAdapter public oracle;
    IMatcher public matcher;
    address public factory;
    address public admin;
    bool private _initialized;

    // --- engine state ---
    Types.Globals internal g;
    mapping(uint256 => Types.Account) internal accounts;
    mapping(uint256 => address) public positionOwner;
    uint256 public nextPositionId = 1;

    event Initialized(address indexed collateral, address indexed admin);
    event AccountOpened(uint256 indexed positionId, address indexed owner);
    event Deposited(
        uint256 indexed positionId, address indexed from, uint256 amount, uint256 credited
    );
    event Withdrawn(uint256 indexed positionId, address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotImplemented();
    error NotInitialized();
    error InvalidConfig();
    error SolvencyEnvelopeFailed();
    error ZeroAmount();
    error ZeroAddress();
    error NoSuchAccount();
    error NotPositionOwner();
    error InsufficientEquity(int256 available, uint256 requested);
    error VaultBalanceShort();
    error AmountTooLarge();

    modifier onlyInit() {
        if (!_initialized) revert NotInitialized();
        _;
    }

    modifier onlyOwnerOf(uint256 positionId) {
        if (!accounts[positionId].materialized) revert NoSuchAccount();
        if (positionOwner[positionId] != msg.sender) revert NotPositionOwner();
        _;
    }

    /// @notice Clone initializer (EIP-1167 clones have no constructor).
    ///         Validates config shape (spec §1.5) and the exact §1.6 solvency envelope.
    function initialize(
        Types.MarketConfig calldata cfg,
        IOracleAdapter oracle_,
        IMatcher matcher_,
        address admin_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (cfg.collateralToken == address(0) || admin_ == address(0)) revert ZeroAddress();
        _validateConfig(cfg);
        _initialized = true;

        config = cfg;
        oracle = oracle_;
        matcher = matcher_;
        admin = admin_;
        factory = msg.sender;

        // Each side's A starts at ADL_ONE ("1.0").
        g.longSide.a = uint128(Constants.ADL_ONE);
        g.shortSide.a = uint128(Constants.ADL_ONE);
        g.slotLast = uint64(block.timestamp);

        emit Initialized(cfg.collateralToken, admin_);
    }

    // ---------------------------------------------------------------------
    // Config validation (spec §1.5 shape + §1.6 exact solvency envelope)
    // ---------------------------------------------------------------------
    function _validateConfig(Types.MarketConfig calldata c) internal pure {
        // shape (spec §1.5)
        if (!(c.minNonzeroMmReq > 0 && c.minNonzeroMmReq < c.minNonzeroImReq)) {
            revert InvalidConfig();
        }
        if (c.maintenanceBps > Constants.BPS_DENOM) revert InvalidConfig();
        if (!(c.maintenanceBps <= c.initialMarginBps && c.initialMarginBps <= Constants.BPS_DENOM))
        {
            revert InvalidConfig();
        }
        if (c.tradingFeeBps > Constants.BPS_DENOM) revert InvalidConfig();
        if (c.liquidationFeeBps > Constants.BPS_DENOM) revert InvalidConfig();
        if (c.minLiquidationAbs > c.liquidationFeeCap) revert InvalidConfig();
        if (c.maxPriceMoveBpsPerSec == 0 || c.maxAccrualDtSec == 0) revert InvalidConfig();
        if (!(c.warmupMaxSec > 0 && c.warmupMinSec <= c.warmupMaxSec)) revert InvalidConfig();

        // Funding-accrual overflow guard (spec §1.6). The K/F accumulators must not
        // overflow over the market lifetime: ADL_ONE * MAX_ORACLE_PRICE * funding * dt
        // must fit a signed 256-bit word. (On Solana this was the tight i128 bound;
        // int256 gives vast headroom, but we keep the invariant explicit.) The checked
        // multiply below reverts on 256-bit overflow; the require enforces the int256 fit.
        uint256 fundingTerm = uint256(c.maxAbsFundingE9PerSec) * uint256(c.maxAccrualDtSec);
        uint256 envBound = Constants.ADL_ONE * Constants.MAX_ORACLE_PRICE * fundingTerm;
        if (envBound > uint256(type(int256).max)) revert InvalidConfig();

        // §1.6 exact per-risk-notional solvency envelope (the self-neutral-siphon boundary)
        SolvencyProof.Params memory pp = SolvencyProof.Params({
            maxPriceMoveBpsPerSec: c.maxPriceMoveBpsPerSec,
            maxAccrualDtSec: c.maxAccrualDtSec,
            maxAbsFundingE9PerSec: c.maxAbsFundingE9PerSec,
            maintenanceBps: c.maintenanceBps,
            liquidationFeeBps: c.liquidationFeeBps,
            minLiquidationAbs: c.minLiquidationAbs,
            liquidationFeeCap: c.liquidationFeeCap,
            minNonzeroMmReq: c.minNonzeroMmReq
        });
        if (!SolvencyProof.validate(pp)) revert SolvencyEnvelopeFailed();
    }

    // ---------------------------------------------------------------------
    // Collateral custody — Milestone 1
    // ---------------------------------------------------------------------

    /// @notice Open a fresh account owned by msg.sender (no deposit). Returns its id.
    function openAccount() public onlyInit returns (uint256 positionId) {
        positionId = nextPositionId++;
        Types.Account storage a = accounts[positionId];
        a.materialized = true;
        a.lastFeeTs = uint64(block.timestamp);
        positionOwner[positionId] = msg.sender;
        emit AccountOpened(positionId, msg.sender);
    }

    /// @notice Deposit collateral. `positionId == 0` opens a new account first.
    ///         Uses balanceAfter-balanceBefore so fee-on-transfer/rebasing tokens credit
    ///         only what actually arrived. Deposit only increases equity → no health check.
    function deposit(uint256 positionId, uint256 amount)
        external
        onlyInit
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();
        if (positionId == 0) {
            positionId = openAccount();
        } else {
            if (!accounts[positionId].materialized) revert NoSuchAccount();
            if (positionOwner[positionId] != msg.sender) revert NotPositionOwner();
        }

        IERC20 token = IERC20(config.collateralToken);
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 credited = token.balanceOf(address(this)) - balBefore;
        if (credited == 0) revert ZeroAmount();
        // Guard the uint128 capital cast (and the per-account checked add). The spec's
        // engine-units MAX_VAULT_TVL cap is reintroduced in Milestone 2 once token ->
        // engine-unit price normalization exists; raw 18-decimal token wei is not 1:1
        // with engine quote-atom units, so it must not be compared against that bound here.
        if (credited > type(uint128).max) revert AmountTooLarge();

        // effects
        Types.Account storage a = accounts[positionId];
        a.capital += uint128(credited);
        g.cTot += credited;
        g.vault += credited;

        RiskEngine.assertConservation(g.vault, g.cTot, g.insurance);
        emit Deposited(positionId, msg.sender, amount, credited);
        return positionId;
    }

    /// @notice Withdraw collateral to `to`. Checks the withdrawal equity lane (haircut
    ///         applied to matured PnL) and IM health. CEI: state mutated before transfer,
    ///         nonReentrant, conservation re-asserted.
    function withdraw(uint256 positionId, uint256 amount, address to)
        external
        onlyInit
        nonReentrant
        onlyOwnerOf(positionId)
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        _accrueMarket();
        _touch(positionId);

        Types.Account storage a = accounts[positionId];
        uint256 residual_ = RiskEngine.residual(g.vault, g.cTot, g.insurance);
        int256 eqWithdraw = RiskEngine.withdrawEquity(
            a.capital, a.pnl, a.reservedPnl, a.feeCredits, residual_, g.pnlMaturedPosTot
        );

        // Withdrawal healthy iff Eq_withdraw_raw - amount >= IM_req. For M1 every account
        // is flat (no position) so IM_req == 0; the position-aware IM check lands in M2.
        if (eqWithdraw < 0 || uint256(eqWithdraw) < amount) {
            revert InsufficientEquity(eqWithdraw, amount);
        }
        // M1: withdrawable value is backed by capital. Guard the capital reduction.
        if (uint256(a.capital) < amount) {
            revert InsufficientEquity(int256(uint256(a.capital)), amount);
        }

        // effects (CEI)
        a.capital -= uint128(amount);
        g.cTot -= amount;
        g.vault -= amount;

        // interaction
        IERC20(config.collateralToken).safeTransfer(to, amount);

        RiskEngine.assertConservation(g.vault, g.cTot, g.insurance);
        emit Withdrawn(positionId, to, amount);
    }

    // ---------------------------------------------------------------------
    // Views over the safety core
    // ---------------------------------------------------------------------

    function residual() external view returns (uint256) {
        return RiskEngine.residual(g.vault, g.cTot, g.insurance);
    }

    function haircut() external view returns (uint256 num, uint256 den) {
        uint256 r = RiskEngine.residual(g.vault, g.cTot, g.insurance);
        Types.Ratio memory h = RiskEngine.haircutRatio(r, g.pnlMaturedPosTot);
        return (h.num, h.den);
    }

    function globals() external view returns (Types.Globals memory) {
        return g;
    }

    function getAccount(uint256 positionId) external view returns (Types.Account memory) {
        return accounts[positionId];
    }

    // ---------------------------------------------------------------------
    // Lazy accrual / settlement — full bodies land in Milestone 2
    // ---------------------------------------------------------------------

    /// @dev MILESTONE 2: port spec §5.3 accrue_market_to with a per-SECOND price-move
    ///      envelope; bundle the pull-oracle update into the caller's tx. For M1 there are
    ///      no positions/OI, so accrual is a no-op beyond the conservation guard.
    function _accrueMarket() internal {
        RiskEngine.assertConservation(g.vault, g.cTot, g.insurance);
    }

    /// @dev MILESTONE 2: settle this account's A/K/F deltas + advance warmup, then
    ///      re-snapshot. For M1 (no positions) there is nothing to settle.
    function _touch(uint256 positionId) internal {
        // no-op until positions exist (Milestone 2)
        positionId;
    }

    // ---------------------------------------------------------------------
    // Trading / liquidation — Milestone 2 (revert until implemented)
    // ---------------------------------------------------------------------

    function trade(
        uint256,
        /*positionId*/
        int256 /*sizeQ*/
    )
        external
        view
        onlyInit
    {
        revert NotImplemented();
    }

    function liquidate(
        uint256 /*positionId*/
    )
        external
        view
        onlyInit
    {
        revert NotImplemented();
    }
}
