// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PerpMarket} from "../src/PerpMarket.sol";
import {Types} from "../src/libraries/Types.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {IMatcher} from "../src/interfaces/IMatcher.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

contract PerpMarketTest is Test {
    PerpMarket market;
    MockERC20 token;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _validConfig(address collateral) internal pure returns (Types.MarketConfig memory) {
        return Types.MarketConfig({
            collateralToken: collateral,
            initialMarginBps: 1000, // 10x
            maintenanceBps: 500, // 5%
            tradingFeeBps: 30,
            liquidationFeeBps: 0,
            maxPriceMoveBpsPerSec: 1,
            maxAccrualDtSec: 100, // price_budget_bps = 100 (1%) -> solvency passes
            maxAbsFundingE9PerSec: 0,
            warmupMinSec: 0,
            warmupMaxSec: 3600,
            minLiquidationAbs: 0,
            liquidationFeeCap: 0,
            minNonzeroMmReq: 1,
            minNonzeroImReq: 2
        });
    }

    function setUp() public {
        token = new MockERC20(0);
        market = new PerpMarket();
        market.initialize(
            _validConfig(address(token)),
            IOracleAdapter(address(0)),
            IMatcher(address(0)),
            address(this)
        );

        token.mint(alice, 1_000_000 ether);
        token.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        token.approve(address(market), type(uint256).max);
        vm.prank(bob);
        token.approve(address(market), type(uint256).max);
    }

    // ---- init / config validation ----

    function test_initialize_twice_reverts() public {
        vm.expectRevert(PerpMarket.AlreadyInitialized.selector);
        market.initialize(
            _validConfig(address(token)),
            IOracleAdapter(address(0)),
            IMatcher(address(0)),
            address(this)
        );
    }

    function test_initialize_rejects_bad_shape() public {
        PerpMarket m = new PerpMarket();
        Types.MarketConfig memory c = _validConfig(address(token));
        c.maintenanceBps = 2000; // > initialMarginBps (1000) -> invalid
        vm.expectRevert(PerpMarket.InvalidConfig.selector);
        m.initialize(c, IOracleAdapter(address(0)), IMatcher(address(0)), address(this));
    }

    function test_initialize_rejects_solvency_failure() public {
        PerpMarket m = new PerpMarket();
        Types.MarketConfig memory c = _validConfig(address(token));
        c.maxPriceMoveBpsPerSec = 6; // price_budget 600 (6%) > maintenance 5% -> fails §1.6
        vm.expectRevert(PerpMarket.SolvencyEnvelopeFailed.selector);
        m.initialize(c, IOracleAdapter(address(0)), IMatcher(address(0)), address(this));
    }

    // ---- deposit ----

    function test_deposit_new_account() public {
        vm.prank(alice);
        uint256 id = market.deposit(0, 100 ether);
        assertEq(id, 1);
        assertEq(market.positionOwner(id), alice);

        Types.Account memory a = market.getAccount(id);
        assertEq(a.capital, 100 ether);
        assertTrue(a.materialized);

        Types.Globals memory g = market.globals();
        assertEq(g.vault, 100 ether);
        assertEq(g.cTot, 100 ether);
        assertEq(g.insurance, 0);
        assertEq(market.residual(), 0); // V == cTot, I == 0
    }

    function test_deposit_adds_to_existing() public {
        vm.startPrank(alice);
        uint256 id = market.deposit(0, 100 ether);
        market.deposit(id, 50 ether);
        vm.stopPrank();
        assertEq(market.getAccount(id).capital, 150 ether);
        assertEq(market.globals().vault, 150 ether);
    }

    function test_deposit_to_others_account_reverts() public {
        vm.prank(alice);
        uint256 id = market.deposit(0, 100 ether);
        vm.prank(bob);
        vm.expectRevert(PerpMarket.NotPositionOwner.selector);
        market.deposit(id, 10 ether);
    }

    function test_deposit_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PerpMarket.ZeroAmount.selector);
        market.deposit(0, 0);
    }

    function test_deposit_fee_on_transfer_credits_actual() public {
        MockERC20 fot = new MockERC20(200); // 2% fee on transfer
        PerpMarket m = new PerpMarket();
        m.initialize(
            _validConfig(address(fot)),
            IOracleAdapter(address(0)),
            IMatcher(address(0)),
            address(this)
        );
        fot.mint(alice, 1000 ether);
        vm.startPrank(alice);
        fot.approve(address(m), type(uint256).max);
        uint256 id = m.deposit(0, 100 ether);
        vm.stopPrank();
        // 2% burned in transfer -> only 98 actually arrived and is credited
        assertEq(m.getAccount(id).capital, 98 ether);
        assertEq(m.globals().vault, 98 ether);
        assertEq(fot.balanceOf(address(m)), 98 ether);
    }

    function test_deposit_vault_cap() public {
        // mint a whale enough to exceed MAX_VAULT_TVL and expect the cap to bite
        token.mint(alice, Constants.MAX_VAULT_TVL + 1 ether);
        vm.prank(alice);
        vm.expectRevert(PerpMarket.VaultCapExceeded.selector);
        market.deposit(0, Constants.MAX_VAULT_TVL + 1);
    }

    // ---- withdraw ----

    function test_withdraw_basic() public {
        vm.startPrank(alice);
        uint256 id = market.deposit(0, 100 ether);
        uint256 balBefore = token.balanceOf(alice);
        market.withdraw(id, 40 ether, alice);
        vm.stopPrank();

        assertEq(token.balanceOf(alice) - balBefore, 40 ether);
        assertEq(market.getAccount(id).capital, 60 ether);
        assertEq(market.globals().vault, 60 ether);
        assertEq(market.globals().cTot, 60 ether);
    }

    function test_withdraw_full() public {
        vm.startPrank(alice);
        uint256 id = market.deposit(0, 100 ether);
        market.withdraw(id, 100 ether, alice);
        vm.stopPrank();
        assertEq(market.getAccount(id).capital, 0);
        assertEq(market.globals().vault, 0);
    }

    function test_withdraw_more_than_capital_reverts() public {
        vm.startPrank(alice);
        uint256 id = market.deposit(0, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpMarket.InsufficientEquity.selector, int256(100 ether), 101 ether
            )
        );
        market.withdraw(id, 101 ether, alice);
        vm.stopPrank();
    }

    function test_withdraw_by_non_owner_reverts() public {
        vm.prank(alice);
        uint256 id = market.deposit(0, 100 ether);
        vm.prank(bob);
        vm.expectRevert(PerpMarket.NotPositionOwner.selector);
        market.withdraw(id, 1 ether, bob);
    }

    function test_withdraw_to_zero_reverts() public {
        vm.startPrank(alice);
        uint256 id = market.deposit(0, 100 ether);
        vm.expectRevert(PerpMarket.ZeroAddress.selector);
        market.withdraw(id, 1 ether, address(0));
        vm.stopPrank();
    }

    function test_withdraw_to_other_address() public {
        vm.startPrank(alice);
        uint256 id = market.deposit(0, 100 ether);
        market.withdraw(id, 30 ether, bob);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 1_000_000 ether + 30 ether);
    }

    // ---- conservation invariant (fuzz) ----

    function testFuzz_conservation_holds_after_deposit_withdraw(uint96 dep, uint96 wd) public {
        dep = uint96(bound(dep, 1, 1_000_000 ether));
        vm.startPrank(alice);
        uint256 id = market.deposit(0, dep);
        uint256 w = bound(wd, 0, dep);
        if (w > 0) market.withdraw(id, w, alice);
        vm.stopPrank();

        Types.Globals memory g = market.globals();
        assertGe(g.vault, g.cTot + g.insurance); // V >= C_tot + I
        assertEq(g.vault, uint256(dep) - w);
        assertEq(g.cTot, uint256(dep) - w);
    }

    // ---- reentrancy ----

    function test_reentrancy_blocked_on_withdraw() public {
        ReentrantToken rt = new ReentrantToken();
        PerpMarket m = new PerpMarket();
        m.initialize(
            _validConfig(address(rt)),
            IOracleAdapter(address(0)),
            IMatcher(address(0)),
            address(this)
        );

        rt.runAttack(address(m), 100 ether);

        // The re-entrant withdraw must have fired and been blocked.
        assertTrue(rt.reentryFired());
        assertTrue(rt.reentryWasBlocked());
        // Exactly the deposited amount was paid out — no double withdraw.
        assertEq(rt.balanceOf(address(rt)), 100 ether);
        assertEq(m.globals().vault, 0);
        assertGe(m.globals().vault, m.globals().cTot + m.globals().insurance);
    }

    // ---- pre-init guard ----

    function test_calls_before_init_revert() public {
        PerpMarket m = new PerpMarket();
        vm.expectRevert(PerpMarket.NotInitialized.selector);
        m.deposit(0, 1);
    }

    // ---- M2 stubs still revert ----

    function test_trade_not_implemented() public {
        vm.expectRevert(PerpMarket.NotImplemented.selector);
        market.trade(1, 1);
    }

    function test_liquidate_not_implemented() public {
        vm.expectRevert(PerpMarket.NotImplemented.selector);
        market.liquidate(1);
    }
}
