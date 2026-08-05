// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./ExponentialNoError.sol";

interface IInterestRateModel {
    function getBorrowRate(uint256 cash, uint256 borrows, uint256 reserves) external view returns (uint256);
    function getSupplyRate(uint256 cash, uint256 borrows, uint256 reserves, uint256 reserveFactorMantissa) external view returns (uint256);
}

interface IComptroller {
    function mintAllowed(address cToken, address minter, uint256 mintAmount) external returns (uint256);
    function redeemAllowed(address cToken, address redeemer, uint256 redeemTokens) external returns (uint256);
    function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external returns (uint256);
    function repayBorrowAllowed(address cToken, address payer, address borrower, uint256 repayAmount) external returns (uint256);
    function liquidateBorrowAllowed(address cTokenBorrowed,
     address cTokenCollateral, address liquidator, address borrower, uint256 repayAmount) external returns (uint256);

    function seizeAllowed(address cTokenCollateral, address cTokenBorrowed, address liquidator, address borrower, uint256 seizeTokens)
     external returns (uint256);

    function transferAllowed(address cToken, address src, address dst, uint256 transferTokens) external returns (uint256);
    function liquidateCalculateSeizeTokens
    (address cTokenBorrowed, address cTokenCollateral, uint256 actualRepayAmount) external view returns (uint256, uint256);
}

contract CTokenStorage is ExponentialNoError {
    bool internal _notEntered;
    string public name;
    string public symbol;
    uint8 public decimals;
    address public admin;
    IComptroller public comptroller;
    IInterestRateModel public interestRateModel;
    uint256 internal initialExchangeRateMantissa;
    uint256 public reserveFactorMantissa;
    uint256 public accrualBlockNumber;
    uint256 public borrowIndex;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public totalSupply;
    mapping(address => uint256) internal accountTokens;
    mapping(address => mapping(address => uint256)) internal transferAllowances;

    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    mapping(address => BorrowSnapshot) internal accountBorrows;
    uint256 public constant protocolSeizeShareMantissa = 2.8e16;

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
