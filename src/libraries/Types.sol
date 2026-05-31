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
    struct SideState {
        uint128 a; // A_side: position scaler, starts at ADL_ONE
        int128 k; // K_side: accumulated mark + ADL overhang per unit
        int128 fNum; // F_side_num: accumulated funding numerator
        uint64 epoch; // side reset epoch
        uint128 oiEffQ; // effective open interest on this side (base * POS_SCALE)
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

    /// Per-account state, keyed by positionId. Packed to minimize SSTOREs.
    struct Account {
        uint128 capital; // C_i (senior principal)
        int128 pnl; // PNL_i
        uint128 reservedPnl; // R_i (warmup reserve; excluded from haircut denom)
        int128 basisPosQ; // signed base position * POS_SCALE
        uint128 aBasis; // A snapshot at last touch
        int128 kSnap; // K snapshot at last touch
        int128 fSnap; // F snapshot at last touch
        uint64 epochSnap; // side epoch at last touch
        int128 feeCredits; // <= 0 (local fee debt)
        uint64 lastFeeTs;
        bool materialized;
        // Two-bucket warmup reserve fields are added with the warmup milestone.
    }

    /// Immutable per-market configuration (set once at createMarket).
    struct MarketConfig {
        address collateralToken; // coin-margined: collateral == the traded ERC-20
        uint16 initialMarginBps; // maxLeverage = 10000 / initialMarginBps
        uint16 maintenanceBps;
        uint16 tradingFeeBps;
        uint16 liquidationFeeBps;
        uint64 maxPriceMoveBpsPerSec; // price-move envelope, per SECOND (L1: 12s blocks)
        uint64 maxAccrualDtSec; // max elapsed time per accrual step
        uint64 warmupMinSec; // admit_h_min horizon (warmup vesting)
        uint64 warmupMaxSec; // admit_h_max horizon
        uint256 minLiquidationFee; // absolute floor so liquidations stay gas-viable on L1
    }

    /// Haircut ratio expressed as an exact fraction (num/den), h in [0,1].
    struct Ratio {
        uint256 num;
        uint256 den;
    }
}
