// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./ComptrollerLiquidity.sol";

/// @title ComptrollerHooks — Policy enforcement hooks called by CToken
/// @notice Every CToken function (mint, redeem, borrow, repay, liquidate, transfer, seize)
///         calls the Comptroller BEFORE executing. These hooks are the Comptroller's way
///         of saying "yes, this action is allowed" or "no, this would be unsafe."
///
/// @dev This is the "allowed" pattern, and it is unique to Compound's architecture:
///      1. CToken calls comptroller.borrowAllowed(...)
///      2. Comptroller checks the user's global solvency across all markets
///      3. Returns 0 for "allowed" or non-zero for "rejected"
///      4. CToken requires the return to be 0
///
///      Why not just put the checks in the CToken? Because risk is CROSS-MARKET.
///      A user's ETH deposit backs their USDC borrow. The CToken for USDC cannot
///      check the user's ETH collateral on its own. Only the Comptroller, which has
///      a global view of all markets, can make that determination.
///
///      Comparison to Uniswap V2: Uniswap has no policy hooks. Each pair is independent.
///      The closest analogy is Uniswap V4's hook system, but those are for customizing
///      pool behavior, not for cross-pool risk management.
contract ComptrollerHooks is ComptrollerLiquidity {

    // ============ Policy Hooks ============

    /// @notice Check if minting (supplying) is allowed in this market
    /// @dev Minimal check: just verify the market is listed. Minting doesn't increase risk
    ///      because you're adding collateral, not taking on debt. Even if you haven't
    ///      entered the market, you can still supply (you just won't get borrowing power).
    /// @param cToken The market being supplied to
    /// @return 0 if allowed, non-zero if rejected
    function mintAllowed(address cToken, address, uint256) external view returns (uint256) {
        require(markets[cToken].isListed, "Comptroller: market not listed");
        return 0;
    }

    /// @notice Check if redeeming (withdrawing) is allowed
    /// @dev This is where it gets interesting. Redeeming reduces your collateral,
    ///      which could make your position undercollateralized. We must check:
    ///      1. Market is listed
    ///      2. HYPOTHETICAL liquidity after the redeem is still positive
    ///
    ///      The hypothetical check simulates "what if this user had redeemed these tokens?"
    ///      and verifies they would still be solvent.
    /// @param cToken The market being redeemed from
    /// @param redeemer The user redeeming
    /// @param redeemTokens The number of cTokens being redeemed
    /// @return 0 if allowed, non-zero if rejected
    function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens) external view returns (uint256) {
        require(markets[cToken].isListed, "Comptroller: market not listed");

        // If the user hasn't entered this market, the redeem doesn't affect their
        // collateral calculation, so it's always safe
        if (!markets[cToken].accountMembership[redeemer]) {
            return 0;
        }

        // Check hypothetical liquidity: "what if this user redeemed redeemTokens?"
        (, , uint256 shortfall) =
            _getHypotheticalAccountLiquidityInternal(redeemer, cToken, redeemTokens, 0);
        require(shortfall == 0, "Comptroller: insufficient liquidity after redeem");

        return 0;
    }

    /// @notice Check if borrowing is allowed
    /// @dev The most complex allowed check. Must verify:
    ///      1. Market is listed
    ///      2. User has entered a market with enough collateral
    ///      3. HYPOTHETICAL liquidity after the borrow is still positive
    ///
    ///      Special behavior: if the borrower hasn't entered this market yet,
    ///      automatically enter them. This is a UX convenience. When you borrow
    ///      from a market, you implicitly need to track that market for liquidation
    ///      purposes, so the protocol enters it for you.
    ///
    /// @param cToken The market being borrowed from
    /// @param borrower The user borrowing
    /// @param borrowAmount The amount of underlying being borrowed
    /// @return 0 if allowed, non-zero if rejected
    function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external returns (uint256) {
        require(markets[cToken].isListed, "Comptroller: market not listed");

        // Auto-enter the market for the borrower (UX convenience)
        // This ensures the borrow is tracked in their accountAssets for liquidity calculation
        if (!markets[cToken].accountMembership[borrower]) {
            // Only the cToken itself should call borrowAllowed, so we require msg.sender == cToken
            require(msg.sender == cToken, "Comptroller: sender must be cToken");
            _addToMarketInternal(cToken, borrower);
        }

        // Verify oracle has a price (safety: never borrow without price data)
        require(oracle.getUnderlyingPrice(cToken) != 0, "Comptroller: oracle price is zero");

        // Check hypothetical liquidity: "what if this user borrowed borrowAmount more?"
        (, , uint256 shortfall) =
            _getHypotheticalAccountLiquidityInternal(borrower, cToken, 0, borrowAmount);
        require(shortfall == 0, "Comptroller: insufficient collateral for borrow");

        return 0;
    }

    /// @notice Check if repaying a borrow is allowed
    /// @dev Minimal check: repaying a borrow is always good for protocol health.
    ///      It reduces the user's debt, so there's no risk to check.
    /// @param cToken The market where the borrow is being repaid
    /// @return 0 if allowed
    function repayBorrowAllowed(address cToken, address, address, uint256) external view returns (uint256) {
        require(markets[cToken].isListed, "Comptroller: market not listed");
        return 0;
    }

    /// @notice Check if a liquidation is allowed
    /// @dev Liquidation is the protocol's safety valve. It lets third parties repay
    ///      an underwater borrower's debt in exchange for their collateral (at a discount).
    ///
    ///      Requirements:
    ///      1. Both the borrowed and collateral markets must be listed
    ///      2. The borrower must have a shortfall (be undercollateralized)
    ///      3. The repay amount must not exceed closeFactor * borrower's total borrow
    ///         in the borrowed market
    ///
    ///      The closeFactor limit (typically 50%) prevents a liquidator from seizing
    ///      ALL of a borrower's collateral in one transaction. This is a fairness
    ///      mechanism: partial liquidation gives the borrower a chance to recover.
    ///
    /// @param cTokenBorrowed The market where the debt exists
    /// @param cTokenCollateral The market where collateral will be seized
    /// @param borrower The account being liquidated
    /// @param repayAmount The amount of debt the liquidator wants to repay
    /// @return 0 if allowed, non-zero if rejected
    function liquidateBorrowAllowed(
        address cTokenBorrowed,
        address cTokenCollateral,
        address,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256) {
        require(markets[cTokenBorrowed].isListed, "Comptroller: borrowed market not listed");
        require(markets[cTokenCollateral].isListed, "Comptroller: collateral market not listed");

        // The borrower must be underwater (shortfall > 0)
        (, , uint256 shortfall) = getAccountLiquidity(borrower);
        require(shortfall > 0, "Comptroller: borrower is not underwater");

        // The repay amount must not exceed closeFactor * borrower's borrow balance
        // This prevents over-liquidation.
        // We use getAccountSnapshot to get the borrower's specific borrow balance
        // (not totalBorrows, which is the entire market's borrows).
        (, , uint256 borrowerBorrowBalance, ) =
            CTokenInterface(cTokenBorrowed).getAccountSnapshot(borrower);

        // maxClose = closeFactor * borrowBalance
        uint256 maxClose = mul_ScalarTruncate(
            Exp({ mantissa: closeFactorMantissa }),
            borrowerBorrowBalance
        );
        require(repayAmount <= maxClose, "Comptroller: repay exceeds close factor limit");

        return 0;
    }

    /// @notice Check if seizing collateral is allowed
    /// @dev Called during liquidation when collateral is being transferred from borrower
    ///      to liquidator. Both markets must be listed and the Comptroller must be the
    ///      same for both (prevents cross-Comptroller attacks).
    /// @param cTokenCollateral The market whose tokens are being seized
    /// @param cTokenBorrowed The market where the debt was repaid
    /// @return 0 if allowed
    function seizeAllowed(
        address cTokenCollateral,
        address cTokenBorrowed,
        address,
        address,
        uint256
    ) external view returns (uint256) {
        require(markets[cTokenCollateral].isListed, "Comptroller: collateral market not listed");
        require(markets[cTokenBorrowed].isListed, "Comptroller: borrowed market not listed");

        // In the real Compound, this also checks that both cTokens reference the same
        // Comptroller. We skip that since we only have one Comptroller in this simplified version.

        return 0;
    }

    /// @notice Check if a cToken transfer is allowed
    /// @dev Transferring cTokens is equivalent to the sender redeeming and the receiver
    ///      minting. We only need to check the sender's liquidity (the receiver benefits).
    ///      This reuses the same hypothetical liquidity check as redeemAllowed.
    /// @param cToken The market whose tokens are being transferred
    /// @param src The sender
    /// @param transferTokens The number of cTokens being transferred
    /// @return 0 if allowed
    function transferAllowed(address cToken, address src, address, uint256 transferTokens) external view returns (uint256) {
        require(markets[cToken].isListed, "Comptroller: market not listed");

        // If the sender hasn't entered this market, the transfer doesn't affect collateral
        if (!markets[cToken].accountMembership[src]) {
            return 0;
        }

        // Check hypothetical liquidity: "what if src redeemed transferTokens?"
        (, , uint256 shortfall) =
            _getHypotheticalAccountLiquidityInternal(src, cToken, transferTokens, 0);
        require(shortfall == 0, "Comptroller: insufficient liquidity after transfer");

        return 0;
    }

    // ============ Liquidation Calculations ============

    /// @notice Calculate how many collateral tokens to seize in a liquidation
    /// @dev The formula:
    ///      seizeTokens = (repayAmount * liquidationIncentive * priceBorrowed) /
    ///                    (priceCollateral * exchangeRate)
    ///
    ///      Step by step:
    ///      1. repayAmount * priceBorrowed = dollar value of debt being repaid
    ///      2. * liquidationIncentive = dollar value including the liquidator's bonus
    ///      3. / priceCollateral = how much underlying collateral that buys
    ///      4. / exchangeRate = how many cTokens that corresponds to
    ///
    ///      Example: Liquidator repays 100 USDC of debt, incentive is 1.08.
    ///      ETH price = $2000, cETH exchange rate = 0.02.
    ///      seizeAmount in ETH = 100 * 1.08 / 2000 = 0.054 ETH
    ///      seizeTokens in cETH = 0.054 / 0.02 = 2.7 cETH
    ///
    /// @param cTokenBorrowed The market where debt was repaid
    /// @param cTokenCollateral The market where collateral is seized
    /// @param actualRepayAmount The actual amount of debt repaid (in underlying units)
    /// @return (error code, number of cTokens to seize)
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        // Get oracle prices for both assets
        uint256 priceBorrowed = oracle.getUnderlyingPrice(cTokenBorrowed);
        uint256 priceCollateral = oracle.getUnderlyingPrice(cTokenCollateral);
        require(priceBorrowed > 0 && priceCollateral > 0, "Comptroller: oracle price is zero");

        // Get the collateral market's exchange rate
        (, , , uint256 exchangeRateMantissa) =
            CTokenInterface(cTokenCollateral).getAccountSnapshot(address(0));
        // Note: In a real implementation, we'd call exchangeRateStored() directly.
        // Using getAccountSnapshot with address(0) gives us the exchange rate.

        // seizeTokens = (actualRepayAmount * liquidationIncentive * priceBorrowed)
        //             / (priceCollateral * exchangeRate)
        //
        // In mantissa math:
        // numerator = liquidationIncentive * priceBorrowed (both mantissa, result is Double)
        // seizeAmount = numerator * actualRepayAmount (underlying units)
        // seizeTokens = seizeAmount / (priceCollateral * exchangeRate)

        Exp memory numerator = mul_(
            Exp({ mantissa: liquidationIncentiveMantissa }),
            Exp({ mantissa: priceBorrowed })
        );
        Exp memory denominator = mul_(
            Exp({ mantissa: priceCollateral }),
            Exp({ mantissa: exchangeRateMantissa })
        );
        Exp memory ratio = div_(numerator, denominator);
        uint256 seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (0, seizeTokens);
    }

    // ============ View Helpers ============

    /// @notice Check if an account is a member of a market
    /// @param cToken The market to check
    /// @param account The account to check
    /// @return True if the account has entered this market
    function checkMembership(address account, address cToken) external view returns (bool) {
        return markets[cToken].accountMembership[account];
    }

    /// @notice Get the list of markets an account has entered
    /// @param account The account to query
    /// @return The array of cToken addresses
    function getAssetsIn(address account) external view returns (address[] memory) {
        return accountAssets[account];
    }
}
