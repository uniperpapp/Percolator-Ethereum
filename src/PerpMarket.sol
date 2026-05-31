// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "./libraries/Types.sol";
import {RiskEngine} from "./libraries/RiskEngine.sol";
import {Constants} from "./libraries/Constants.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IMatcher} from "./interfaces/IMatcher.sol";

/// @title PerpMarket
/// @notice One isolated, coin-margined perpetual-futures market. Deployed as an
///         EIP-1167 clone by PerpFactory; holds all storage. The chain-agnostic
///         math lives in the RiskEngine / PerpMath libraries.
///
/// DESIGN (docs/DESIGN.md):
///  - LAZY ON-DEMAND ACCRUAL: `_accrueMarket()` runs inside any user tx that needs
///    fresh state (trade/withdraw/liquidate); per-account A/K/F settles in `_touch()`.
///    Idle / zero-OI markets cost nothing — no continuous crank (the L1 enabler).
///  - Master invariant `V >= C_tot + I` asserted at the end of every mutating fn.
///  - Coin-margined: collateral == the traded ERC-20; PnL denominated in that token.
///
/// STATUS: scaffold. The safety core (RiskEngine: H haircut, conservation, risk
/// notional, margin) is implemented & tested. Deposit/withdraw/trade/liquidate,
/// lazy accrual, and warmup are the next milestones and currently revert.
contract PerpMarket {
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
    uint256 public nextPositionId = 1;

    event Initialized(address indexed collateral, address indexed admin);

    error AlreadyInitialized();
    error NotImplemented();

    /// @notice Clone initializer (EIP-1167 clones have no constructor).
    function initialize(
        Types.MarketConfig calldata cfg,
        IOracleAdapter oracle_,
        IMatcher matcher_,
        address admin_
    ) external {
        if (_initialized) revert AlreadyInitialized();
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
    // Views over the safety core (already implemented & tested)
    // ---------------------------------------------------------------------

    /// @notice Residual = V - (C_tot + I): value backing junior positive PnL.
    function residual() external view returns (uint256) {
        return RiskEngine.residual(g.vault, g.cTot, g.insurance);
    }

    /// @notice Current haircut ratio h (num/den) over matured positive PnL.
    function haircut() external view returns (uint256 num, uint256 den) {
        uint256 r = RiskEngine.residual(g.vault, g.cTot, g.insurance);
        Types.Ratio memory h = RiskEngine.haircutRatio(r, g.pnlMaturedPosTot);
        return (h.num, h.den);
    }

    function globals() external view returns (Types.Globals memory) {
        return g;
    }

    // ---------------------------------------------------------------------
    // MILESTONE 2 — lazy accrual: update ONLY globals (mark->K, funding->F,
    // advance pLast/slotLast) gated by the §5.3 per-SECOND price-move envelope,
    // then assert conservation. Per-account settlement is lazy, in _touch().
    // ---------------------------------------------------------------------
    function _accrueMarket() internal {
        // TODO(milestone-2): port spec §5.3 accrue_market_to with a per-second budget;
        // bundle the pull-oracle update (Pyth/RedStone) into the caller's tx.
        RiskEngine.assertConservation(g.vault, g.cTot, g.insurance);
    }

    // ---------------------------------------------------------------------
    // User entrypoints — MILESTONE 1/2 (revert until implemented)
    // ---------------------------------------------------------------------

    /// @notice Deposit collateral and (optionally) open/extend a position. MILESTONE 1.
    function deposit(
        uint256,
        /*positionId*/
        uint256 /*amount*/
    )
        external
        view
    {
        _mustExist();
        revert NotImplemented();
    }

    /// @notice Withdraw collateral / matured-and-released PnL (haircut applied). MILESTONE 1.
    function withdraw(
        uint256,
        /*positionId*/
        uint256 /*amount*/
    )
        external
        view
    {
        _mustExist();
        revert NotImplemented();
    }

    /// @notice Open/modify a position; filled at oracle +/- spread via the matcher. MILESTONE 2.
    function trade(
        uint256,
        /*positionId*/
        int256 /*sizeQ*/
    )
        external
        view
    {
        _mustExist();
        revert NotImplemented();
    }

    /// @notice Permissionless liquidation of an unhealthy account (oracle-mark close). MILESTONE 2.
    function liquidate(
        uint256 /*positionId*/
    )
        external
        view
    {
        _mustExist();
        revert NotImplemented();
    }

    function _mustExist() private view {
        require(_initialized, "uninit");
    }
}
