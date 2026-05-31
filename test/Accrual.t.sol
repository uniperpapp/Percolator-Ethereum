// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EngineHarness} from "./harness/EngineHarness.sol";
import {Accrual} from "../src/libraries/Accrual.sol";
import {Constants} from "../src/libraries/Constants.sol";

contract AccrualTest is Test {
    EngineHarness h;

    uint256 constant E6 = 1_000_000;
    uint256 constant A1 = Constants.ADL_ONE; // 1e15

    function setUp() public {
        h = new EngineHarness();
        // allow a 1% move over dt=100s: |ΔP|*1e4 <= rate*dt*pLast.
        // ΔP=1e6, pLast=100e6, dt=100 -> need rate >= 1; use 2 for margin.
        h.setConfig(2, 100);
    }

    // ---- staircase (§1.7) ----

    function test_staircase_clamps_large_jump() public view {
        // pLast=100e6, target=200e6, rate=2, dt=100
        // maxDelta = floor(100e6 * (2*100) / 10000) = floor(100e6*200/1e4) = 2e6
        uint256 next = h.staircase(100 * E6, 200 * E6, 2, 100);
        assertEq(next, 102 * E6); // walks up by maxDelta, not to target
    }

    function test_staircase_reaches_small_target() public view {
        // target within one step is reached exactly
        uint256 next = h.staircase(100 * E6, 100 * E6 + 1, 2, 100);
        assertEq(next, 100 * E6 + 1);
    }

    function test_staircase_down() public view {
        uint256 next = h.staircase(100 * E6, 50 * E6, 2, 100);
        assertEq(next, 98 * E6); // down by 2e6
    }

    function test_staircase_noop_when_target_equals() public view {
        assertEq(h.staircase(100 * E6, 100 * E6, 2, 100), 100 * E6);
    }

    // ---- mark-to-K (§5.3) ----

    function test_mark_to_k_both_sides() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 1 * E6); // OI both sides
        h.accrue(101 * E6, 0, 100); // +1e6 price move
        // ΔP = 1e6; K_long += A*ΔP = 1e15*1e6 = 1e21 ; K_short -= same
        assertEq(h.kLong(), int256(A1 * E6));
        assertEq(h.kShort(), -int256(A1 * E6));
        assertEq(h.pLast(), uint64(101 * E6));
        assertEq(h.slotLast(), 100);
    }

    function test_mark_only_long_side_when_short_flat() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 0); // only long OI
        h.accrue(101 * E6, 0, 100);
        assertEq(h.kLong(), int256(A1 * E6));
        assertEq(h.kShort(), int256(0)); // short has no OI -> untouched
    }

    function test_mark_negative_move() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 1 * E6);
        h.accrue(99 * E6, 0, 100); // -1e6
        assertEq(h.kLong(), -int256(A1 * E6)); // longs lose
        assertEq(h.kShort(), int256(A1 * E6)); // shorts gain
    }

    // ---- envelope (§5.3) ----

    function test_envelope_rejects_too_large_move() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 1 * E6);
        // jump to 200e6 = 100% in one step; rate=2,dt=100 -> rhs=2e10, lhs=100e6*1e4=1e12 > rhs
        vm.expectRevert(Accrual.PriceMoveExceeded.selector);
        h.accrue(200 * E6, 0, 100);
    }

    function test_envelope_not_checked_when_zero_oi() public {
        h.seed(A1, uint64(100 * E6), 0, 0, 0); // no OI
        // even a huge jump is allowed when nobody is exposed; just advances price
        h.accrue(500 * E6, 0, 100);
        assertEq(h.pLast(), uint64(500 * E6));
    }

    function test_accrual_window_exceeded() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 1 * E6);
        // dt=101 > maxAccrualDtSec=100 with an active price move -> revert
        vm.expectRevert(Accrual.AccrualWindowExceeded.selector);
        h.accrue(101 * E6, 0, 101);
    }

    // ---- funding (§5.3) ----

    function test_funding_accrues_to_F() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 1 * E6);
        // no price move (effPrice == pLast), funding rate = 1000 e9/s, dt=10
        // total = fundPxLast * rate * dt = 100e6 * 1000 * 10 = 1e12
        h.accrue(100 * E6, 1000, 10);
        int256 total = int256(100 * E6) * 1000 * 10; // 1e12
        assertEq(h.fLong(), -int256(A1) * total); // longs pay
        assertEq(h.fShort(), int256(A1) * total); // shorts receive
    }

    function test_funding_inactive_when_one_side_flat() public {
        h.seed(A1, uint64(100 * E6), 0, 1 * E6, 0); // short flat
        h.accrue(100 * E6, 1000, 10);
        assertEq(h.fLong(), int256(0));
        assertEq(h.fShort(), int256(0));
    }

    // ---- invalid inputs ----

    function test_rejects_zero_price() public {
        h.seed(A1, uint64(100 * E6), 0, 0, 0);
        vm.expectRevert(Accrual.InvalidOraclePrice.selector);
        h.accrue(0, 0, 100);
    }

    function test_rejects_price_above_max() public {
        h.seed(A1, uint64(100 * E6), 0, 0, 0);
        vm.expectRevert(Accrual.InvalidOraclePrice.selector);
        h.accrue(Constants.MAX_ORACLE_PRICE + 1, 0, 100);
    }
}
