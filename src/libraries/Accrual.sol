// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Constants} from "./Constants.sol";
import {FixedPointMath} from "./FixedPointMath.sol";
import {Types} from "./Types.sol";

/// @title Accrual
/// @notice Lazy market accrual (Percolator spec §5.3 + §1.7 staircase), ported from the
///         Rust engine's `accrue_market_to`, RE-EXPRESSED IN SECONDS for Ethereum L1.
///
/// @dev Called inside any user tx that needs fresh state (the trader funds their own
///      accrual). It mutates ONLY the two side accumulators and the price/slot scalars —
///      never per-account storage. That O(1)-per-market property is what makes the
///      no-continuous-crank, lazy model viable on L1.
///
///      Two steps:
///        1. staircase (§1.7): clamp the raw oracle target toward `pLast` by at most
///           max_delta = floor(pLast * maxPriceMoveBpsPerSec * dt / 10_000), so a single
///           large oracle jump can never be marked through in one step.
///        2. accrue (§5.3): enforce the per-step price-move envelope, then
///             K_long  += A_long  * ΔP   (if long OI > 0)
///             K_short -= A_short * ΔP   (if short OI > 0)
///             F_long  -= A_long  * fundNumTotal ; F_short += A_short * fundNumTotal
///           and finalize pLast / fundPxLast / slotLast.
library Accrual {
    error InvalidOraclePrice();
    error AccrualWindowExceeded();
    error PriceMoveExceeded();

    /// @notice §1.7 deterministic clamp: move `pLast` toward `target` by at most maxDelta.
    ///         Never overshoots; never returns 0 (price must stay > 0).
    function staircaseNext(uint256 pLast, uint256 target, uint256 maxPriceMoveBpsPerSec, uint256 dt)
        internal
        pure
        returns (uint256)
    {
        if (target == pLast || dt == 0 || pLast == 0) return pLast == 0 ? target : pLast;
        uint256 maxDelta =
            FixedPointMath.mulDivDown(pLast, maxPriceMoveBpsPerSec * dt, Constants.BPS_DENOM);
        if (target > pLast) {
            uint256 up = pLast + maxDelta;
            return up < target ? up : target;
        } else {
            if (maxDelta >= pLast) return target; // would underflow; target is the floor
            uint256 down = pLast - maxDelta;
            return down > target ? down : target;
        }
    }

    /// @notice Accrue `g` to `nowTs` at effective engine price `effPrice` (already
    ///         staircase-clamped) with signed per-second funding rate (e9 units).
    ///         Mutates only g's side accumulators + price/slot scalars.
    function accrue(
        Types.Globals storage g,
        Types.MarketConfig storage cfg,
        uint256 effPrice,
        int256 fundingRateE9PerSec,
        uint256 nowTs
    ) internal {
        if (effPrice == 0 || effPrice > Constants.MAX_ORACLE_PRICE) {
            revert InvalidOraclePrice();
        }
        if (nowTs < g.slotLast) revert AccrualWindowExceeded();
        uint256 dt = nowTs - g.slotLast;

        uint256 pLast = g.pLast;
        uint256 oiL = g.longSide.oiEffQ;
        uint256 oiS = g.shortSide.oiEffQ;

        bool fundingActive = fundingRateE9PerSec != 0 && oiL != 0 && oiS != 0 && g.fundPxLast > 0;
        bool priceMoveActive = pLast > 0 && effPrice != pLast && (oiL != 0 || oiS != 0);

        if ((fundingActive || priceMoveActive) && dt > cfg.maxAccrualDtSec) {
            revert AccrualWindowExceeded();
        }

        // Per-step price-move envelope (spec §5.3): checked BEFORE any mutation.
        // |ΔP| * 10_000 <= maxPriceMoveBpsPerSec * dt * pLast
        if (priceMoveActive) {
            uint256 absDelta = effPrice > pLast ? effPrice - pLast : pLast - effPrice;
            uint256 lhs = absDelta * Constants.BPS_DENOM;
            uint256 rhs = uint256(cfg.maxPriceMoveBpsPerSec) * dt * pLast;
            if (lhs > rhs) revert PriceMoveExceeded();
        }

        // Mark-to-market: K_side += A_side * ΔP (per side, only if that side has OI).
        if (pLast > 0 && effPrice != pLast) {
            int256 dP = int256(effPrice) - int256(pLast);
            if (oiL > 0) {
                g.longSide.k += int256(g.longSide.a) * dP;
            }
            if (oiS > 0) {
                g.shortSide.k -= int256(g.shortSide.a) * dP;
            }
        }

        // Funding: F_long -= A_long * total ; F_short += A_short * total.
        if (fundingActive && dt > 0) {
            int256 total = int256(uint256(g.fundPxLast)) * fundingRateE9PerSec * int256(dt);
            g.longSide.fNum -= int256(g.longSide.a) * total;
            g.shortSide.fNum += int256(g.shortSide.a) * total;
        }

        // Finalize.
        g.pLast = uint64(effPrice);
        g.fundPxLast = uint64(effPrice);
        g.slotLast = uint64(nowTs);
    }
}
