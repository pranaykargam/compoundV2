// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./CTokenMint.sol";

/// @title CToken Redeem — Withdrawing assets from the protocol
/// @notice Users burn cTokens to receive underlying tokens. Two variants:
///         - redeem(cTokenAmount): "I want to burn exactly X cTokens"
///         - redeemUnderlying(underlyingAmount): "I want exactly Y underlying tokens"
///
/// @dev Critical difference from Uniswap's burn(): the Comptroller checks whether
///      this redemption would make the user's position undercollateralized. In Uniswap,
///      you can always burn LP tokens. In Compound, you might be blocked if those cTokens
///      are being used as collateral for a borrow.
abstract contract CTokenRedeem is CTokenMint {

    /// @notice Redeem cTokens for underlying. Specify the cToken amount to burn.
    /// @param redeemTokens The number of cTokens to burn
    function redeemInternal(uint256 redeemTokens) internal {
        accrueInterest();
        redeemFresh(msg.sender, redeemTokens, 0);
    }

    /// @notice Redeem cTokens for underlying. Specify the underlying amount to receive.
    /// @param redeemAmount The amount of underlying to receive
    function redeemUnderlyingInternal(uint256 redeemAmount) internal {
        accrueInterest();
        redeemFresh(msg.sender, 0, redeemAmount);
    }

    /// @notice The core redeem logic. One of redeemTokensIn or redeemAmountIn must be zero.
    /// @dev This dual-parameter pattern lets the same function handle both variants:
    ///      - redeemTokensIn > 0: burn exact cTokens, calculate underlying
    ///      - redeemAmountIn > 0: calculate cTokens needed for exact underlying
    ///
    /// @param redeemer The account redeeming
    /// @param redeemTokensIn The number of cTokens to burn (0 if specifying underlying)
    /// @param redeemAmountIn The amount of underlying to receive (0 if specifying cTokens)
    function redeemFresh(address redeemer, uint256 redeemTokensIn, uint256 redeemAmountIn) internal {
        require(redeemTokensIn == 0 || redeemAmountIn == 0, "CToken: one must be zero");

        Exp memory exchangeRate = Exp({ mantissa: exchangeRateStoredInternal() });

        uint256 redeemTokens;
        uint256 redeemAmount;

        if (redeemTokensIn > 0) {
            // Redeem exact cTokens: calculate underlying
            redeemTokens = redeemTokensIn;
            redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokensIn);
        } else {
            // Redeem exact underlying: calculate cTokens needed
            redeemTokens = div_(redeemAmountIn, exchangeRate);
            redeemAmount = redeemAmountIn;
        }

        // Check with Comptroller (verifies collateral sufficiency AFTER redemption)
        uint256 allowed = comptroller.redeemAllowed(address(this), redeemer, redeemTokens);
        require(allowed == 0, "CToken: redeem rejected by comptroller");

        // Verify interest is current
        require(accrualBlockNumber == block.number, "CToken: interest not accrued");

        // Check the protocol has enough cash
        require(getCashPrior() >= redeemAmount, "CToken: insufficient cash");

        // Update state
        totalSupply -= redeemTokens;
        accountTokens[redeemer] -= redeemTokens;

        // Transfer underlying out (done by CErc20's doTransferOut)
        doTransferOut(redeemer, redeemAmount);

        emit Redeem(redeemer, redeemAmount, redeemTokens);
        emit Transfer(redeemer, address(0), redeemTokens);
    }

    /// @notice Transfer underlying tokens out of the contract.
    /// @dev Must be overridden by CErc20 (uses ERC-20 transfer).
    function doTransferOut(address to, uint256 amount) internal virtual;
}
