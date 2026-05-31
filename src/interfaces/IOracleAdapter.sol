// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOracleAdapter
/// @notice Returns the EFFECTIVE ENGINE PRICE (e6) for a market after the capped
///         staircase clamp (raw target -> effective). Implementations wrap a tiered
///         source per the L1 oracle stack (docs/DESIGN.md):
///           - Tier A: Chainlink Data Feeds (free reads) for majors
///           - Tier B: Pyth / RedStone pull (bundled into the user tx) for mid-caps
///           - Tier C: Uniswap v3 geomean TWAP (+ caps + warmup) for long-tail cold-start
///         Separating raw target from effective price is load-bearing (spec §1.7):
///         a cap-violating raw jump must never be fed into live accrual.
interface IOracleAdapter {
    /// @return priceE6 effective engine price (quote atoms per base, e6), already staircase-clamped
    /// @return publishTs source timestamp of the underlying observation
    function effectivePrice() external view returns (uint256 priceE6, uint64 publishTs);

    /// @return rawTargetE6 latest validated raw target (pre-staircase), for divergence checks
    /// @return publishTs source timestamp
    function rawTarget() external view returns (uint256 rawTargetE6, uint64 publishTs);
}
