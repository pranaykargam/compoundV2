// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./ExponentialNoError.sol";
import "./PriceOracle.sol";

/// @title CTokenInterface — Minimal interface so the Comptroller can call CToken functions
/// @dev The full CToken is built in sections 04-07 and 12-17. This lets the Comptroller compile
///      without importing the entire CToken inheritance chain.
interface CTokenInterface {
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);
    function accrueInterest() external returns (uint256);
    function seize(address liquidator, address borrower, uint256 seizeTokens) external;
    function totalBorrows() external view returns (uint256);
    function borrowIndex() external view returns (uint256);
}

/// @title ComptrollerStorage — All state variables for the Comptroller
/// @notice The Comptroller is Compound's risk engine. It decides whether any given action
///         (mint, borrow, redeem, liquidate) is safe based on the user's total collateral
///         vs total borrows across ALL markets.
///
/// @dev Think of the Comptroller like a bank's risk department:
///      - Markets are the different loan products the bank offers
///      - collateralFactor is the LTV (loan-to-value) ratio for each product
///      - closeFactor controls how much of a bad loan can be repaid in one liquidation
///      - liquidationIncentive is the discount liquidators get on seized collateral
///
///      Comparison to Uniswap V2: Uniswap has no equivalent. Each Uniswap pair is
///      independent. Compound markets are interconnected through the Comptroller because
///      users can borrow from one market using collateral from another.
contract ComptrollerStorage is ExponentialNoError {

    /// @notice The address that can configure markets and parameters
    address public admin;

    /// @notice Oracle used to fetch underlying asset prices
    /// @dev All risk calculations depend on this oracle. A bad oracle = bad risk management.
    PriceOracle public oracle;

    /// @notice Maximum fraction of a borrow that can be repaid in a single liquidation
    /// @dev Typically 0.5e18 (50%). This prevents a liquidator from repaying 100% and
    ///      seizing all collateral in one transaction. It gives the borrower a chance to
    ///      recover. Also prevents price manipulation attacks from being too profitable.
    uint256 public closeFactorMantissa;

    /// @notice Bonus that liquidators receive on seized collateral
    /// @dev Typically 1.08e18 (108%), meaning liquidators get an 8% discount on collateral.
    ///      This incentivizes liquidators to keep the protocol solvent. Without this bonus,
    ///      nobody would bother liquidating underwater positions.
    uint256 public liquidationIncentiveMantissa;

    /// @notice Per-market configuration and state
    /// @dev The Market struct tracks:
    ///      - isListed: whether this cToken is recognized by the Comptroller
    ///      - collateralFactorMantissa: how much of this asset's value counts as collateral
    ///        (e.g., 0.75e18 means $100 of this asset provides $75 of borrowing power)
    ///      - accountMembership: tracks which users have "entered" this market (opted in
    ///        to use it as collateral). You must enter a market before it counts as collateral.
    struct Market {
        bool isListed;
        uint256 collateralFactorMantissa;
        mapping(address => bool) accountMembership;
    }

    /// @notice Maps cToken address to its Market configuration
    mapping(address => Market) public markets;

    /// @notice List of markets each user has entered (opted into as collateral)
    /// @dev When calculating liquidity, we iterate over this array for the given user.
    ///      This is why enterMarkets/exitMarket exist: they control what appears in this list.
    mapping(address => address[]) public accountAssets;

    // ============ Events ============

    event MarketListed(address cToken);
    event MarketEntered(address cToken, address account);
    event MarketExited(address cToken, address account);
    event NewOracle(PriceOracle oldOracle, PriceOracle newOracle);
    event NewCloseFactor(uint256 oldCloseFactor, uint256 newCloseFactor);
    event NewLiquidationIncentive(uint256 oldIncentive, uint256 newIncentive);
    event NewCollateralFactor(address cToken, uint256 oldFactor, uint256 newFactor);
}