// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./CTokenStorage.sol";

/// @title CToken Interest — Exchange rate and interest accrual logic
/// @notice This section adds the two most fundamental functions of the CToken:
///         1. exchangeRateStoredInternal() - how much underlying does 1 cToken represent?
///         2. accrueInterest() - accumulate interest since the last block
///
/// @dev These two functions are the heartbeat of the protocol. Every other function
///      (mint, redeem, borrow, repay, liquidate) depends on them being correct.
///
///      The exchange rate grows over time as borrowers pay interest:
///        exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
///
///      accrueInterest() is called at the START of every user-facing function.
///      It uses simple interest per block (not compound interest). The compounding
///      effect comes from frequent calls.
abstract contract CTokenInterest is CTokenStorage {

    /// @notice Get the current amount of underlying tokens held by this contract.
    /// @dev Must be overridden by CErc20 (uses balanceOf) or CEther (uses address.balance).
    function getCashPrior() internal virtual view returns (uint256);

    /// @notice Calculate the exchange rate from cToken to underlying.
    /// @dev When totalSupply is 0, returns the initial exchange rate.
    ///      Otherwise: (totalCash + totalBorrows - totalReserves) / totalSupply
    ///
    ///      This is analogous to how Uniswap LP tokens represent a share of the pool:
    ///      LP value = (reserve0 + reserve1) / totalSupply
    ///      cToken value = (cash + borrows - reserves) / totalSupply
    ///
    /// @return The exchange rate as a mantissa (scaled by 1e18)
    function exchangeRateStoredInternal() internal view returns (uint256) {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            // Before any deposits, use the initial exchange rate
            return initialExchangeRateMantissa;
        } else {
            // totalCash + totalBorrows - totalReserves = total underlying value
            uint256 totalCash = getCashPrior();
            uint256 cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
            // Exchange rate = total value / total shares
            uint256 exchangeRate = (cashPlusBorrowsMinusReserves * expScale) / _totalSupply;
            return exchangeRate;
        }
    }

    /// @notice Accrue interest to the current block.
    /// @dev This is called at the START of every user-facing function (mint, redeem,
    ///      borrow, repay, liquidate). It calculates interest since the last accrual:
    ///
    ///      1. Get the borrow rate from the InterestRateModel
    ///      2. Calculate blocks elapsed since last accrual
    ///      3. simpleInterestFactor = borrowRate * blockDelta
    ///      4. interestAccumulated = simpleInterestFactor * totalBorrows
    ///      5. totalBorrows += interestAccumulated
    ///      6. totalReserves += reserveFactor * interestAccumulated
    ///      7. borrowIndex *= (1 + simpleInterestFactor)
    ///
    ///      The borrowIndex is the key to lazy per-user accounting. Instead of updating
    ///      every borrower's balance every block, each borrower stores a snapshot of
    ///      the borrowIndex when they last interacted. Their current balance is:
    ///        currentBorrow = snapshot.principal * currentBorrowIndex / snapshot.interestIndex
    function accrueInterest() public virtual returns (uint256) {
        uint256 currentBlockNumber = block.number;
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        // Short-circuit if already accrued this block
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return 0;
        }

        uint256 cashPrior = getCashPrior();
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        // Get the current borrow rate from the interest rate model
        uint256 borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);

        // Calculate blocks elapsed
        uint256 blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        // Calculate interest accumulated: simpleInterestFactor * totalBorrows
        // simpleInterestFactor = borrowRate * blockDelta
        uint256 simpleInterestFactor = borrowRateMantissa * blockDelta;
        uint256 interestAccumulated = (simpleInterestFactor * borrowsPrior) / expScale;

        // Update state
        totalBorrows = borrowsPrior + interestAccumulated;
        totalReserves = reservesPrior + (reserveFactorMantissa * interestAccumulated) / expScale;
        borrowIndex = borrowIndexPrior + (simpleInterestFactor * borrowIndexPrior) / expScale;
        accrualBlockNumber = currentBlockNumber;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndex, totalBorrows);

        return 0;
    }

    /// @notice Get a borrower's current borrow balance (including accrued interest).
    /// @dev Uses the BorrowSnapshot for lazy calculation:
    ///      currentBorrow = snapshot.principal * currentBorrowIndex / snapshot.interestIndex
    ///      If the borrower has never borrowed, returns 0.
    function borrowBalanceStoredInternal(address account) internal view returns (uint256) {
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        // If they've never borrowed, principal is 0
        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        // Calculate current balance using the borrowIndex ratio
        return (borrowSnapshot.principal * borrowIndex) / borrowSnapshot.interestIndex;
    }

    /// @notice Get the account's cToken balance, borrow balance, and exchange rate.
    /// @dev Used by the Comptroller for liquidity calculations.
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256) {
        return (
            0, // no error
            accountTokens[account],
            borrowBalanceStoredInternal(account),
            exchangeRateStoredInternal()
        );
    }
}
