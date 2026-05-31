// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IMatcher
/// @notice Prices a trade against the passive LP. The DEFAULT implementation is an
///         oracle-anchored fixed-spread quoter:
///             exec = oracle * (1 +/- spreadBps)   (longs pay more, shorts receive less)
///         This is NOT a constant-product AMM — Percolator is oracle-priced; the LP
///         is a passive counterparty that captures the spread (confirmed against
///         percolator-matcher/matcher-program/src/amm.rs). Pluggable so an RFQ/router
///         can be swapped in later.
interface IMatcher {
    /// @param oraclePriceE6 effective engine price
    /// @param sizeQ signed requested size (base * POS_SCALE); >0 long, <0 short
    /// @return execPriceE6 fill price
    /// @return execSizeQ filled size (may be a partial fill)
    /// @return ok whether the quote is accepted
    function price(uint256 oraclePriceE6, int256 sizeQ)
        external
        view
        returns (uint256 execPriceE6, int256 execSizeQ, bool ok);
}
