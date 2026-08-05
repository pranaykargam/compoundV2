// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./ComptrollerStorage.sol";
import "./PriceOracle.sol";

contract ComptrollerMarkets is ComptrollerStorage {
    constructor() {
        admin = msg.sender;
    }

    // ============ Admin Functions ============

    /// @notice Set the price oracle
    /// @param newOracle The new oracle contract
    function _setOracle(PriceOracle newOracle) external {
        require(msg.sender == admin, "Comptroller: only admin");
        require(newOracle.isPriceOracle(), "Comptroller: invalid oracle");

        PriceOracle oldOracle = oracle;
        oracle = newOracle;

        emit NewOracle(oldOracle, newOracle);
    }

    /// @notice Set the close factor (max liquidation repay fraction)
    /// @param newCloseFactorMantissa The new close factor (mantissa)
    function _setCloseFactor(uint256 newCloseFactorMantissa) external {
        require(msg.sender == admin, "Comptroller: only admin");
        require(newCloseFactorMantissa >= 0.05e18, "Comptroller: close factor too low");
        require(newCloseFactorMantissa <= 0.9e18, "Comptroller: close factor too high");

        uint256 old = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;

        emit NewCloseFactor(old, newCloseFactorMantissa);
    }

    /// @notice Set the liquidation incentive (bonus for liquidators)
    /// @param newLiquidationIncentiveMantissa The new incentive (mantissa, e.g., 1.08e18)
    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external {
        require(msg.sender == admin, "Comptroller: only admin");
        require(newLiquidationIncentiveMantissa >= 1e18, "Comptroller: incentive below 1.0");
        require(newLiquidationIncentiveMantissa <= 1.5e18, "Comptroller: incentive too high");

        uint256 old = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        emit NewLiquidationIncentive(old, newLiquidationIncentiveMantissa);
    }

    /// @notice Add a new market (cToken) to the Comptroller
    /// @param cToken The cToken contract to list
    function _supportMarket(address cToken) external {
        require(msg.sender == admin, "Comptroller: only admin");
        require(!markets[cToken].isListed, "Comptroller: market already listed");

        markets[cToken].isListed = true;
        markets[cToken].collateralFactorMantissa = 0; // Must be set separately

        emit MarketListed(cToken);
    }

    /// @notice Set the collateral factor for a market
    /// @param cToken The cToken market
    /// @param newCollateralFactorMantissa The new collateral factor (mantissa)
    function _setCollateralFactor(address cToken, uint256 newCollateralFactorMantissa) external {
        require(msg.sender == admin, "Comptroller: only admin");
        require(markets[cToken].isListed, "Comptroller: market not listed");
        require(newCollateralFactorMantissa <= 0.9e18, "Comptroller: factor too high");

        // Verify the oracle has a price for this market (safety check)
        require(oracle.getUnderlyingPrice(cToken) != 0, "Comptroller: oracle price is zero");

        uint256 old = markets[cToken].collateralFactorMantissa;
        markets[cToken].collateralFactorMantissa = newCollateralFactorMantissa;

        emit NewCollateralFactor(cToken, old, newCollateralFactorMantissa);
    }

    // ============ User Market Membership ============

    /// @notice Enter a list of markets (opt in to use them as collateral)
    /// @param cTokens The list of cToken markets to enter
    /// @return An array of 0s (success) for each market
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory) {
        uint256 len = cTokens.length;
        uint256[] memory results = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            results[i] = _addToMarketInternal(cTokens[i], msg.sender);
        }

        return results;
    }

    /// @notice Internal function to add a user to a market's membership
    /// @param cToken The market to enter
    /// @param borrower The user entering the market
    /// @return 0 on success
    function _addToMarketInternal(address cToken, address borrower) internal returns (uint256) {
        Market storage marketToJoin = markets[cToken];

        // Market must be listed
        require(marketToJoin.isListed, "Comptroller: market not listed");

        // Already a member? No-op (not an error)
        if (marketToJoin.accountMembership[borrower]) {
            return 0;
        }

        // Add to membership and track in the user's asset list
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(cToken);

        emit MarketEntered(cToken, borrower);
        return 0;
    }

    /// @notice Exit a market (stop using it as collateral)
    /// @param cToken The market to exit
    /// @return 0 on success
    function exitMarket(address cToken) external returns (uint256) {
        // Get the user's snapshot in this market
        (uint256 err, uint256 cTokenBalance, uint256 borrowBalance, ) =
            CTokenInterface(cToken).getAccountSnapshot(msg.sender);
        require(err == 0, "Comptroller: snapshot error");

        // Cannot exit if you have an outstanding borrow in this market
        require(borrowBalance == 0, "Comptroller: cannot exit market with active borrow");

        // Check if removing this collateral would cause a shortfall
        (uint256 errLiq, , uint256 shortfall) =
            _getHypotheticalAccountLiquidityInternal(msg.sender, cToken, cTokenBalance, 0);
        require(errLiq == 0, "Comptroller: liquidity calculation error");
        require(shortfall == 0, "Comptroller: insufficient liquidity to exit market");

        // Remove from membership
        Market storage marketToLeave = markets[cToken];
        require(marketToLeave.accountMembership[msg.sender], "Comptroller: not in market");
        marketToLeave.accountMembership[msg.sender] = false;

        // Remove from accountAssets array (swap and pop for gas efficiency)
        address[] storage userAssets = accountAssets[msg.sender];
        uint256 len = userAssets.length;
        for (uint256 i = 0; i < len; i++) {
            if (userAssets[i] == cToken) {
                userAssets[i] = userAssets[len - 1];
                userAssets.pop();
                break;
            }
        }

        emit MarketExited(cToken, msg.sender);
        return 0;
    }

    /// @dev Placeholder for the liquidity calculation. Implemented in 10-comptroller-liquidity-ref.sol.
    function _getHypotheticalAccountLiquidityInternal(
        address account,
        address cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view virtual returns (uint256, uint256, uint256) {
        // Will be overridden by ComptrollerLiquidity
        revert("Comptroller: liquidity not implemented");
    }
}