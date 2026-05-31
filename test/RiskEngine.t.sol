// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RiskEngine} from "../src/libraries/RiskEngine.sol";
import {Types} from "../src/libraries/Types.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @dev External wrapper so we can assert reverts across an external call boundary
///      (internal library functions are inlined into the test contract).
contract REHarness {
    function residual(uint256 v, uint256 c, uint256 i) external pure returns (uint256) {
        return RiskEngine.residual(v, c, i);
    }
}

contract RiskEngineTest is Test {
    uint256 constant E6 = 1_000_000;
    REHarness harness;

    function setUp() public {
        harness = new REHarness();
    }

    // ----- conservation / residual -----

    function test_residual_basic() public pure {
        // V=1000, C=600, I=100 -> Residual=300
        assertEq(RiskEngine.residual(1000, 600, 100), 300);
    }

    function test_residual_reverts_on_violation() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskEngine.ConservationViolated.selector, uint256(500), uint256(600), uint256(0)
            )
        );
        harness.residual(500, 600, 0);
    }

    // ----- H haircut -----

    function test_haircut_fully_backed_h_equals_one() public pure {
        // Residual(300) >= matured(200) -> h = min(300,200)/200 = 200/200 = 1
        Types.Ratio memory h = RiskEngine.haircutRatio(300, 200);
        assertEq(h.num, 200);
        assertEq(h.den, 200);
        // released 50 -> full 50
        assertEq(RiskEngine.effectiveMaturedPnl(50, 300, 200), 50);
    }

    function test_haircut_stressed_h_below_one() public pure {
        // Residual(100) < matured(200) -> h = 100/200 = 0.5
        Types.Ratio memory h = RiskEngine.haircutRatio(100, 200);
        assertEq(h.num, 100);
        assertEq(h.den, 200);
        // released 50 -> floor(50 * 100 / 200) = 25
        assertEq(RiskEngine.effectiveMaturedPnl(50, 100, 200), 25);
    }

    function test_haircut_no_matured_is_one() public pure {
        Types.Ratio memory h = RiskEngine.haircutRatio(123, 0);
        assertEq(h.num, 1);
        assertEq(h.den, 1);
        assertEq(RiskEngine.effectiveMaturedPnl(50, 123, 0), 50);
    }

    /// @dev Core safety property: total effective matured payouts never exceed Residual.
    function testFuzz_haircut_sum_bounded_by_residual(
        uint256 residual_,
        uint256 matured,
        uint256 released
    ) public pure {
        matured = bound(matured, 1, 1e30);
        released = bound(released, 0, matured); // an account's released <= total matured
        residual_ = bound(residual_, 0, 1e30);
        uint256 eff = RiskEngine.effectiveMaturedPnl(released, residual_, matured);
        // If everyone's released summed to `matured`, total effective <= Residual.
        // For a single account: eff <= floor(released * min(R,matured)/matured) <= released
        // and the aggregate cap is eff_total <= min(Residual, matured). Check the per-account bound.
        assertLe(eff, released);
        if (residual_ < matured) {
            // h < 1 => eff <= released and eff <= released (strictly haircut). Check eff <= Residual-ish bound.
            assertLe(eff, residual_ + 1); // single account released<=matured => eff<=floor(released*R/matured)<=R
        }
    }

    // ----- risk notional (ceil) & margin -----

    function test_riskNotional_ceil() public pure {
        // 1.0 base at price 50.0 -> ceil(1e6 * 50e6 / 1e6) = 50e6
        assertEq(RiskEngine.riskNotional(1 * E6, 50 * E6), 50 * E6);
        // dust: 1 q-unit at 50.0 -> ceil(1 * 50e6 / 1e6) = ceil(50) = 50 (NOT zero)
        assertEq(RiskEngine.riskNotional(1, 50 * E6), 50);
    }

    function test_riskNotional_flat_is_zero() public pure {
        assertEq(RiskEngine.riskNotional(0, 50 * E6), 0);
    }

    function test_maintenanceReq() public pure {
        // rn=1e6, 5% -> floor(1e6*500/10000)=50_000 ; min floor 100 -> 50_000
        assertEq(RiskEngine.maintenanceReq(1 * E6, 500, 100), 50_000);
        // tiny rn hits the min-nonzero floor
        assertEq(RiskEngine.maintenanceReq(100, 500, 100), 100);
        // flat
        assertEq(RiskEngine.maintenanceReq(0, 500, 100), 0);
    }
}
