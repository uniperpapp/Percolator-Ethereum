// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Constants} from "./Constants.sol";
import {FixedPointMath} from "./FixedPointMath.sol";

/// @title PerpMath
/// @notice Coin-margined perpetual trade math, ported faithfully from the
///         Percolator TS SDK (percolator-sdk/src/math/trading.ts). Display +
///         estimation helpers and the fee schedule. Prices are in e6.
///
/// @dev On-chain PnL formula (coin-margined — note the division by oracle):
///        mark_pnl = (oracle - entry) * |pos| / oracle   (longs)
///        mark_pnl = (entry - oracle) * |pos| / oracle   (shorts)
library PerpMath {
    /// @notice mark-to-market PnL for an open position (token units).
    function markPnl(int256 positionSize, uint256 entryPrice, uint256 oraclePrice)
        internal
        pure
        returns (int256)
    {
        if (positionSize == 0 || oraclePrice == 0) return 0;
        uint256 absPos = FixedPointMath.abs(positionSize);
        if (positionSize > 0) {
            // long: gains when oracle > entry
            if (oraclePrice >= entryPrice) {
                return
                    int256(FixedPointMath.mulDivDown(oraclePrice - entryPrice, absPos, oraclePrice));
            }
            return -int256(FixedPointMath.mulDivDown(entryPrice - oraclePrice, absPos, oraclePrice));
        } else {
            // short: gains when entry > oracle
            if (entryPrice >= oraclePrice) {
                return
                    int256(FixedPointMath.mulDivDown(entryPrice - oraclePrice, absPos, oraclePrice));
            }
            return -int256(FixedPointMath.mulDivDown(oraclePrice - entryPrice, absPos, oraclePrice));
        }
    }

    /// @notice Liquidation price. Longs liquidate when price falls; shorts when it rises.
    ///         Returns LIQ_PRICE_UNREACHABLE for shorts with maintenance >= 100%.
    function liqPrice(uint256 entryPrice, uint256 capital, int256 positionSize, uint256 maintBps)
        internal
        pure
        returns (uint256)
    {
        if (positionSize == 0 || entryPrice == 0) return 0;
        uint256 absPos = FixedPointMath.abs(positionSize);
        uint256 capPerUnitE6 = FixedPointMath.mulDivDown(capital, Constants.POS_SCALE, absPos);
        if (positionSize > 0) {
            uint256 adjusted = FixedPointMath.mulDivDown(
                capPerUnitE6, Constants.BPS_DENOM, Constants.BPS_DENOM + maintBps
            );
            return entryPrice > adjusted ? entryPrice - adjusted : 0;
        } else {
            if (maintBps >= Constants.BPS_DENOM) return Constants.LIQ_PRICE_UNREACHABLE;
            uint256 adjusted = FixedPointMath.mulDivDown(
                capPerUnitE6, Constants.BPS_DENOM, Constants.BPS_DENOM - maintBps
            );
            return entryPrice + adjusted;
        }
    }

    /// @notice trading fee = ceil(notional * feeBps / 10_000). Ceil prevents
    ///         fee evasion via micro-trades (matches on-chain SDK behavior).
    function tradingFee(uint256 notional, uint256 feeBps) internal pure returns (uint256) {
        if (notional == 0 || feeBps == 0) return 0;
        return FixedPointMath.mulDivUp(notional, feeBps, Constants.BPS_DENOM);
    }

    /// @notice Split a total fee into (lp, protocol, creator). Creator receives the
    ///         rounding remainder so the total is exactly preserved. If all split
    ///         params are zero, 100% goes to LP (legacy behavior).
    function feeSplit(uint256 totalFee, uint256 lpBps, uint256 protocolBps)
        internal
        pure
        returns (uint256 lp, uint256 protocol, uint256 creator)
    {
        if (lpBps == 0 && protocolBps == 0) {
            return (totalFee, 0, 0);
        }
        lp = FixedPointMath.mulDivDown(totalFee, lpBps, Constants.BPS_DENOM);
        protocol = FixedPointMath.mulDivDown(totalFee, protocolBps, Constants.BPS_DENOM);
        creator = totalFee - lp - protocol;
    }

    /// @notice margin required for a notional at a given initial-margin bps.
    function requiredMargin(uint256 notional, uint256 initialMarginBps)
        internal
        pure
        returns (uint256)
    {
        return FixedPointMath.mulDivDown(notional, initialMarginBps, Constants.BPS_DENOM);
    }

    /// @notice max leverage (integer x) from initial-margin bps.
    function maxLeverageX(uint256 initialMarginBps) internal pure returns (uint256) {
        require(initialMarginBps > 0, "IM=0");
        return Constants.BPS_DENOM / initialMarginBps;
    }
}
