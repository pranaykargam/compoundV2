// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./ExponentialNoError.sol";
import "./PriceOracle.sol";
import "./ComptrollerMarkets.sol";

/// @title Liquidation Comptroller Reference — Focused view of liquidation policy
/// @notice This file provides a focused reference for the Comptroller's liquidation logic.
///         The same functions are declared in 11-comptroller-hooks-ref.sol as part of the full
///         Comptroller. This file isolates them with detailed commentary for the liquidation
///         module.
///
/// @dev WHY LIQUIDATION EXISTS:
///      Compound is an overcollateralized lending protocol. Users deposit $150 of ETH to
///      borrow $100 of USDC. But if ETH drops in price, that $150 might become $95. Now
///      the protocol has $100 of debt backed by only $95 of collateral. This is "bad debt,"
///      and if left unchecked, it means the protocol cannot repay all depositors.
///
///      Liquidation prevents bad debt by letting third-party "liquidators" repay an
///      underwater borrower's debt in exchange for their collateral (at a discount).
///      The discount incentivizes liquidators to act quickly, keeping the protocol solvent.
///
///      THE LIQUIDATION FLOW (end to end):
///      1. A borrower's collateral value drops below their borrow value (shortfall > 0)
///      2. A liquidator calls cTokenBorrowed.liquidateBorrow(borrower, repayAmount, cTokenCollateral)
///      3. CToken calls comptroller.liquidateBorrowAllowed() — THIS FILE, function below
///      4. CToken repays part of the borrower's debt (using the liquidator's funds)
///      5. CToken calls comptroller.liquidateCalculateSeizeTokens() — THIS FILE, function below
///      6. CToken calls cTokenCollateral.seize() to transfer collateral to the liquidator
///
///      Comparison to Uniswap V2: Uniswap has no liquidation because it has no lending.
///      The closest parallel in DeFi is Aave's liquidation mechanism, which follows a
///      very similar pattern (close factor, liquidation bonus, health factor check).
///
///      KEY PARAMETERS:
///      - closeFactorMantissa (typically 0.5e18 = 50%): Maximum fraction of a borrow
///        that can be repaid in a single liquidation. Prevents over-liquidation.
///      - liquidationIncentiveMantissa (typically 1.08e18 = 108%): The bonus liquidators
///        receive. A 1.08 incentive means for every $100 of debt repaid, the liquidator
///        receives $108 worth of collateral.
///      - protocolSeizeShareMantissa (2.8%): Of the seized collateral, this fraction goes
///        to the protocol as reserves. The liquidator gets the rest (97.2%).

