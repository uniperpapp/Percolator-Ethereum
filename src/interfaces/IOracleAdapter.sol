// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracleAdapter
/// @notice Supplies the latest validated RAW target price (e6) for a market. The market
///         owns `pLast` (the effective engine price) and applies the §1.7 capped staircase
///         itself, so the adapter's only job is to return a fresh, validated target from
///         its source tier:
///           - Tier A: Chainlink Data Feeds (free reads) for majors
///           - Tier B: Pyth / RedStone pull (bundled into the user tx) for mid-caps
///           - Tier C: Uniswap v3 geomean TWAP (+ liquidity gating) for long-tail cold-start
///         The raw-target-vs-effective-price separation (spec §1.7) lives in the market:
///         while the returned target differs from the effective price, the market restricts
///         risk-increasing user ops until the staircase catches up.
interface IOracleAdapter {
    /// @return priceE6 latest validated raw target (quote atoms per base, e6); MUST be > 0
    /// @return publishTs source timestamp / publish time of the observation
    function readTarget() external view returns (uint256 priceE6, uint64 publishTs);
}
