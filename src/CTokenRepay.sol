// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./CTokenBorrow.sol";

/// @title CToken Repay — Repaying borrowed assets
/// @notice Borrowers (or anyone on their behalf) can repay outstanding borrows.
///         Repaying reduces the borrower's debt and returns underlying tokens to the protocol.
///
/// @dev The repay mechanism mirrors the borrow mechanism:
///      - Borrow: protocol sends underlying to user, increases BorrowSnapshot
///      - Repay: user sends underlying to protocol, decreases BorrowSnapshot
///
///      A special feature is "repay on behalf": anyone can repay another user's debt.
///      This is essential for liquidation (the liquidator repays the borrower's debt)
///      and for helper contracts that automate position management.
///
///      The type(uint256).max pattern for full repayment is worth noting: instead of
///      requiring the user to calculate their exact debt (which changes every block due
///      to interest), they can pass max uint to mean "repay everything." The contract
///      calculates the actual amount.
///
///      Comparison to Uniswap V2: Uniswap has no debt to repay. The closest parallel
///      is removeLiquidity, where LP tokens are burned to retrieve underlying tokens.
///      But in Compound, repaying doesn't give you anything back. It just reduces your debt.
abstract contract CTokenRepay is CTokenBorrow {

    /// @notice Repay your own borrow
    /// @param repayAmount The amount of underlying to repay (use type(uint256).max for full repay)
    function repayBorrowInternal(uint256 repayAmount) internal {
        accrueInterest();
        repayBorrowFresh(msg.sender, msg.sender, repayAmount);
    }

    /// @notice Repay someone else's borrow
    /// @dev This is the "repay on behalf" pattern. Anyone can repay another user's debt.
    ///      No approval needed. This is safe because repaying debt can only HELP the borrower.
    ///
    ///      Use cases:
    ///      1. Liquidation: the liquidator calls this to repay part of the borrower's debt
    ///      2. Position management bots: automated debt repayment
    ///      3. Charitable repayment: someone paying off another user's loan
    ///
    /// @param borrower The account whose borrow to repay
    /// @param repayAmount The amount to repay (use type(uint256).max for full repay)
    function repayBorrowBehalfInternal(address borrower, uint256 repayAmount) internal {
        accrueInterest();
        repayBorrowFresh(msg.sender, borrower, repayAmount);
    }

    /// @notice Core repay logic (assumes interest is already accrued)
    /// @dev Flow:
    ///      1. Comptroller.repayBorrowAllowed() — minimal check (market is listed)
    ///      2. Verify interest is current
    ///      3. Calculate the borrower's current borrow balance (including accrued interest)
    ///      4. Determine actual repay amount (handle type(uint256).max for full repay)
    ///      5. Transfer underlying FROM the payer TO this contract
    ///      6. Update the BorrowSnapshot (reduce principal, reset interestIndex)
    ///      7. Update totalBorrows
    ///
    ///      The BorrowSnapshot update follows the same pattern as borrowFresh:
    ///      store the new principal and current borrowIndex.
    ///
    /// @param payer The account paying the underlying (may differ from borrower)
    /// @param borrower The account whose borrow is being repaid
    /// @param repayAmount The amount to repay (type(uint256).max = repay all)
    /// @return The actual amount repaid
    function repayBorrowFresh(
        address payer,
        address borrower,
        uint256 repayAmount
    ) internal returns (uint256) {
        // 1. Check with Comptroller
        uint256 allowed = comptroller.repayBorrowAllowed(address(this), payer, borrower, repayAmount);
        require(allowed == 0, "CToken: repay rejected by comptroller");

        // 2. Verify interest is current
        require(accrualBlockNumber == block.number, "CToken: interest not accrued");

        // 3. Get the borrower's current borrow balance (with accrued interest)
        uint256 accountBorrowsPrev = borrowBalanceStoredInternal(borrower);

        // 4. Determine the actual repay amount
        //    If repayAmount == type(uint256).max, repay the entire borrow balance.
        //    This is a UX pattern: the user doesn't need to know their exact balance
        //    (which changes every block). They just say "repay everything."
        uint256 repayAmountFinal;
        if (repayAmount == type(uint256).max) {
            repayAmountFinal = accountBorrowsPrev;
        } else {
            repayAmountFinal = repayAmount;
        }

        // 5. Transfer underlying from payer to this contract
        //    doTransferIn is a virtual function implemented by CErc20 (ERC-20 transferFrom)
        uint256 actualRepayAmount = doTransferIn(payer, repayAmountFinal);

        // 6. Update the BorrowSnapshot
        //    Reduce principal by the repaid amount, reset interestIndex to current borrowIndex
        uint256 accountBorrowsNew = accountBorrowsPrev - actualRepayAmount;
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;

        // 7. Update total borrows
        totalBorrows = totalBorrows - actualRepayAmount;

        emit RepayBorrow(payer, borrower, actualRepayAmount, accountBorrowsNew, totalBorrows);

        return actualRepayAmount;
    }

    /// @notice Transfer underlying tokens into the contract
    /// @dev Must be overridden by CErc20 (uses ERC-20 transferFrom).
    ///      Returns the actual amount received (may differ from requested amount
    ///      for fee-on-transfer tokens).
    function doTransferIn(address from, uint256 amount) internal virtual returns (uint256);
}
