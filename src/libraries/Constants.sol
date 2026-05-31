// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Constants
/// @notice Canonical fixed-point scales and hard bounds for the Percolator-Ethereum
///         risk engine. Ported from the Percolator spec (spec.md §1). These are the
///         load-bearing units the engine's EXACT integer math depends on — do not
///         change without re-running the §1.6 solvency proof.
library Constants {
    // ---- fixed-point scales (spec §1.1–§1.3) ----
    /// base position is stored as `base * POS_SCALE`.
    uint256 internal constant POS_SCALE = 1_000_000; // 1e6
    /// A-index scale; each side's A starts at ADL_ONE ("1.0").
    uint256 internal constant ADL_ONE = 1_000_000_000_000_000; // 1e15
    /// funding index scale.
    uint256 internal constant FUNDING_DEN = 1_000_000_000; // 1e9
    /// below this A, a side enters DrainOnly.
    uint256 internal constant MIN_A_SIDE = 100_000_000_000_000; // 1e14
    /// basis-points denominator.
    uint256 internal constant BPS_DENOM = 10_000;

    // ---- hard bounds (spec §1.4) ----
    /// quote atoms per 1 base; every price MUST satisfy 0 < price <= MAX_ORACLE_PRICE.
    uint256 internal constant MAX_ORACLE_PRICE = 1_000_000_000_000; // 1e12
    uint256 internal constant MAX_VAULT_TVL = 10_000_000_000_000_000; // 1e16
    uint256 internal constant MAX_POSITION_ABS_Q = 100_000_000_000_000; // 1e14
    uint256 internal constant MAX_OI_SIDE_Q = 100_000_000_000_000; // 1e14

    /// max liquidation price sentinel (short positions are unliquidatable when
    /// maintenance margin >= 100%); mirrors the SDK's max-u64 sentinel.
    uint256 internal constant LIQ_PRICE_UNREACHABLE = type(uint64).max;
}
