// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./05-ctoken-interest-ref.sol";

/// @title CToken Mint — Supplying assets to the protocol
/// @notice When a user supplies underlying tokens, they receive cTokens in return.
///         The number of cTokens received = mintAmount / exchangeRate.
///         Over time, as interest accrues, each cToken is worth more underlying.
///
/// @dev This is analogous to Uniswap V2's mint():
///      - Uniswap: deposit token0 + token1, receive LP tokens proportional to reserves
///      - Compound: deposit underlying, receive cTokens proportional to exchange rate
///
///      Key difference: Compound only requires ONE token (the underlying), and the
///      exchange rate replaces Uniswap's two-token reserve ratio.
contract CTokenMint is CTokenInterest {

    /// @notice Sender supplies underlying tokens and receives cTokens.
    /// @dev Called by CErc20.mint() after transferring tokens in.
    ///      The actual mint logic is in mintFresh().
    /// @param mintAmount The amount of underlying to supply
    function mintInternal(uint256 mintAmount) internal {
        accrueInterest();
        mintFresh(msg.sender, mintAmount);
    }

    /// @notice The core mint logic.
    /// @dev Flow:
    ///      1. Comptroller.mintAllowed() — check this market is listed and not paused
    ///      2. Verify interest is accrued to current block
    ///      3. Calculate cTokens to mint: mintAmount / exchangeRate
    ///      4. Transfer underlying from minter to this contract (done by CErc20)
    ///      5. Update totalSupply and minter's balance
    ///      6. Emit Mint and Transfer events
    function mintFresh(address minter, uint256 mintAmount) internal {
        // 1. Check with Comptroller
        uint256 allowed = comptroller.mintAllowed(address(this), minter, mintAmount);
        require(allowed == 0, "CToken: mint rejected by comptroller");

        // 2. Verify interest is current
        require(accrualBlockNumber == block.number, "CToken: interest not accrued");

        // 3. Calculate exchange rate and cTokens to mint
        Exp memory exchangeRate = Exp({ mantissa: exchangeRateStoredInternal() });

        // actualMintAmount comes from doTransferIn (handles fee-on-transfer)
        // For now, we assume mintAmount == actualMintAmount. CErc20 handles the transfer.
        uint256 actualMintAmount = mintAmount;

        // mintTokens = actualMintAmount / exchangeRate
        uint256 mintTokens = div_(actualMintAmount, exchangeRate);

        // 4-5. Update state
        totalSupply += mintTokens;
        accountTokens[minter] += mintTokens;

        // 6. Emit events
        emit Mint(minter, actualMintAmount, mintTokens);
        emit Transfer(address(0), minter, mintTokens);
    }
}
