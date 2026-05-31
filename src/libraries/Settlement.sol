// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Constants} from "./Constants.sol";
import {FixedPointMath} from "./FixedPointMath.sol";
import {Types} from "./Types.sol";

/// @title Settlement
/// @notice The lazy A/K/F per-account settlement math (Percolator spec §5.1–§5.2),
///         ported from the Rust engine's `effective_pos_q_checked` and
///         `compute_kf_pnl_delta`. Pure functions over an account + its side state, so
///         they are unit-testable in isolation exactly like the Rust unit tests.
///
/// @dev The whole point of A/K/F: a market-wide price/funding/ADL move mutates only the
///      two `SideState` accumulators (K, F) and the scaler A — never per-account storage.
///      Each account reconciles its share O(1) the next time it is "touched":
///        effective_pos = sign(basis) * floor(|basis| * A_side / a_basis)
///        pnl_delta     = floor( |basis| * ((K-kSnap)*FUNDING_DEN + (F-fSnap))
///                               / (a_basis * POS_SCALE * FUNDING_DEN) )   [floor → −∞]
library Settlement {
    using FixedPointMath for uint256;

    /// @notice Effective signed position (base * POS_SCALE). Zero if flat or if the
    ///         account's side epoch no longer matches (its basis was reset by ADL).
    function effectivePosQ(Types.Account memory a, Types.SideState memory side)
        internal
        pure
        returns (int256)
    {
        int256 basis = a.basisPosQ;
        if (basis == 0) return 0;
        if (a.epochSnap != side.epoch) return 0; // basis was reset out from under it
        require(a.aBasis > 0, "aBasis=0");

        uint256 absBasis = FixedPointMath.abs(basis);
        // floor(|basis| * A_side / a_basis)
        uint256 effAbs = FixedPointMath.mulDivDown(absBasis, side.a, a.aBasis);
        return basis > 0 ? int256(effAbs) : -int256(effAbs);
    }

    /// @notice The account's unsettled A/K/F PnL delta since its last snapshot.
    ///         Floor toward −∞ so losses round in the vault's favor (load-bearing).
    function kfPnlDelta(Types.Account memory a, Types.SideState memory side)
        internal
        pure
        returns (int256)
    {
        int256 basis = a.basisPosQ;
        if (basis == 0) return 0;
        require(a.aBasis > 0, "aBasis=0");

        int256 kDiff = side.k - a.kSnap;
        int256 fDiff = side.fNum - a.fSnap;
        uint256 absBasis = FixedPointMath.abs(basis);

        // inner = kDiff * FUNDING_DEN + fDiff   (signed)
        int256 inner = kDiff * int256(Constants.FUNDING_DEN) + fDiff;
        // numerator = |basis| * inner          (signed; |basis| <= 1e14, inner fits int256)
        int256 numerator = int256(absBasis) * inner;
        // denominator = a_basis * POS_SCALE * FUNDING_DEN   (positive)
        int256 denominator = int256(a.aBasis * Constants.POS_SCALE * Constants.FUNDING_DEN);

        return FixedPointMath.divFloorSigned(numerator, denominator);
    }

    /// @notice Risk notional of the effective position at `oraclePrice` (ceil — §1.2).
    function riskNotionalOf(
        Types.Account memory a,
        Types.SideState memory side,
        uint256 oraclePrice
    ) internal pure returns (uint256) {
        int256 eff = effectivePosQ(a, side);
        if (eff == 0) return 0;
        return FixedPointMath.mulDivUp(FixedPointMath.abs(eff), oraclePrice, Constants.POS_SCALE);
    }
}
