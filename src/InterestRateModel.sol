// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

/// @title InterestRateModel — Interface for interest rate calculations
/// @notice Each CToken market references an InterestRateModel to determine borrow and supply rates.
abstract contract InterestRateModel {
    /// @notice Indicator that this is an InterestRateModel contract (for validation)
    bool public constant isInterestRateModel = true;

    /// @notice Calculate the current borrow rate per block.
    /// @param cash The total amount of underlying tokens the market has
    /// @param borrows The total amount of underlying tokens borrowed
    /// @param reserves The total amount of underlying tokens held as reserves
    /// @return The borrow rate per block (as a mantissa, scaled by 1e18)
    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) virtual external view returns (uint256);

    /// @notice Calculate the current supply rate per block.
    /// @param cash The total amount of underlying tokens the market has
    /// @param borrows The total amount of underlying tokens borrowed
    /// @param reserves The total amount of underlying tokens held as reserves
    /// @param reserveFactorMantissa The current reserve factor (as a mantissa)
    /// @return The supply rate per block (as a mantissa, scaled by 1e18)
    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa) virtual external view returns (uint256);
}


/// @title JumpRateModel — Piecewise linear interest rate model with a kink
/// @notice Below the kink, rates increase gently. Above the kink, rates spike to incentivize
///         deposits and repayments. This is the production model used by most Compound markets.
///
/// @dev The kink creates a capital-efficiency incentive:
///      - Below kink: borrowing is cheap, utilization is healthy
///      - Above kink: borrowing is expensive, pushing utilization back down
///      - At 100%: rates are extremely high, nobody can withdraw (emergency)
contract JumpRateModel is InterestRateModel {
    /// @notice The approximate number of blocks per year (assuming ~12s block time)
    uint256 public constant blocksPerYear = 2_628_000;

    /// @notice The base interest rate (y-intercept) per block
    uint256 public baseRatePerBlock;

    /// @notice The slope of the rate below the kink, per block
    uint256 public multiplierPerBlock;

    /// @notice The slope of the rate above the kink, per block
    uint256 public jumpMultiplierPerBlock;

    /// @notice The utilization point at which the jump multiplier kicks in (e.g., 0.8e18 = 80%)
    uint256 public kink;

    /// @param baseRatePerYear The base interest rate per year (mantissa)
    /// @param multiplierPerYear The rate slope below the kink, per year (mantissa)
    /// @param jumpMultiplierPerYear The rate slope above the kink, per year (mantissa)
    /// @param kink_ The utilization kink point (mantissa)
    constructor(
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink_
    ) {
        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = kink_;
    }

    /// @notice Calculate the utilization rate of the market.
    /// @dev utilization = borrows / (cash + borrows - reserves)
    ///      Returns 0 if there are no borrows.
    function utilizationRate(uint256 cash, uint256 borrows, uint256 reserves) public pure returns (uint256) {
        if (borrows == 0) {
            return 0;
        }
        return (borrows * 1e18) / (cash + borrows - reserves);
    }

    /// @notice Calculate the borrow rate per block using the jump rate model.
    /// @dev Below kink: baseRate + multiplier * utilization
    ///      Above kink: baseRate + multiplier * kink + jumpMultiplier * (utilization - kink)
    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) override external view returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);

        if (util <= kink) {
            // Below the kink: gentle linear increase
            return baseRatePerBlock + (util * multiplierPerBlock / 1e18);
        } else {
            // Above the kink: base + gentle slope up to kink + steep slope above kink
            uint256 normalRate = baseRatePerBlock + (kink * multiplierPerBlock / 1e18);
            uint256 excessUtil = util - kink;
            return normalRate + (excessUtil * jumpMultiplierPerBlock / 1e18);
        }
    }

    /// @notice Calculate the supply rate per block.
    /// @dev supplyRate = borrowRate * (1 - reserveFactor) * utilizationRate
    ///      Suppliers earn less than borrowers pay because:
    ///      1. Only borrowed capital generates interest (utilization < 100%)
    ///      2. The protocol takes a cut (reserveFactor)
    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa) override external view returns (uint256) {
        uint256 oneMinusReserveFactor = 1e18 - reserveFactorMantissa;
        uint256 borrowRate = this.getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = (borrowRate * oneMinusReserveFactor) / 1e18;
        uint256 util = utilizationRate(cash, borrows, reserves);
        return (util * rateToPool) / 1e18;
    }
}
