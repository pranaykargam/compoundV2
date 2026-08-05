// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./ComptrollerMarkets.sol";

/// @title ComptrollerLiquidity — Account liquidity calculation
/// @notice This is the CORE risk engine of Compound V2. It answers the question:
///         "Is this user solvent?" by summing up all their collateral and borrows
///         across every market they've entered.
///
/// @dev How it works:
///      For each market the user has entered:
///        1. Get the user's cToken balance and borrow balance
///        2. Get the current exchange rate (cTokens -> underlying)
///        3. Get the oracle price (underlying -> USD/ETH)
///        4. Collateral value = cTokenBalance * exchangeRate * oraclePrice * collateralFactor
///        5. Borrow value = borrowBalance * oraclePrice
///
///      Then sum across all markets:
///        - If total collateral > total borrows: user has "liquidity" (excess collateral)
///        - If total borrows > total collateral: user has "shortfall" (undercollateralized)
///
///      Comparison to Uniswap V2: Uniswap has no concept of solvency. Each LP position
///      is self-contained. Compound's cross-market solvency check is what enables
///      borrowing: you deposit ETH, and the Comptroller calculates how much USDC you
///      can borrow against it.
///
///      The "hypothetical" variant lets us answer "what IF the user did X?" without
///      actually doing it. This is used to CHECK whether a borrow/redeem is safe before
///      allowing it.
contract ComptrollerLiquidity is ComptrollerMarkets {

    /// @notice Get the current liquidity/shortfall for an account
    /// @dev This is the public entry point. It calls the internal hypothetical function
    ///      with no modifications (no hypothetical redeem or borrow).
    /// @param account The account to check
    /// @return error Always 0 in this simplified version
    /// @return liquidity Excess collateral value (in USD/ETH units). If > 0, user can borrow more.
    /// @return shortfall Collateral deficit (in USD/ETH units). If > 0, user can be liquidated.
    function getAccountLiquidity(address account) public view returns (uint256, uint256, uint256) {
        return _getHypotheticalAccountLiquidityInternal(account, address(0), 0, 0);
    }

    /// @notice Calculate hypothetical liquidity after a potential action
    /// @dev This is the heart of Compound's risk management. Every safety check in the
    ///      protocol flows through this function:
    ///
    ///      - borrowAllowed: "What if this user borrows X more?" -> check no shortfall
    ///      - redeemAllowed: "What if this user redeems X cTokens?" -> check no shortfall
    ///      - liquidateBorrowAllowed: "Does this user have shortfall?" -> check shortfall > 0
    ///      - exitMarket: "What if this user removes all collateral from market X?" -> check no shortfall
    ///
    ///      The algorithm iterates ALL markets the user has entered, which is why Compound
    ///      limits the number of markets a user can enter (to bound gas costs).
    ///
    /// @param account The account to calculate liquidity for
    /// @param cTokenModify The market being modified (if any). Pass address(0) for current state.
    /// @param redeemTokens If cTokenModify is set, simulate redeeming this many cTokens
    /// @param borrowAmount If cTokenModify is set, simulate borrowing this much underlying
    /// @return error Always 0 in this simplified version
    /// @return liquidity Excess collateral (0 if shortfall exists)
    /// @return shortfall Collateral deficit (0 if liquidity exists)
    function _getHypotheticalAccountLiquidityInternal(
        address account,
        address cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view override returns (uint256, uint256, uint256) {

        // Accumulators for total collateral and total borrows (in oracle price units)
        uint256 sumCollateral = 0;
        uint256 sumBorrowPlusEffects = 0;

        // Iterate over all markets the user has entered
        address[] memory assets = accountAssets[account];

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            // 1. Get the user's position in this market
            //    Returns: (error, cTokenBalance, borrowBalance, exchangeRateMantissa)
            (uint256 err, uint256 cTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa) =
                CTokenInterface(asset).getAccountSnapshot(account);
            require(err == 0, "Comptroller: snapshot failed");

            // 2. Get the collateral factor for this market
            //    collateralFactor = how much of this asset's value counts as collateral
            uint256 collateralFactorMantissa = markets[asset].collateralFactorMantissa;

            // 3. Get the oracle price for this asset
            uint256 oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            require(oraclePriceMantissa > 0, "Comptroller: oracle price is zero");

            // 4. Calculate this market's contribution to collateral
            //    tokensToDenom = collateralFactor * exchangeRate * oraclePrice
            //    This converts cToken balance directly to a dollar value adjusted for risk
            //
            //    Step by step:
            //    a) cTokenBalance * exchangeRate = underlying balance
            //    b) underlying balance * oraclePrice = dollar value
            //    c) dollar value * collateralFactor = risk-adjusted collateral value
            //
            //    We combine all three multiplications for efficiency.
            Exp memory collateralFactor = Exp({ mantissa: collateralFactorMantissa });
            Exp memory exchangeRate = Exp({ mantissa: exchangeRateMantissa });
            Exp memory oraclePrice = Exp({ mantissa: oraclePriceMantissa });

            // tokensToDenom = collateralFactor * exchangeRate * oraclePrice
            Exp memory tokensToDenom = mul_(mul_(collateralFactor, exchangeRate), oraclePrice);

            // sumCollateral += cTokenBalance * tokensToDenom
            sumCollateral += mul_ScalarTruncate(tokensToDenom, cTokenBalance);

            // 5. Calculate this market's contribution to borrows
            //    borrowValue = borrowBalance * oraclePrice
            sumBorrowPlusEffects += mul_(borrowBalance, oraclePrice);

            // 6. Apply hypothetical modifications (if this is the market being modified)
            //    This is the "what if" part: we adjust the sums as if the action already happened.
            if (asset == cTokenModify) {
                // If redeeming: reduce collateral by the redeemed amount
                // sumCollateral -= redeemTokens * tokensToDenom
                sumBorrowPlusEffects += mul_ScalarTruncate(tokensToDenom, redeemTokens);

                // If borrowing: increase borrows by the borrowed amount
                // sumBorrows += borrowAmount * oraclePrice
                sumBorrowPlusEffects += mul_(borrowAmount, oraclePrice);
            }
        }

        // 7. Calculate final liquidity or shortfall
        //    Only one of these can be non-zero (you either have excess or deficit, never both)
        if (sumCollateral > sumBorrowPlusEffects) {
            return (0, sumCollateral - sumBorrowPlusEffects, 0);
        } else {
            return (0, 0, sumBorrowPlusEffects - sumCollateral);
        }
    }
}
