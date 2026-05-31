// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolvencyProof} from "../src/libraries/SolvencyProof.sol";

/// @notice Tests for the §1.6 bounded-breakpoint solvency proof (re-derived in seconds).
///         Vectors are hand-derived from the invariant
///         price_funding_loss_N + liq_fee_N <= mm_req_N for all N in [1, MAX_ACCOUNT_NOTIONAL].
contract SolvencyProofTest is Test {
    function _base() internal pure returns (SolvencyProof.Params memory p) {
        p = SolvencyProof.Params({
            maxPriceMoveBpsPerSec: 1,
            maxAccrualDtSec: 100, // price_budget_bps = 100 (1%)
            maxAbsFundingE9PerSec: 0,
            maintenanceBps: 500, // 5%
            liquidationFeeBps: 0,
            minLiquidationAbs: 0,
            liquidationFeeCap: 0,
            minNonzeroMmReq: 1
        });
    }

    // ---- PASS cases ----

    function test_pass_price_below_maintenance() public pure {
        // price_budget 1% << maintenance 5%, no funding/fees -> holds for all N
        assertTrue(SolvencyProof.validate(_base()));
    }

    function test_pass_with_liq_fee_within_budget() public pure {
        SolvencyProof.Params memory p = _base();
        p.maintenanceBps = 1000; // 10%
        p.liquidationFeeBps = 50; // 0.5%
        p.liquidationFeeCap = 1e30;
        // minNonzeroMmReq must cover the worst small-N case: at low N the ceil rounding
        // on loss and on liq_fee each contribute >= 1, so the maintenance floor has to
        // absorb that constant. With proportional maintenance ~1.5% << 10%, a floor of
        // 100 covers the whole floor region; the tail is then slope-dominated.
        p.minNonzeroMmReq = 100;
        assertTrue(SolvencyProof.validate(p));
    }

    function test_pass_full_margin_loss_only_special_case() public pure {
        // maintenance 100%, price budget exactly 100% (rate*dt = 10000), no fee/floor
        SolvencyProof.Params memory p = _base();
        p.maxPriceMoveBpsPerSec = 100;
        p.maxAccrualDtSec = 100; // price_budget_bps = 10000
        p.maintenanceBps = 10_000;
        p.liquidationFeeBps = 0;
        p.minLiquidationAbs = 0;
        p.liquidationFeeCap = 0;
        assertTrue(SolvencyProof.validate(p));
    }

    function test_pass_with_funding_within_budget() public pure {
        SolvencyProof.Params memory p = _base();
        p.maintenanceBps = 1000; // 10%
        // funding budget bps = funding_budget_num / FUNDING_DEN
        //  = (maxAbsFundingE9PerSec * dt * 1e4) / 1e9
        // pick maxAbsFundingE9PerSec=1000, dt=100 -> 1000*100*1e4/1e9 = 1 bps. tiny.
        p.maxAbsFundingE9PerSec = 1000;
        assertTrue(SolvencyProof.validate(p));
    }

    // ---- FAIL cases ----

    function test_fail_price_above_maintenance() public pure {
        SolvencyProof.Params memory p = _base();
        p.maxPriceMoveBpsPerSec = 6; // price_budget_bps = 600 (6%) > maintenance 5%
        assertFalse(SolvencyProof.validate(p));
    }

    function test_fail_liq_fee_floor_dominates_small_N() public pure {
        // A large absolute min liquidation fee that the maintenance floor can't cover
        // at small N -> envelope fails in the floor region.
        SolvencyProof.Params memory p = _base();
        p.maintenanceBps = 500;
        p.minNonzeroMmReq = 1;
        p.liquidationFeeBps = 0;
        p.minLiquidationAbs = 1000; // flat $1000 fee for every liquidation
        p.liquidationFeeCap = 1000;
        // N=1: total ~ 1 + 1000 = 1001 > mm_req = max(0,1) = 1 -> FAIL
        assertFalse(SolvencyProof.validate(p));
    }

    function test_fail_liq_fee_bps_pushes_over() public pure {
        SolvencyProof.Params memory p = _base();
        p.maintenanceBps = 500; // 5%
        p.maxPriceMoveBpsPerSec = 4; // price 4%
        p.liquidationFeeBps = 300; // ~3% -> 4%+3% = 7% > 5%
        p.liquidationFeeCap = 1e30;
        assertFalse(SolvencyProof.validate(p));
    }

    // ---- boundary: exactly at the edge ----

    function test_pass_price_equals_maintenance_loss_only() public pure {
        // price_budget == maintenance, no fees. price_funding_loss_N = ceil(N*p%),
        // mm_req_N = floor(N*p%). ceil can exceed floor by 1, but min_nonzero_mm_req
        // floor + monotone tail keeps it covered for the linear region only when
        // ceil slack is absorbed. With min_nonzero_mm_req=1 and equal slopes the ceil
        // rounding makes it FAIL at points where N*p% is fractional.
        SolvencyProof.Params memory p = _base();
        p.maxPriceMoveBpsPerSec = 5; // price_budget = 500 == maintenance 500
        // expected: fails due to ceil>floor at fractional points
        assertFalse(SolvencyProof.validate(p));
    }

    // ---- gas: proof must be cheap enough for a constructor ----

    function test_gas_validate_typical() public {
        SolvencyProof.Params memory p = _base();
        uint256 gasBefore = gasleft();
        bool ok = SolvencyProof.validate(p);
        uint256 used = gasBefore - gasleft();
        assertTrue(ok);
        emit log_named_uint("solvency proof gas (pass)", used);
        // Sanity ceiling — must be affordable in a market-creation tx.
        assertLt(used, 5_000_000);
    }
}
