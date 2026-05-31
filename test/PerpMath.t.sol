// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @notice Tests for the coin-margined trade math ported from the Percolator SDK.
///         Values mirror the SDK's documented behaviour (e6 prices).
contract PerpMathTest is Test {
    uint256 constant E6 = 1_000_000;

    // ----- markPnl -----

    function test_markPnl_long_profit() public pure {
        // 1.0 base long, entry 50.0, oracle 60.0:
        // (60e6-50e6)*1e6/60e6 = 1e13/6e7 = 166_666 (floor)
        int256 pnl = PerpMath.markPnl(int256(1 * E6), 50 * E6, 60 * E6);
        assertEq(pnl, int256(166_666));
    }

    function test_markPnl_long_loss() public pure {
        int256 pnl = PerpMath.markPnl(int256(1 * E6), 50 * E6, 40 * E6);
        // (40e6-50e6) -> loss: (50-40)e6*1e6/40e6 = 250_000
        assertEq(pnl, -int256(250_000));
    }

    function test_markPnl_short_profit() public pure {
        // short profits when price falls: entry 50, oracle 40 -> (50-40)e6*1e6/40e6 = 250_000
        int256 pnl = PerpMath.markPnl(-int256(1 * E6), 50 * E6, 40 * E6);
        assertEq(pnl, int256(250_000));
    }

    function test_markPnl_zero() public pure {
        assertEq(PerpMath.markPnl(0, 50 * E6, 60 * E6), int256(0));
        assertEq(PerpMath.markPnl(int256(E6), 50 * E6, 0), int256(0));
    }

    // ----- liqPrice -----

    function test_liqPrice_long() public pure {
        // entry 50, capital 10 tokens, 1.0 base, maint 5% (500bps)
        // capPerUnit = 10e6*1e6/1e6 = 10e6; adjusted = 10e6*10000/10500 = 9_523_809
        // liq = 50e6 - 9_523_809 = 40_476_191
        uint256 liq = PerpMath.liqPrice(50 * E6, 10 * E6, int256(1 * E6), 500);
        assertEq(liq, 40_476_191);
        assertLt(liq, 50 * E6);
    }

    function test_liqPrice_short_rises() public pure {
        uint256 liq = PerpMath.liqPrice(50 * E6, 10 * E6, -int256(1 * E6), 500);
        // adjusted = 10e6*10000/9500 = 10_526_315; liq = 60_526_315
        assertEq(liq, 60_526_315);
        assertGt(liq, 50 * E6);
    }

    function test_liqPrice_short_unliquidatable_at_full_maint() public pure {
        uint256 liq = PerpMath.liqPrice(50 * E6, 10 * E6, -int256(1 * E6), Constants.BPS_DENOM);
        assertEq(liq, Constants.LIQ_PRICE_UNREACHABLE);
    }

    // ----- fees -----

    function test_tradingFee_ceil() public pure {
        // 333 * 30bps = 9990/10000 = 0.999 -> ceil 1
        assertEq(PerpMath.tradingFee(333, 30), 1);
        // exact multiple: 1000 * 30bps = 3
        assertEq(PerpMath.tradingFee(1000, 30), 3);
        assertEq(PerpMath.tradingFee(0, 30), 0);
        assertEq(PerpMath.tradingFee(1000, 0), 0);
    }

    function test_feeSplit_remainder_to_creator() public pure {
        (uint256 lp, uint256 protocol, uint256 creator) = PerpMath.feeSplit(1000, 8000, 1000);
        assertEq(lp, 800);
        assertEq(protocol, 100);
        assertEq(creator, 100);
        assertEq(lp + protocol + creator, 1000);
    }

    function test_feeSplit_all_zero_goes_to_lp() public pure {
        (uint256 lp, uint256 protocol, uint256 creator) = PerpMath.feeSplit(1000, 0, 0);
        assertEq(lp, 1000);
        assertEq(protocol, 0);
        assertEq(creator, 0);
    }

    // ----- margin / leverage -----

    function test_maxLeverage() public pure {
        assertEq(PerpMath.maxLeverageX(1000), 10); // 10% IM -> 10x
        assertEq(PerpMath.maxLeverageX(500), 20); // 5% IM -> 20x
    }

    function test_requiredMargin() public pure {
        // 10x: notional 10_000 -> margin 1_000
        assertEq(PerpMath.requiredMargin(10_000, 1000), 1_000);
    }
}
