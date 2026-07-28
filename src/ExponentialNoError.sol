// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

/// @title ExponentialNoError — Fixed-point math for Compound V2
/// @notice All interest rate and exchange rate math uses 18-decimal fixed-point numbers called "mantissas."
/// @dev A mantissa of 1e18 represents 1.0. A mantissa of 0.5e18 represents 0.5.
///      This library provides safe arithmetic for these scaled values.

contract ExponentialNoError {
    uint256 constant expScale = 1e18;
    uint256 constant halfExpScale = expScale / 2;

    /// @dev A fixed-point number with 18 decimals of precision.
    struct Exp {
        uint256 mantissa;
    }

    /// @dev Like Exp but used for intermediate calculations where double precision is needed.
    struct Double {
        uint256 mantissa;
    }

    /// @notice Truncate an Exp to its integer part (discard the fractional part).
    /// @dev truncate(Exp{mantissa: 1.5e18}) = 1
    function truncate(Exp memory exp) internal pure returns (uint256) {
        return exp.mantissa / expScale;
    }

    /// @notice Multiply a uint by an Exp (scaled multiply, then truncate).
    /// @dev mul_ScalarTruncate(100, Exp{mantissa: 0.5e18}) = 50
    function mul_ScalarTruncate(Exp memory a, uint256 scalar) internal pure returns (uint256) {
        Exp memory product = mul_(a, scalar);
        return truncate(product);
    }

    /// @notice Multiply a uint by an Exp and add another uint.
    function mul_ScalarTruncateAddUInt(Exp memory a, uint256 scalar, uint256 addend) internal pure returns (uint256) {
        Exp memory product = mul_(a, scalar);
        return truncate(product) + addend;
    }

    /// @notice Multiply two Exp values, returning an Exp.
    /// @dev (a.mantissa * b.mantissa + halfExpScale) / expScale
    ///      The halfExpScale addition provides rounding to nearest.
    function mul_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({ mantissa: (a.mantissa * b.mantissa + halfExpScale) / expScale });
    }

    /// @notice Multiply an Exp by a uint, returning an Exp.
    function mul_(Exp memory a, uint256 b) internal pure returns (Exp memory) {
        return Exp({ mantissa: a.mantissa * b });
    }

    /// @notice Multiply two uints, returning a uint.
    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return (a * b.mantissa + halfExpScale) / expScale;
    }

    /// @notice Multiply two uints, returning a uint (plain multiply).
    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    /// @notice Divide two Exp values, returning an Exp.
    /// @dev (a.mantissa * expScale + b.mantissa / 2) / b.mantissa
    function div_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({ mantissa: (a.mantissa * expScale + b.mantissa / 2) / b.mantissa });
    }

    /// @notice Divide an Exp by a uint, returning an Exp.
    function div_(Exp memory a, uint256 b) internal pure returns (Exp memory) {
        return Exp({ mantissa: a.mantissa / b });
    }

    /// @notice Divide a uint by an Exp, returning a uint.
    function div_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return (a * expScale + b.mantissa / 2) / b.mantissa;
    }

    /// @notice Add two Exp values.
    function add_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({ mantissa: a.mantissa + b.mantissa });
    }

    /// @notice Subtract two Exp values.
    function sub_(Exp memory a, Exp memory b) internal pure returns (Exp memory) {
        return Exp({ mantissa: a.mantissa - b.mantissa });
    }

    /// @notice Check if an Exp is less than another.
    function lessThanExp(Exp memory left, Exp memory right) internal pure returns (bool) {
        return left.mantissa < right.mantissa;
    }

    /// @notice Check if an Exp is less than or equal to another.
    function lessThanOrEqualExp(Exp memory left, Exp memory right) internal pure returns (bool) {
        return left.mantissa <= right.mantissa;
    }

    /// @notice Check if an Exp is greater than another.
    function greaterThanExp(Exp memory left, Exp memory right) internal pure returns (bool) {
        return left.mantissa > right.mantissa;
    }

    /// @notice Check if an Exp is zero.
    function isZeroExp(Exp memory value) internal pure returns (bool) {
        return value.mantissa == 0;
    }
}
