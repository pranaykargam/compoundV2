// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./CTokenRedeem.sol";

/// @title CToken Borrow — Borrowing underlying assets from the protocol
/// @notice Users who have supplied collateral (and entered markets) can borrow underlying
///         tokens from any market. The borrowed amount accrues interest over time.
///
/// @dev The borrow mechanism relies on the BorrowSnapshot pattern (defined in 04-ctoken-state-ref.sol):
///      Instead of updating every borrower's balance every block, each borrower stores a
///      "snapshot" of their principal and the global borrowIndex at the time of their last
///      interaction. Their current balance is computed lazily:
///
///        currentBorrow = snapshot.principal * currentBorrowIndex / snapshot.interestIndex
///
///      This is the same pattern as Compound's "borrow balance stored" approach. The key
///      insight is that interest accrual is GLOBAL (borrowIndex grows), but balance
///      calculation is PER-USER and LAZY (only computed when needed).
///
///      Comparison to Uniswap V2: Uniswap has no borrowing. The closest parallel is how
///      LP token value grows over time from fees. In Uniswap, fees are embedded in the
///      reserves and reflected in the LP share price. In Compound, interest is tracked
///      via the borrowIndex, and the "share price" (exchange rate) grows as borrowers
///      pay interest.
abstract contract CTokenBorrow is CTokenRedeem {

    /// @notice Borrow underlying tokens from the protocol
    /// @dev Entry point for borrowing. Calls accrueInterest first (ensures borrowIndex
    ///      is up to date), then delegates to borrowFresh for the actual logic.
    ///
    ///      The two-step pattern (external entry + internal fresh) is consistent across
    ///      all CToken operations. The "fresh" function assumes interest is already accrued.
    ///
    /// @param borrowAmount The amount of underlying tokens to borrow
    function borrowInternal(uint256 borrowAmount) internal {
        accrueInterest();
        borrowFresh(msg.sender, borrowAmount);
    }

    /// @notice Core borrow logic (assumes interest is already accrued)
    /// @dev Flow:
    ///      1. Comptroller.borrowAllowed() — checks the user has enough collateral
    ///         across all markets to support this new borrow
    ///      2. Verify interest is current (defense against stale state)
    ///      3. Check the protocol has enough cash to lend
    ///      4. Calculate the borrower's new borrow balance
    ///      5. Update the BorrowSnapshot (principal + interestIndex)
    ///      6. Update totalBorrows
    ///      7. Transfer the borrowed tokens to the user
    ///
    ///      The BorrowSnapshot update is critical: we store the borrower's NEW total
    ///      borrow and the CURRENT borrowIndex. This "resets" their interest accumulation
    ///      point so future interest calculations start from this moment.
    ///
    /// @param borrower The address borrowing (always msg.sender in practice)
    /// @param borrowAmount The amount of underlying to borrow
    function borrowFresh(address borrower, uint256 borrowAmount) internal {
        // 1. Check with Comptroller (cross-market solvency check)
        uint256 allowed = comptroller.borrowAllowed(address(this), borrower, borrowAmount);
        require(allowed == 0, "CToken: borrow rejected by comptroller");

        // 2. Verify interest is current
        require(accrualBlockNumber == block.number, "CToken: interest not accrued");

        // 3. Check the protocol has enough cash to lend
        //    Cash = underlying tokens sitting in this contract (not yet borrowed)
        require(getCashPrior() >= borrowAmount, "CToken: insufficient cash to borrow");

        // 4. Calculate the borrower's current borrow balance (including accrued interest)
        //    This uses the BorrowSnapshot pattern from borrowBalanceStoredInternal()
        uint256 accountBorrowsPrev = borrowBalanceStoredInternal(borrower);
        uint256 accountBorrowsNew = accountBorrowsPrev + borrowAmount;
        uint256 totalBorrowsNew = totalBorrows + borrowAmount;

        // 5. Update the BorrowSnapshot for this borrower
        //    principal = their total borrow balance NOW (including this new borrow)
        //    interestIndex = the CURRENT borrowIndex (resets their interest accumulation point)
        //
        //    Next time we calculate their balance, it will be:
        //      accountBorrowsNew * futureBorrowIndex / currentBorrowIndex
        //    which correctly captures only the interest accrued AFTER this borrow.
        accountBorrows[borrower].principal = accountBorrowsNew;
        accountBorrows[borrower].interestIndex = borrowIndex;

        // 6. Update total borrows
        totalBorrows = totalBorrowsNew;

        // 7. Transfer the borrowed tokens to the borrower
        //    doTransferOut is a virtual function implemented by CErc20 (ERC-20 transfer)
        doTransferOut(borrower, borrowAmount);

        emit Borrow(borrower, borrowAmount, accountBorrowsNew, totalBorrowsNew);
    }
}
