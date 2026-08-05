// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./CTokenRepay.sol";

interface CTokenInterface {
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);
    function accrueInterest() external returns (uint256);
    function seize(address liquidator, address borrower, uint256 seizeTokens) external;
}

/// @title CToken Liquidation — Liquidating underwater positions
/// @notice When a borrower becomes undercollateralized (their borrows exceed their
///         risk-adjusted collateral), anyone can call liquidateBorrow to repay part
///         of the borrower's debt and seize their collateral at a discount.
///
/// @dev THE COMPLETE LIQUIDATION SEQUENCE:
///
///      1. TRIGGER: Borrower's collateral value drops (price change, interest accrual)
///         until shortfall > 0 (borrows > risk-adjusted collateral)
///
///      2. LIQUIDATOR ACTION: Calls cTokenBorrowed.liquidateBorrow(borrower, repayAmount, cTokenCollateral)
///         The liquidator chooses:
///         - Which borrow to repay (cTokenBorrowed)
///         - How much to repay (limited by closeFactor)
///         - Which collateral to seize (cTokenCollateral)
///
///      3. INTEREST ACCRUAL: Both the borrowed and collateral markets accrue interest
///         (ensures exchange rates and borrow balances are current)
///
///      4. POLICY CHECK: Comptroller.liquidateBorrowAllowed() verifies:
///         - Both markets are listed
///         - Borrower is actually underwater
///         - repayAmount <= closeFactor * borrowBalance
///
///      5. DEBT REPAYMENT: The liquidator's tokens are used to repay the borrower's debt
///         (calls repayBorrowFresh with liquidator as payer, borrower as borrower)
///
///      6. SEIZE CALCULATION: Comptroller.liquidateCalculateSeizeTokens() computes how many
///         cTokens to seize based on repay amount, prices, and liquidation incentive
///
///      7. COLLATERAL SEIZURE: cTokenCollateral.seize() transfers cTokens from borrower
///         to liquidator, with a portion going to protocol reserves (2.8%)
///
///      WHY TWO MARKETS ARE INVOLVED:
///      The borrower might have ETH collateral backing a USDC borrow. The liquidator
///      repays USDC (cTokenBorrowed) and receives cETH (cTokenCollateral). This
///      cross-market interaction is why the Comptroller exists.
///
///      Comparison to Uniswap V2: No direct parallel. Uniswap has no lending, so no
///      liquidation. In the broader DeFi context, Aave uses a nearly identical liquidation
///      pattern. MakerDAO uses a different auction-based approach.
abstract contract CTokenLiquidate is CTokenRepay {

    /// @notice Liquidate an underwater borrower's position
    /// @dev Entry point. Accrues interest on BOTH markets before proceeding.
    ///      Why both markets? Because:
    ///      - The borrowed market needs current borrow balances (to verify repay amount)
    ///      - The collateral market needs current exchange rate (to calculate seize amount)
    ///
    /// @param borrower The account being liquidated
    /// @param repayAmount The amount of borrowed asset the liquidator is repaying
    /// @param cTokenCollateral The cToken market from which to seize collateral
    function liquidateBorrowInternal(
        address borrower,
        uint256 repayAmount,
        CTokenInterface cTokenCollateral
    ) internal {
        // Accrue interest on the borrowed market (this contract)
        accrueInterest();

        // Accrue interest on the collateral market
        // This is critical: the exchange rate in the collateral market affects
        // how many cTokens are seized. Stale interest = wrong seize amount.
        cTokenCollateral.accrueInterest();

        liquidateBorrowFresh(msg.sender, borrower, repayAmount, cTokenCollateral);
    }

    /// @notice Core liquidation logic (assumes interest is accrued on both markets)
    /// @dev The three key operations happen in sequence:
    ///      1. Policy check (Comptroller validates the liquidation is legal)
    ///      2. Debt repayment (liquidator pays borrower's debt)
    ///      3. Collateral seizure (borrower's collateral goes to liquidator)
    ///
    ///      IMPORTANT: The liquidator CANNOT be the borrower. Self-liquidation would let
    ///      a user extract the liquidation incentive from themselves, which is economically
    ///      meaningless but could be used for accounting manipulation.
    ///
    /// @param liquidator The account performing the liquidation
    /// @param borrower The account being liquidated
    /// @param repayAmount The amount of borrowed asset to repay
    /// @param cTokenCollateral The cToken market from which to seize collateral
    function liquidateBorrowFresh(
        address liquidator,
        address borrower,
        uint256 repayAmount,
        CTokenInterface cTokenCollateral
    ) internal {
        // Sanity checks
        require(liquidator != borrower, "CToken: liquidator cannot be borrower");
        require(repayAmount > 0, "CToken: repay amount must be greater than zero");

        // 1. Policy check: is this liquidation allowed?
        //    The Comptroller checks: markets listed, borrower underwater, amount within close factor
        uint256 allowed = comptroller.liquidateBorrowAllowed(
            address(this),           // cTokenBorrowed (this market)
            address(cTokenCollateral), // where collateral will be seized
            liquidator,
            borrower,
            repayAmount
        );
        require(allowed == 0, "CToken: liquidation rejected by comptroller");

        // Verify interest is current on both markets
        require(accrualBlockNumber == block.number, "CToken: borrow market interest not accrued");

        // 2. Repay the borrower's debt using the liquidator's funds
        //    This calls repayBorrowFresh with payer=liquidator, borrower=borrower
        //    The liquidator's underlying tokens are transferred to this contract,
        //    and the borrower's BorrowSnapshot is updated (debt reduced).
        uint256 actualRepayAmount = repayBorrowFresh(liquidator, borrower, repayAmount);

        // 3. Calculate how many collateral cTokens to seize
        //    The formula (from Comptroller):
        //    seizeTokens = (actualRepayAmount * liquidationIncentive * priceBorrowed)
        //                / (priceCollateral * exchangeRate)
        (uint256 errCalc, uint256 seizeTokens) = comptroller.liquidateCalculateSeizeTokens(
            address(this),             // cTokenBorrowed (for price lookup)
            address(cTokenCollateral),  // cTokenCollateral (for price + exchange rate)
            actualRepayAmount           // how much was actually repaid
        );
        require(errCalc == 0, "CToken: seize calculation failed");

        // Verify the borrower has enough collateral cTokens to seize
        // (getAccountSnapshot returns: error, cTokenBalance, borrowBalance, exchangeRate)
        (uint256 errSnap, uint256 borrowerCollateralBalance, , ) =
            cTokenCollateral.getAccountSnapshot(borrower);
        require(errSnap == 0, "CToken: collateral snapshot failed");
        require(seizeTokens <= borrowerCollateralBalance, "CToken: insufficient collateral to seize");

        // 4. Seize the collateral
        //    If the collateral market is THIS contract, call seizeInternal directly.
        //    Otherwise, call the external seize function on the collateral cToken.
        if (address(cTokenCollateral) == address(this)) {
            seizeInternal(liquidator, borrower, seizeTokens);
        } else {
            cTokenCollateral.seize(liquidator, borrower, seizeTokens);
        }

        emit LiquidateBorrow(liquidator, borrower, actualRepayAmount, address(cTokenCollateral), seizeTokens);
    }

    /// @notice Transfer seized collateral from borrower to liquidator
    /// @dev This function handles the actual balance transfer during liquidation.
    ///      A portion of the seized tokens goes to the protocol as reserves (2.8%).
    ///
    ///      THE PROTOCOL SEIZE SHARE (2.8%):
    ///      In Compound V2, the protocolSeizeShare is 2.8% of the seized amount.
    ///      This means:
    ///        - Liquidator receives: seizeTokens * (1 - 0.028) = 97.2% of seized tokens
    ///        - Protocol receives: seizeTokens * 0.028 = 2.8% of seized tokens
    ///
    ///      The protocol's share goes to reserves (totalReserves), not to a specific address.
    ///      These reserves serve as a safety buffer against future bad debt.
    ///
    ///      WHY A PROTOCOL CUT?
    ///      Without it, all the value from liquidations goes to liquidators. The protocol
    ///      bears the risk of bad debt but gets none of the liquidation revenue. The 2.8%
    ///      creates a revenue stream that builds reserves, making the protocol more resilient.
    ///
    ///      BALANCE MECHANICS:
    ///      The seized cTokens already exist (they're the borrower's balance). We just
    ///      move them around. The protocol's portion is effectively "burned" from the
    ///      borrower and its underlying value added to reserves. Because reserves are
    ///      subtracted in the exchange-rate formula and totalSupply drops by the same
    ///      proportion, this leaves the exchange rate essentially unchanged (not
    ///      increased) for other cToken holders, aside from rounding.
    ///
    /// @param liquidator The account receiving the seized collateral
    /// @param borrower The account losing the collateral
    /// @param seizeTokens The total number of cTokens being seized
    function seizeInternal(
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) internal {
        // Check with Comptroller
        uint256 allowed = comptroller.seizeAllowed(
            address(this),   // cTokenCollateral
            address(this),   // cTokenBorrowed (same market in this case)
            liquidator,
            borrower,
            seizeTokens
        );
        require(allowed == 0, "CToken: seize rejected by comptroller");

        require(borrower != liquidator, "CToken: cannot seize from self");

        // Calculate the protocol's share and the liquidator's share
        //
        // protocolSeizeTokens = seizeTokens * protocolSeizeShareMantissa / 1e18
        // liquidatorSeizeTokens = seizeTokens - protocolSeizeTokens
        //
        // With protocolSeizeShareMantissa = 2.8e16 (2.8%):
        //   If seizeTokens = 100 cETH:
        //     protocolSeizeTokens = 100 * 0.028 = 2.8 cETH
        //     liquidatorSeizeTokens = 100 - 2.8 = 97.2 cETH
        uint256 protocolSeizeTokens = mul_(seizeTokens, Exp({ mantissa: protocolSeizeShareMantissa }));
        uint256 liquidatorSeizeTokens = seizeTokens - protocolSeizeTokens;

        // Convert protocol's seized cTokens to underlying value for reserves
        // The protocol doesn't keep the cTokens. Instead, it "burns" them and adds
        // the equivalent underlying value (exchangeRate * protocolSeizeTokens) to
        // reserves. Since totalSupply drops by protocolSeizeTokens and reserves rise
        // by their exchange-rate value, the exchange rate is preserved (not increased).
        Exp memory exchangeRate = Exp({ mantissa: exchangeRateStoredInternal() });
        uint256 protocolSeizeAmount = mul_ScalarTruncate(exchangeRate, protocolSeizeTokens);

        // Update balances
        accountTokens[borrower] -= seizeTokens;
        accountTokens[liquidator] += liquidatorSeizeTokens;

        // Protocol's share: reduce totalSupply (cTokens burned) and add to reserves
        totalSupply -= protocolSeizeTokens;
        totalReserves += protocolSeizeAmount;

        // Emit Transfer events for transparency
        emit Transfer(borrower, liquidator, liquidatorSeizeTokens);
        emit Transfer(borrower, address(this), protocolSeizeTokens);
    }

    /// @notice External seize function called by another CToken during cross-market liquidation
    /// @dev When the collateral market is different from the borrowed market, the borrowed
    ///      market's CToken calls this function on the collateral CToken.
    /// @param liquidator The account receiving the collateral
    /// @param borrower The account losing the collateral
    /// @param seizeTokens The number of cTokens to seize
    function seize(address liquidator, address borrower, uint256 seizeTokens) external {
        seizeInternal(liquidator, borrower, seizeTokens);
    }
}
