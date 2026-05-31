// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Constants} from "./Constants.sol";
import {FixedPointMath} from "./FixedPointMath.sol";

/// @title SolvencyProof
/// @notice The construction-time "self-neutral siphon" boundary (Percolator spec §1.6),
///         ported faithfully from the Rust engine's `validate_exact_solvency_envelope`
///         (percolator/src/percolator.rs:1571–1941) and RE-EXPRESSED IN SECONDS for
///         Ethereum L1 (Solana counted 400 ms slots; here every per-slot budget is
///         per-second and `dt` is `block.timestamp` seconds).
///
/// @dev THE INVARIANT (spec §1.6): for every integer risk notional N in
///      [1, MAX_ACCOUNT_NOTIONAL], the worst one-accrual-step price+funding loss plus
///      the worst post-move liquidation fee must not exceed the maintenance requirement:
///
///        price_budget_bps   = maxPriceMoveBpsPerSec * maxAccrualDtSec
///        funding_budget_num = maxAbsFundingE9PerSec * maxAccrualDtSec * 10_000
///        loss_budget_num    = price_budget_bps * FUNDING_DEN + funding_budget_num
///        loss_budget_den    = 10_000 * FUNDING_DEN
///
///        price_funding_loss_N = ceil(N * loss_budget_num / loss_budget_den)
///        worst_liq_notional_N = ceil(N * (10_000 + price_budget_bps) / 10_000)
///        liq_fee_raw_N        = ceil(worst_liq_notional_N * liqFeeBps / 10_000)
///        liq_fee_N            = min(max(liq_fee_raw_N, minLiquidationAbs), liqFeeCap)
///        mm_req_N             = max(floor(N * maintenanceBps / 10_000), minNonzeroMmReq)
///        REQUIRE: price_funding_loss_N + liq_fee_N <= mm_req_N
///
///      A naive loop over all N up to 1e20 is impossible on-chain. This port reproduces
///      the Rust analytic decomposition: closed-form floor-region + linear/capped tail
///      bounds reduce the universe to a small exact interval, proven by bounded
///      bisection with monotonicity certificates. Total work is bounded (no unbounded
///      loops) so this runs once in the constructor/initializer as a `require`.
///
///      Faithfulness note: this mirrors the Rust `not(kani)` runtime validator. The
///      same proof is to be re-established symbolically (Halmos/Certora) in Milestone 4.
library SolvencyProof {
    using FixedPointMath for uint256;

    /// Subset of MarketConfig the proof needs. Kept as an explicit struct so the
    /// proof is testable in isolation against the Rust accept/reject vectors.
    struct Params {
        uint256 maxPriceMoveBpsPerSec; // cfg_max_price_move_bps_per_sec
        uint256 maxAccrualDtSec; // cfg_max_accrual_dt_sec
        uint256 maxAbsFundingE9PerSec; // cfg_max_abs_funding_e9_per_sec
        uint256 maintenanceBps; // cfg_maintenance_bps
        uint256 liquidationFeeBps; // cfg_liquidation_fee_bps
        uint256 minLiquidationAbs; // cfg_min_liquidation_abs
        uint256 liquidationFeeCap; // cfg_liquidation_fee_cap
        uint256 minNonzeroMmReq; // cfg_min_nonzero_mm_req
    }

    // Bounded-work constants (match the Rust validator).
    uint256 internal constant MAX_SOLVENCY_INTERVALS = 96;
    uint256 internal constant MAX_SOLVENCY_STEPS = 4096;
    uint256 internal constant EXACT_CHUNK = 64;

    /// @notice Returns true iff the per-risk-notional solvency envelope holds for ALL
    ///         N in [1, MAX_ACCOUNT_NOTIONAL]. Pure; safe to call in a constructor.
    function validate(Params memory p) internal pure returns (bool) {
        // ---- derive budgets (256-bit native; no wide-math shim needed) ----
        // price_budget_bps = maxPriceMoveBpsPerSec * maxAccrualDtSec
        uint256 priceBudgetBps = p.maxPriceMoveBpsPerSec * p.maxAccrualDtSec;
        // funding_budget_num = maxAbsFundingE9PerSec * maxAccrualDtSec * 10_000
        uint256 fundingBudgetNum = p.maxAbsFundingE9PerSec * p.maxAccrualDtSec * Constants.BPS_DENOM;
        // loss_budget_num = price_budget_bps * FUNDING_DEN + funding_budget_num
        uint256 lossBudgetNum = priceBudgetBps * Constants.FUNDING_DEN + fundingBudgetNum;
        // loss_budget_den = 10_000 * FUNDING_DEN
        uint256 lossBudgetDen = Constants.BPS_DENOM * Constants.FUNDING_DEN;

        // funding_budget_bps_ceil = ceil(funding_budget_num / FUNDING_DEN)
        uint256 fundingBudgetBpsCeil = _ceilDiv(fundingBudgetNum, Constants.FUNDING_DEN);
        // loss_budget_bps_ceil = price_budget_bps + funding_budget_bps_ceil
        uint256 lossBudgetBpsCeil = priceBudgetBps + fundingBudgetBpsCeil;
        // worst_liq_budget_bps_ceil = ceil((10_000 + price_budget_bps) * liqFeeBps / 10_000)
        uint256 worstLiqBudgetBpsCeil = _ceilDiv(
            (Constants.BPS_DENOM + priceBudgetBps) * p.liquidationFeeBps, Constants.BPS_DENOM
        );
        // linear_budget_bps = loss_budget_bps_ceil + worst_liq_budget_bps_ceil
        uint256 linearBudgetBps = lossBudgetBpsCeil + worstLiqBudgetBpsCeil;

        // Exact full-margin loss-only special case (spec/Rust:1791): maintenance==100%,
        // loss budget exactly fills it, no fee term, no fee floor → trivially holds.
        if (
            p.maintenanceBps == Constants.BPS_DENOM && lossBudgetBpsCeil == Constants.BPS_DENOM
                && worstLiqBudgetBpsCeil == 0 && p.minLiquidationAbs == 0
        ) {
            return true;
        }

        uint256 domainMax = Constants.MAX_ACCOUNT_NOTIONAL;

        // maintenance_margin_bps == 0: no proportional term; loss+fee monotone in N,
        // so only the domain max must be checked (Rust:1804).
        if (p.maintenanceBps == 0) {
            return _holds(p, domainMax, lossBudgetNum, lossBudgetDen, priceBudgetBps);
        }

        // ---- Floor region (Rust:1819) ----
        // While proportional maintenance < min floor, loss+fee is monotone, so the
        // largest floor-covered notional is the only point to check.
        // floor_region_max = ((min_nonzero_mm_req + 1) * 10_000 - 1) / maintenance_bps
        uint256 floorRegionMax =
            ((p.minNonzeroMmReq + 1) * Constants.BPS_DENOM - 1) / p.maintenanceBps;
        uint256 floorRegionEnd = floorRegionMax < domainMax ? floorRegionMax : domainMax;
        if (
            floorRegionEnd != 0
                && !_holds(p, floorRegionEnd, lossBudgetNum, lossBudgetDen, priceBudgetBps)
        ) {
            return false;
        }
        if (floorRegionMax >= domainMax) {
            return true;
        }

        uint256 exactStart = floorRegionEnd + 1;

        // ---- Linear tail (Rust:1852): uncapped-fee slope below maintenance slope ----
        if (linearBudgetBps < p.maintenanceBps) {
            uint256 slopeGap = p.maintenanceBps - linearBudgetBps;
            uint256 roundingSlack = 3;
            uint256 tailForLinear = _ceilDiv(roundingSlack * Constants.BPS_DENOM, slopeGap);

            uint256 lossGap = p.maintenanceBps - lossBudgetBpsCeil; // checked >=0 by branch ordering
            uint256 floorFeeSlack = p.minLiquidationAbs + 2;
            uint256 tailForFeeFloor = _ceilDiv(floorFeeSlack * Constants.BPS_DENOM, lossGap);

            uint256 exactTail = tailForLinear > tailForFeeFloor ? tailForLinear : tailForFeeFloor;
            if (exactTail <= exactStart) {
                return true;
            }
            uint256 exactEnd = _min(exactTail - 1, domainMax);
            return
                _validateRange(
                    p, exactStart, exactEnd, lossBudgetNum, lossBudgetDen, priceBudgetBps
                );
        }

        // loss budget alone already meets/exceeds maintenance slope → must exact-check
        // the whole tail to the domain max (Rust:1898).
        if (lossBudgetBpsCeil >= p.maintenanceBps) {
            return
                _validateRange(
                    p, exactStart, domainMax, lossBudgetNum, lossBudgetDen, priceBudgetBps
                );
        }

        // ---- Capped-fee tail (Rust:1909): fee cap as a bounded additive term ----
        uint256 slopeGap2 = p.maintenanceBps - lossBudgetBpsCeil;
        uint256 cappedFeeSlack = p.liquidationFeeCap + 3; // + rounding_slack
        uint256 exactTail2 = _ceilDiv(cappedFeeSlack * Constants.BPS_DENOM, slopeGap2);
        if (exactTail2 <= exactStart) {
            return true;
        }
        uint256 exactEnd2 = _min(exactTail2 - 1, domainMax);
        return
            _validateRange(p, exactStart, exactEnd2, lossBudgetNum, lossBudgetDen, priceBudgetBps);
    }

    // ---------------------------------------------------------------------
    // Per-notional terms
    // ---------------------------------------------------------------------

    /// total = price_funding_loss_N + liq_fee_N
    function _totalForNotional(
        Params memory p,
        uint256 n,
        uint256 lossBudgetNum,
        uint256 lossBudgetDen,
        uint256 priceBudgetBps
    ) private pure returns (uint256) {
        uint256 loss = FixedPointMath.mulDivUp(n, lossBudgetNum, lossBudgetDen);
        uint256 worstLiqNotional =
            FixedPointMath.mulDivUp(n, Constants.BPS_DENOM + priceBudgetBps, Constants.BPS_DENOM);
        uint256 liqFeeRaw =
            FixedPointMath.mulDivUp(worstLiqNotional, p.liquidationFeeBps, Constants.BPS_DENOM);
        uint256 liqFee = _min(_max(liqFeeRaw, p.minLiquidationAbs), p.liquidationFeeCap);
        return loss + liqFee;
    }

    /// mm_req_N = max(floor(N * maintenanceBps / 10_000), minNonzeroMmReq)
    function _maintenanceForNotional(Params memory p, uint256 n) private pure returns (uint256) {
        uint256 mmProp = (n * p.maintenanceBps) / Constants.BPS_DENOM;
        return _max(mmProp, p.minNonzeroMmReq);
    }

    function _holds(
        Params memory p,
        uint256 n,
        uint256 lossBudgetNum,
        uint256 lossBudgetDen,
        uint256 priceBudgetBps
    ) private pure returns (bool) {
        uint256 total = _totalForNotional(p, n, lossBudgetNum, lossBudgetDen, priceBudgetBps);
        uint256 mmReq = _maintenanceForNotional(p, n);
        return total <= mmReq;
    }

    /// Monotone interval certificate: if the worst case over [lo,hi] (loss+fee at hi)
    /// is covered by the weakest maintenance over [lo,hi] (mm at lo), the whole
    /// interval holds without per-point checks (Rust:1647).
    function _intervalCertifies(
        Params memory p,
        uint256 lo,
        uint256 hi,
        uint256 lossBudgetNum,
        uint256 lossBudgetDen,
        uint256 priceBudgetBps
    ) private pure returns (bool) {
        uint256 totalHi = _totalForNotional(p, hi, lossBudgetNum, lossBudgetDen, priceBudgetBps);
        uint256 mmLo = _maintenanceForNotional(p, lo);
        return totalHi <= mmLo;
    }

    // ---------------------------------------------------------------------
    // Bounded bisection over [lo, hi] (Rust:1667, explicit stack — no recursion)
    // ---------------------------------------------------------------------
    function _validateRange(
        Params memory p,
        uint256 lo,
        uint256 hi,
        uint256 lossBudgetNum,
        uint256 lossBudgetDen,
        uint256 priceBudgetBps
    ) private pure returns (bool) {
        if (lo > hi) return true;

        uint256[2][MAX_SOLVENCY_INTERVALS] memory stack;
        uint256 len = 1;
        uint256 steps = 0;
        stack[0] = [lo, hi];

        while (len != 0) {
            steps += 1;
            if (steps > MAX_SOLVENCY_STEPS) return false;

            len -= 1;
            uint256 rangeLo = stack[len][0];
            uint256 rangeHi = stack[len][1];

            if (_intervalCertifies(
                    p, rangeLo, rangeHi, lossBudgetNum, lossBudgetDen, priceBudgetBps
                )) {
                continue;
            }

            if (rangeHi == rangeLo || rangeHi - rangeLo <= EXACT_CHUNK) {
                uint256 n = rangeLo;
                while (true) {
                    if (!_holds(p, n, lossBudgetNum, lossBudgetDen, priceBudgetBps)) {
                        return false;
                    }
                    if (n == rangeHi) break;
                    n += 1;
                }
                continue;
            }

            uint256 mid = rangeLo + (rangeHi - rangeLo) / 2;
            if (len + 2 > MAX_SOLVENCY_INTERVALS) return false;
            stack[len] = [mid + 1, rangeHi];
            stack[len + 1] = [rangeLo, mid];
            len += 2;
        }
        return true;
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == 0) return 0;
        return (a - 1) / b + 1;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }
}
