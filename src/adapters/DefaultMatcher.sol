// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMatcher} from "../interfaces/IMatcher.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title DefaultMatcher
/// @notice Oracle-anchored fixed-spread quoter — a faithful EVM port of the Percolator
///         reference matcher (percolator-matcher/.../amm.rs). It is NOT a constant-product
///         AMM: there is no reserve curve and no price discovery here. The execution price
///         is simply the oracle price plus/minus a spread, and the passive LP captures the
///         spread:
///            long  (size > 0): exec = oracle * (1 + spread)   (pays more)
///            short (size < 0): exec = oracle * (1 - spread)    (receives less)
contract DefaultMatcher is IMatcher {
    uint256 public constant MAX_SPREAD_BPS = 500; // 5%
    uint256 public immutable spreadBps;

    error SpreadTooHigh();

    constructor(uint256 spreadBps_) {
        if (spreadBps_ > MAX_SPREAD_BPS) revert SpreadTooHigh();
        spreadBps = spreadBps_;
    }

    /// @inheritdoc IMatcher
    function price(uint256 oraclePriceE6, int256 sizeQ)
        external
        view
        returns (uint256 execPriceE6, int256 execSizeQ, bool ok)
    {
        if (oraclePriceE6 == 0 || sizeQ == 0) {
            return (0, 0, false);
        }
        if (sizeQ > 0) {
            // long pays oracle * (1 + spread); rounding up is in the LP's favor
            execPriceE6 = (oraclePriceE6 * (Constants.BPS_DENOM + spreadBps)) / Constants.BPS_DENOM;
        } else {
            // short receives oracle * (1 - spread); floor is in the LP's favor
            execPriceE6 = (oraclePriceE6 * (Constants.BPS_DENOM - spreadBps)) / Constants.BPS_DENOM;
        }
        return (execPriceE6, sizeQ, true);
    }
}
