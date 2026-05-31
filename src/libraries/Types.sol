// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Types
/// @notice Storage layout for a single perp market. Replaces Percolator's Solana
///         "slab" (one big account) with packed Solidity structs + a mapping of
///         accounts. The O(1) running aggregates (cTot, pnl totals, oiEff, side
///         A/K/F, vault, insurance) are updated incrementally so a market-wide
///         price move mutates ONLY `Globals` — never iterates accounts (lazy A/K/F).
library Types {
    /// Per-side lazy index state (long / short).
    /// @dev K and F are int256 (the spec uses i128 because Solana lacks a native 256-bit
    ///      word; EVM is natively 256-bit, so we take the headroom and keep checked math).
    struct SideState {
        uint256 a; // A_side: position scaler, starts at ADL_ONE
        int256 k; // K_side: accumulated mark + ADL overhang per unit
        int256 fNum; // F_side_num: accumulated funding numerator
        uint64 epoch; // side reset epoch
        uint256 oiEffQ; // effective open interest on this side (base * POS_SCALE)
        uint64 storedPosCount; // number of stored nonzero positions on this side
    }

    /// Per-market global engine state (the "RiskEngine header").
    struct Globals {
        uint256 vault; // V
        uint256 cTot; // sum of senior principal
        uint256 insurance; // I
        uint256 pnlPosTot; // full positive PnL aggregate (g lane)
        uint256 pnlMaturedPosTot; // matured positive PnL (haircut denominator, h lane)
        SideState longSide;
        SideState shortSide;
        uint64 pLast; // last effective engine price (e6)
        uint64 fundPxLast; // funding reference price
        uint64 slotLast; // = block.timestamp at last accrual
        uint8 marketMode; // 0 = Live, 1 = Resolved
    }

    /// Per-account state, keyed by positionId.
    struct Account {
        uint256 capital; // C_i (senior principal)
        int256 pnl; // PNL_i
        uint256 reservedPnl; // R_i (warmup reserve; excluded from haircut denom)
        int256 basisPosQ; // signed base position * POS_SCALE
        uint256 aBasis; // A snapshot at last attach (re-anchored each trade)
        int256 kSnap; // K snapshot at last touch
        int256 fSnap; // F snapshot at last touch
        uint64 epochSnap; // side epoch at last touch
        int256 feeCredits; // <= 0 (local fee debt)
        uint64 lastFeeTs;
        bool materialized;
        // ---- two-bucket warmup reserve (spec §4.3) ----
        uint256 schedRemainingQ; // scheduled bucket (matures linearly)
        uint256 schedAnchorQ;
        uint64 schedStartTs;
        uint64 schedHorizon;
        uint256 schedReleaseQ;
        uint256 pendingRemainingQ; // pending bucket (does not mature while pending)
        uint64 pendingHorizon;
    }

    /// Immutable per-market configuration (set once at createMarket).
    /// Fields map 1:1 to the Percolator engine's RiskParams (spec §1.5), with
    /// every per-slot budget re-expressed PER SECOND for Ethereum L1.
    struct MarketConfig {
        address collateralToken; // coin-margined: collateral == the traded ERC-20
        uint16 initialMarginBps; // cfg_initial_bps; maxLeverage = 10000 / initialMarginBps
        uint16 maintenanceBps; // cfg_maintenance_bps (<= initialMarginBps)
        uint16 tradingFeeBps; // cfg_trading_fee_bps
        uint16 liquidationFeeBps; // cfg_liquidation_fee_bps
        uint64 maxPriceMoveBpsPerSec; // cfg_max_price_move_bps_per_sec (price-move envelope)
        uint64 maxAccrualDtSec; // cfg_max_accrual_dt_sec (max elapsed per accrual step)
        uint64 maxAbsFundingE9PerSec; // cfg_max_abs_funding_e9_per_sec
        uint64 warmupMinSec; // admit_h_min horizon (warmup vesting)
        uint64 warmupMaxSec; // admit_h_max horizon
        uint256 minLiquidationAbs; // cfg_min_liquidation_abs (L1 gas-viability floor)
        uint256 liquidationFeeCap; // cfg_liquidation_fee_cap
        uint256 minNonzeroMmReq; // cfg_min_nonzero_mm_req
        uint256 minNonzeroImReq; // cfg_min_nonzero_im_req
    }

    /// Haircut ratio expressed as an exact fraction (num/den), h in [0,1].
    struct Ratio {
        uint256 num;
        uint256 den;
    }
}
