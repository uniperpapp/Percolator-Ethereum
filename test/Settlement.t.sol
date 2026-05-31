// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EngineHarness} from "./harness/EngineHarness.sol";
import {Types} from "../src/libraries/Types.sol";
import {Constants} from "../src/libraries/Constants.sol";

contract SettlementTest is Test {
    EngineHarness h;

    uint256 constant E6 = 1_000_000;
    uint256 constant A1 = Constants.ADL_ONE; // 1e15

    function setUp() public {
        h = new EngineHarness();
    }

    function _acct(int256 basis, uint256 aBasis, int256 kSnap, int256 fSnap, uint64 epochSnap)
        internal
        pure
        returns (Types.Account memory a)
    {
        a.basisPosQ = basis;
        a.aBasis = aBasis;
        a.kSnap = kSnap;
        a.fSnap = fSnap;
        a.epochSnap = epochSnap;
        a.materialized = true;
    }

    function _side(uint256 a_, int256 k, int256 fNum, uint64 epoch)
        internal
        pure
        returns (Types.SideState memory s)
    {
        s.a = a_;
        s.k = k;
        s.fNum = fNum;
        s.epoch = epoch;
    }

    // ---- effective position ----

    function test_effective_pos_full() public view {
        // 1.0 base long, aBasis = A = ADL_ONE -> effective == basis
        Types.Account memory a = _acct(int256(1 * E6), A1, 0, 0, 0);
        Types.SideState memory s = _side(A1, 0, 0, 0);
        assertEq(h.effectivePosQ(a, s), int256(1 * E6));
    }

    function test_effective_pos_after_a_decay() public view {
        // A decayed to half -> effective halves (ADL quantity socialization)
        Types.Account memory a = _acct(int256(1 * E6), A1, 0, 0, 0);
        Types.SideState memory s = _side(A1 / 2, 0, 0, 0);
        assertEq(h.effectivePosQ(a, s), int256(E6 / 2));
    }

    function test_effective_pos_short_is_negative() public view {
        Types.Account memory a = _acct(-int256(1 * E6), A1, 0, 0, 0);
        Types.SideState memory s = _side(A1, 0, 0, 0);
        assertEq(h.effectivePosQ(a, s), -int256(1 * E6));
    }

    function test_effective_pos_zero_on_epoch_mismatch() public view {
        Types.Account memory a = _acct(int256(1 * E6), A1, 0, 0, 0); // epochSnap 0
        Types.SideState memory s = _side(A1, 0, 0, 1); // side epoch advanced to 1
        assertEq(h.effectivePosQ(a, s), int256(0));
    }

    function test_effective_pos_zero_when_flat() public view {
        Types.Account memory a = _acct(0, A1, 0, 0, 0);
        Types.SideState memory s = _side(A1, 0, 0, 0);
        assertEq(h.effectivePosQ(a, s), int256(0));
    }

    // ---- kf pnl delta (linear engine PnL: basis * ΔP / POS_SCALE) ----

    function test_kf_pnl_delta_mark_gain() public view {
        // After a +1e6 mark move on a 1.0 long with A=ADL_ONE: K = A*ΔP = 1e21.
        // pnl_delta = floor(|basis| * (kDiff*FUNDING_DEN) / (aBasis*POS_SCALE*FUNDING_DEN))
        //           = floor(1e6 * 1e21 / (1e15 * 1e6)) = 1e6
        Types.Account memory a = _acct(int256(1 * E6), A1, 0, 0, 0);
        Types.SideState memory s = _side(A1, int256(A1 * E6), 0, 0); // k = 1e21
        assertEq(h.kfPnlDelta(a, s), int256(1 * E6));
    }

    function test_kf_pnl_delta_mark_loss_floors_toward_neg_inf() public view {
        // Negative K with a remainder must floor DOWN (against the trader).
        // k = -(1e21 + 1) ; delta = floor( 1e6 * -(1e21+1) / 1e21 )
        //   = floor( -(1e6 + 1e6/1e21) ) -> -(1e6 + epsilon) -> -1000001
        Types.Account memory a = _acct(int256(1 * E6), A1, 0, 0, 0);
        int256 k = -(int256(A1 * E6) + 1);
        Types.SideState memory s = _side(A1, k, 0, 0);
        assertEq(h.kfPnlDelta(a, s), -int256(1 * E6) - 1);
    }

    function test_kf_pnl_delta_funding_component() public view {
        // Pure funding (kDiff = 0): delta = floor(|basis| * fNum / (aBasis*POS_SCALE*FUNDING_DEN)).
        // With basis = aBasis = A1 this is floor(fNum / (POS_SCALE*FUNDING_DEN)) = floor(fNum / 1e15).
        // Pick fNum = A1*FUNDING_DEN = 1e24 so delta = floor(1e6 * 1e24 / 1e30) = 1.
        Types.Account memory a = _acct(int256(1 * E6), A1, 0, 0, 0);
        int256 fNum = int256(A1 * Constants.FUNDING_DEN); // 1e24
        Types.SideState memory s = _side(A1, 0, fNum, 0);
        assertEq(h.kfPnlDelta(a, s), int256(1));

        // Linearity: 1e6x the funding numerator scales delta to 1e6.
        Types.SideState memory s2 = _side(A1, 0, fNum * int256(E6), 0);
        assertEq(h.kfPnlDelta(a, s2), int256(1 * E6));
    }

    function test_kf_pnl_delta_zero_when_flat() public view {
        Types.Account memory a = _acct(0, A1, 0, 0, 0);
        Types.SideState memory s = _side(A1, 12345, 678, 0);
        assertEq(h.kfPnlDelta(a, s), int256(0));
    }
}
