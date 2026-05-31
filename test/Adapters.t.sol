// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PushOracleAdapter} from "../src/adapters/PushOracleAdapter.sol";
import {DefaultMatcher} from "../src/adapters/DefaultMatcher.sol";
import {Constants} from "../src/libraries/Constants.sol";

contract AdaptersTest is Test {
    uint256 constant E6 = 1_000_000;

    // ---- PushOracleAdapter ----

    function test_push_and_read() public {
        PushOracleAdapter o = new PushOracleAdapter(address(this), 3600);
        o.pushPrice(100 * E6);
        (uint256 p, uint64 ts) = o.readTarget();
        assertEq(p, 100 * E6);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_push_only_authority() public {
        PushOracleAdapter o = new PushOracleAdapter(address(this), 0);
        vm.prank(address(0xBEEF));
        vm.expectRevert(PushOracleAdapter.NotAuthority.selector);
        o.pushPrice(100 * E6);
    }

    function test_push_rejects_out_of_range() public {
        PushOracleAdapter o = new PushOracleAdapter(address(this), 0);
        vm.expectRevert(PushOracleAdapter.InvalidPrice.selector);
        o.pushPrice(0);
        vm.expectRevert(PushOracleAdapter.InvalidPrice.selector);
        o.pushPrice(Constants.MAX_ORACLE_PRICE + 1);
    }

    function test_read_reverts_when_stale() public {
        PushOracleAdapter o = new PushOracleAdapter(address(this), 60);
        o.pushPrice(100 * E6);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(PushOracleAdapter.Stale.selector);
        o.readTarget();
    }

    function test_read_reverts_when_unset() public {
        PushOracleAdapter o = new PushOracleAdapter(address(this), 0);
        vm.expectRevert(PushOracleAdapter.InvalidPrice.selector);
        o.readTarget();
    }

    function test_set_authority() public {
        PushOracleAdapter o = new PushOracleAdapter(address(this), 0);
        o.setAuthority(address(0xCAFE));
        assertEq(o.authority(), address(0xCAFE));
        // old authority can no longer push
        vm.expectRevert(PushOracleAdapter.NotAuthority.selector);
        o.pushPrice(1 * E6);
    }

    // ---- DefaultMatcher ----

    function test_matcher_long_pays_spread() public {
        DefaultMatcher m = new DefaultMatcher(30); // 0.30%
        (uint256 exec, int256 size, bool ok) = m.price(50 * E6, int256(1000));
        // 50e6 * 10030 / 10000 = 50_150_000
        assertEq(exec, 50_150_000);
        assertEq(size, int256(1000));
        assertTrue(ok);
    }

    function test_matcher_short_receives_less() public {
        DefaultMatcher m = new DefaultMatcher(30);
        (uint256 exec, int256 size, bool ok) = m.price(50 * E6, -int256(1000));
        // 50e6 * 9970 / 10000 = 49_850_000
        assertEq(exec, 49_850_000);
        assertEq(size, -int256(1000));
        assertTrue(ok);
    }

    function test_matcher_rejects_zero() public {
        DefaultMatcher m = new DefaultMatcher(30);
        (,, bool ok1) = m.price(0, int256(1));
        (,, bool ok2) = m.price(50 * E6, 0);
        assertFalse(ok1);
        assertFalse(ok2);
    }

    function test_matcher_spread_cap() public {
        vm.expectRevert(DefaultMatcher.SpreadTooHigh.selector);
        new DefaultMatcher(501);
    }

    function test_matcher_zero_spread() public {
        DefaultMatcher m = new DefaultMatcher(0);
        (uint256 exec,,) = m.price(50 * E6, int256(1));
        assertEq(exec, 50 * E6);
    }
}
