// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./02-math-library-ref.sol";

/// @title InterestRateModel interface (minimal, for CToken reference)
interface IInterestRateModel {
    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256);
    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa) external view returns (uint256);
}

/// @title IComptroller — Minimal interface for CToken to call the Comptroller
/// @dev The full Comptroller is built in sections 9-11. This interface lets CToken compile.
interface IComptroller {
    function mintAllowed(address cToken, address minter, uint256 mintAmount) external returns (uint256);
    function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens) external returns (uint256);
    function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external returns (uint256);
    function repayBorrowAllowed(address cToken, address payer, address borrower, uint256 repayAmount) external returns (uint256);
    function liquidateBorrowAllowed(address cTokenBorrowed, address cTokenCollateral, address liquidator, address borrower, uint256 repayAmount) external returns (uint256);
    function seizeAllowed(address cTokenCollateral, address cTokenBorrowed, address liquidator, address borrower, uint256 seizeTokens) external returns (uint256);
    function transferAllowed(address cToken, address src, address dst, uint256 transferTokens) external returns (uint256);
    function liquidateCalculateSeizeTokens(address cTokenBorrowed, address cTokenCollateral, uint256 actualRepayAmount) external view returns (uint256, uint256);
}

/// @title CTokenStorage — All state variables for the CToken
/// @notice This is the storage layout. Separating it makes the architecture clear:
///         state here, logic in CToken, token-specific handling in CErc20.
///
/// @dev Key accounting:
///      - totalSupply: total cTokens in existence (share tokens)
///      - totalBorrows: total underlying tokens lent out (grows with interest)
///      - totalReserves: protocol revenue (cut of interest)
///      - borrowIndex: cumulative interest multiplier (enables lazy per-user calculation)
///
///      The BorrowSnapshot enables lazy interest: instead of updating every borrower
///      every block, each borrower's balance is computed on-demand as:
///        currentBorrow = snapshot.principal * currentBorrowIndex / snapshot.interestIndex
contract CTokenStorage is ExponentialNoError {
    /// @dev Guard against reentrancy
    bool internal _notEntered;

    /// @notice ERC-20 metadata
    string public name;
    string public symbol;
    uint8 public decimals;

    /// @notice Admin address (can set reserve factor, interest rate model)
    address public admin;

    /// @notice The Comptroller that governs this market
    IComptroller public comptroller;

    /// @notice The interest rate model for this market
    IInterestRateModel public interestRateModel;

    /// @notice Initial exchange rate when totalSupply is 0 (typically 0.02e18 = 50 cTokens per underlying)
    uint256 internal initialExchangeRateMantissa;

    /// @notice Fraction of interest set aside for reserves (e.g., 0.1e18 = 10%)
    uint256 public reserveFactorMantissa;

    /// @notice Block number that interest was last accrued at
    uint256 public accrualBlockNumber;

    /// @notice Cumulative interest multiplier. Starts at 1e18, grows every accrual.
    /// @dev Used to compute individual borrow balances without iterating all borrowers.
    uint256 public borrowIndex;

    /// @notice Total outstanding borrows (in underlying token units)
    uint256 public totalBorrows;

    /// @notice Total reserves (protocol revenue, in underlying token units)
    uint256 public totalReserves;

    /// @notice Total cTokens in existence
    uint256 public totalSupply;

    /// @notice cToken balances per account
    mapping(address => uint256) internal accountTokens;

    /// @notice ERC-20 transfer allowances
    mapping(address => mapping(address => uint256)) internal transferAllowances;

    /// @notice Per-user borrow state for lazy interest calculation
    struct BorrowSnapshot {
        uint256 principal;      // Borrow balance at time of last interaction
        uint256 interestIndex;  // borrowIndex at time of last interaction
    }

    /// @notice Maps borrower address to their borrow snapshot
    mapping(address => BorrowSnapshot) internal accountBorrows;

    /// @notice Share of seized collateral that goes to protocol (2.8%)
    uint256 public constant protocolSeizeShareMantissa = 2.8e16;

    // ============ Events ============

    event AccrueInterest(uint256 cashPrior, uint256 interestAccumulated, uint256 borrowIndex, uint256 totalBorrows);
    event Mint(address minter, uint256 mintAmount, uint256 mintTokens);
    event Redeem(address redeemer, uint256 redeemAmount, uint256 redeemTokens);
    event Borrow(address borrower, uint256 borrowAmount, uint256 accountBorrows, uint256 totalBorrows);
    event RepayBorrow(address payer, address borrower, uint256 repayAmount, uint256 accountBorrows, uint256 totalBorrows);
    event LiquidateBorrow(address liquidator, address borrower, uint256 repayAmount, address cTokenCollateral, uint256 seizeTokens);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event NewReserveFactor(uint256 oldReserveFactorMantissa, uint256 newReserveFactorMantissa);
    event NewComptroller(IComptroller oldComptroller, IComptroller newComptroller);
    event NewInterestRateModel(IInterestRateModel oldInterestRateModel, IInterestRateModel newInterestRateModel);
}