/// @notice Standalone reference showing the Comptroller's liquidation policy checks.
///         Not meant to be deployed independently. See 11-comptroller-hooks-ref.sol for the
///         integrated version.
contract LiquidationComptrollerReference is ExponentialNoError {

    // ============ State (duplicated here for standalone readability) ============

    PriceOracle public oracle;
    uint256 public closeFactorMantissa;      // e.g., 0.5e18 = 50%
    uint256 public liquidationIncentiveMantissa; // e.g., 1.08e18 = 108%

    /// @notice Determine whether a liquidation should be allowed
    /// @dev Three requirements must all pass:
    ///
    ///      REQUIREMENT 1: Both markets are listed
    ///      Why? An unlisted market has no collateral factor, no oracle price, and no
    ///      Comptroller oversight. Allowing liquidation on unlisted markets would be
    ///      operating in the dark.
    ///
    ///      REQUIREMENT 2: Borrower has shortfall (is undercollateralized)
    ///      Why? Liquidation is a PENALTY mechanism. It should only trigger when the
    ///      borrower's position is actually at risk. Allowing liquidation of healthy
    ///      positions would be theft, not risk management.
    ///
    ///      How shortfall is calculated (see 10-comptroller-liquidity-ref.sol):
    ///        For each market the borrower entered:
    ///          collateral += cTokenBalance * exchangeRate * oraclePrice * collateralFactor
    ///          borrows += borrowBalance * oraclePrice
    ///        shortfall = max(0, borrows - collateral)
    ///
    ///      REQUIREMENT 3: repayAmount <= closeFactor * borrowerBorrowBalance
    ///      Why? The closeFactor (typically 50%) limits how much can be liquidated at once.
    ///      This serves two purposes:
    ///        a) Fairness: the borrower keeps some collateral and can try to recover
    ///        b) Security: limits the profit from a price manipulation attack. If an
    ///           attacker manipulates the oracle to make a position appear underwater,
    ///           they can only seize closeFactor * borrow worth of collateral, not all of it.
    ///
    /// @param cTokenBorrowed The cToken market where the borrower has debt
    /// @param cTokenCollateral The cToken market where collateral will be seized
    /// @param borrower The account being liquidated
    /// @param repayAmount The amount of borrowed asset the liquidator wants to repay
    /// @return 0 if liquidation is allowed
    function liquidateBorrowAllowed(
        address cTokenBorrowed,
        address cTokenCollateral,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256) {
        // REQUIREMENT 1: Both markets must be recognized by this Comptroller
        // (In the full Comptroller, this checks markets[cToken].isListed)

        // REQUIREMENT 2: Borrower must be underwater
        // getAccountLiquidity returns (error, liquidity, shortfall)
        // shortfall > 0 means borrows exceed collateral
        // (In the full Comptroller, this calls getAccountLiquidity(borrower))

        // REQUIREMENT 3: repayAmount must respect the close factor
        // Get the borrower's borrow balance in the borrowed market
        (, , uint256 borrowerBorrowBalance, ) =
            CTokenInterface(cTokenBorrowed).getAccountSnapshot(borrower);

        // maxClose = closeFactor * borrowerBorrowBalance
        //
        // Example: If borrower owes 1000 USDC and closeFactor is 50%,
        // the liquidator can repay at most 500 USDC in one transaction.
        uint256 maxClose = mul_ScalarTruncate(
            Exp({ mantissa: closeFactorMantissa }),
            borrowerBorrowBalance
        );
        require(repayAmount <= maxClose, "Comptroller: repay amount exceeds close factor limit");

        return 0;
    }

    /// @notice Calculate the number of collateral cTokens to seize in a liquidation
    /// @dev The formula converts the repaid debt value into collateral cTokens:
    ///
    ///      seizeTokens = (repayAmount * liquidationIncentive * priceBorrowed)
    ///                  / (priceCollateral * exchangeRate)
    ///
    ///      STEP-BY-STEP WALKTHROUGH:
    ///
    ///      Given:
    ///        repayAmount = 500 USDC
    ///        liquidationIncentive = 1.08 (8% bonus)
    ///        priceBorrowed (USDC) = 1.0 (in ETH or USD units)
    ///        priceCollateral (ETH) = 2000.0
    ///        exchangeRate (cETH -> ETH) = 0.02
    ///
    ///      Step 1: Dollar value of repayment = 500 * 1.0 = $500
    ///      Step 2: With incentive = 500 * 1.08 = $540 worth of collateral to seize
    ///      Step 3: In ETH terms = 540 / 2000 = 0.27 ETH
    ///      Step 4: In cETH terms = 0.27 / 0.02 = 13.5 cETH
    ///
    ///      So the liquidator pays 500 USDC of the borrower's debt and receives 13.5 cETH
    ///      (worth $540 in ETH). The $40 difference is the liquidator's profit.
    ///
    ///      WHY THE EXCHANGE RATE MATTERS:
    ///      We seize cTokens, not underlying. The exchange rate converts from underlying
    ///      value to cToken quantity. If we seized underlying directly, we'd break the
    ///      cToken accounting (totalSupply wouldn't match actual balances).
    ///
    /// @param cTokenBorrowed The market where debt was repaid (for oracle price)
    /// @param cTokenCollateral The market being seized (for oracle price and exchange rate)
    /// @param actualRepayAmount The actual amount of underlying repaid
    /// @return error Always 0 in this simplified version
    /// @return seizeTokens The number of cTokens to seize
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        // Get oracle prices for both the borrowed and collateral assets
        uint256 priceBorrowed = oracle.getUnderlyingPrice(cTokenBorrowed);
        uint256 priceCollateral = oracle.getUnderlyingPrice(cTokenCollateral);
        require(priceBorrowed > 0 && priceCollateral > 0, "Comptroller: oracle price is zero");

        // Get the collateral cToken's exchange rate (cToken -> underlying)
        (, , , uint256 exchangeRateMantissa) =
            CTokenInterface(cTokenCollateral).getAccountSnapshot(address(0));

        // numerator = liquidationIncentive * priceBorrowed
        // This gives us the "boosted" value per unit of borrowed asset
        Exp memory numerator = mul_(
            Exp({ mantissa: liquidationIncentiveMantissa }),
            Exp({ mantissa: priceBorrowed })
        );

        // denominator = priceCollateral * exchangeRate
        // This gives us the value per cToken of collateral
        Exp memory denominator = mul_(
            Exp({ mantissa: priceCollateral }),
            Exp({ mantissa: exchangeRateMantissa })
        );

        // ratio = numerator / denominator
        // This is the conversion factor: how many cTokens per unit of borrowed asset
        Exp memory ratio = div_(numerator, denominator);

        // seizeTokens = ratio * actualRepayAmount
        uint256 seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (0, seizeTokens);
    }
}
