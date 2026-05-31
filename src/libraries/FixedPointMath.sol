// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FixedPointMath
/// @notice 512-bit-intermediate mul-div with EXPLICIT rounding direction.
///         The Percolator engine's safety depends on direction-correct rounding:
///         floor for payouts, ceil for risk notional and fees. Solidity's native
///         `/` truncates toward zero — fine for the unsigned helpers here, but
///         signed floor-toward-(-inf) deltas (e.g. the A/K/F pnl_delta) are handled
///         explicitly in RiskEngine, NOT here.
/// @dev mulDiv is the canonical Remco Bloemen / OpenZeppelin algorithm (MIT),
///      inlined so the initial scaffold has no external dependency. When OZ lands
///      with the vaults milestone we may switch to `Math.mulDiv` for consistency.
library FixedPointMath {
    error MulDivOverflow();
    error DivByZero();

    /// @notice floor(a * b / denominator) with full 512-bit intermediate precision.
    function mulDivDown(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        unchecked {
            uint256 prod0; // least significant 256 bits of the product
            uint256 prod1; // most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                if (denominator == 0) revert DivByZero();
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) revert MulDivOverflow();

            // 512 by 256 division.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256 via Newton-Raphson (XOR seed is intentional).
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;

            result = prod0 * inverse;
        }
    }

    /// @notice ceil(a * b / denominator).
    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        uint256 d = mulDivDown(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            return d + 1;
        }
        return d;
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @notice floor(numerator / denominator) toward NEGATIVE INFINITY (denominator > 0).
    ///         Solidity `/` truncates toward zero; for negative numerators that rounds the
    ///         WRONG way (toward the trader). The A/K/F pnl_delta is specified floor-to-(-inf)
    ///         so losses round against the trader / in the vault's favor (spec §5.2).
    function divFloorSigned(int256 numerator, int256 denominator) internal pure returns (int256) {
        require(denominator > 0, "den<=0");
        int256 q = numerator / denominator;
        // If there is a remainder and the (negative) signs disagree, step down by one.
        if (numerator % denominator != 0 && numerator < 0) {
            q -= 1;
        }
        return q;
    }
}
