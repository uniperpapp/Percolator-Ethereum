// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FixedPointMath} from "../src/libraries/FixedPointMath.sol";

contract FixedPointMathHarness {
    function mulDivDown(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FixedPointMath.mulDivDown(a, b, d);
    }
}

contract FixedPointMathTest is Test {
    FixedPointMathHarness h;

    function setUp() public {
        h = new FixedPointMathHarness();
    }

    function test_mulDivDown_basic() public pure {
        assertEq(FixedPointMath.mulDivDown(10, 20, 5), 40);
        assertEq(FixedPointMath.mulDivDown(7, 3, 2), 10); // floor(21/2)=10
    }

    function test_mulDivUp_basic() public pure {
        assertEq(FixedPointMath.mulDivUp(7, 3, 2), 11); // ceil(21/2)=11
        assertEq(FixedPointMath.mulDivUp(10, 20, 5), 40); // exact
    }

    /// @dev No 256-bit overflow even when a*b exceeds 2^256 (the reason mulDiv exists).
    function test_mulDivDown_no_overflow_on_large_product() public pure {
        uint256 a = type(uint256).max;
        uint256 b = 5;
        uint256 d = 5;
        assertEq(FixedPointMath.mulDivDown(a, b, d), a); // (max*5)/5 == max, no revert
    }

    function test_mulDivDown_reverts_div_by_zero() public {
        vm.expectRevert(FixedPointMath.DivByZero.selector);
        h.mulDivDown(1, 1, 0);
    }

    function testFuzz_mulDivDown_matches_native_when_small(uint128 a, uint128 b, uint128 d)
        public
        pure
    {
        vm.assume(d != 0);
        assertEq(FixedPointMath.mulDivDown(a, b, d), (uint256(a) * uint256(b)) / uint256(d));
    }

    function testFuzz_up_is_down_or_plus_one(uint128 a, uint128 b, uint128 d) public pure {
        vm.assume(d != 0);
        uint256 down = FixedPointMath.mulDivDown(a, b, d);
        uint256 up = FixedPointMath.mulDivUp(a, b, d);
        assertTrue(up == down || up == down + 1);
    }
}
