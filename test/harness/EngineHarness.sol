// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Types} from "../../src/libraries/Types.sol";
import {Accrual} from "../../src/libraries/Accrual.sol";
import {Settlement} from "../../src/libraries/Settlement.sol";

/// @notice Thin storage-holding harness so the storage-based Accrual library and the
///         memory-based Settlement library can be unit-tested in isolation (mirrors the
///         Rust engine's pure unit tests).
contract EngineHarness {
    using Accrual for Types.Globals;

    Types.Globals internal g;
    Types.MarketConfig internal cfg;

    function setConfig(uint64 maxPriceMoveBpsPerSec, uint64 maxAccrualDtSec) external {
        cfg.maxPriceMoveBpsPerSec = maxPriceMoveBpsPerSec;
        cfg.maxAccrualDtSec = maxAccrualDtSec;
    }

    function seed(uint256 a, uint64 pLast, uint64 slotLast, uint256 oiLong, uint256 oiShort)
        external
    {
        g.longSide.a = a;
        g.shortSide.a = a;
        g.pLast = pLast;
        g.fundPxLast = pLast;
        g.slotLast = slotLast;
        g.longSide.oiEffQ = oiLong;
        g.shortSide.oiEffQ = oiShort;
    }

    function accrue(uint256 effPrice, int256 fundingRateE9PerSec, uint256 nowTs) external {
        Accrual.accrue(g, cfg, effPrice, fundingRateE9PerSec, nowTs);
    }

    function staircase(uint256 pLast, uint256 target, uint256 rate, uint256 dt)
        external
        pure
        returns (uint256)
    {
        return Accrual.staircaseNext(pLast, target, rate, dt);
    }

    function kLong() external view returns (int256) {
        return g.longSide.k;
    }

    function kShort() external view returns (int256) {
        return g.shortSide.k;
    }

    function fLong() external view returns (int256) {
        return g.longSide.fNum;
    }

    function fShort() external view returns (int256) {
        return g.shortSide.fNum;
    }

    function pLast() external view returns (uint64) {
        return g.pLast;
    }

    function slotLast() external view returns (uint64) {
        return g.slotLast;
    }

    // ---- Settlement wrappers ----

    function effectivePosQ(Types.Account memory a, Types.SideState memory side)
        external
        pure
        returns (int256)
    {
        return Settlement.effectivePosQ(a, side);
    }

    function kfPnlDelta(Types.Account memory a, Types.SideState memory side)
        external
        pure
        returns (int256)
    {
        return Settlement.kfPnlDelta(a, side);
    }
}
