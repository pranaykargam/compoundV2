// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import "./CTokenLiquidate.sol";

/// @title IERC20 — Minimal ERC-20 interface for interacting with the underlying token
/// @dev We define a minimal interface rather than importing OpenZeppelin to keep
///      the educational reference self-contained.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title CErc20 — The final integration layer for ERC-20 backed cTokens
/// @notice This contract ties everything together. It inherits the full CToken logic chain:
///         CTokenStorage -> CTokenInterest -> CTokenMint -> CTokenRedeem -> CTokenBorrow
///         -> CTokenRepay -> CTokenLiquidate -> CErc20
///
///         CErc20 provides:
///         1. The public entry points (mint, redeem, borrow, repay, liquidateBorrow)
///         2. The ERC-20 token transfer implementation (doTransferIn, doTransferOut)
///         3. Standard ERC-20 functions (transfer, transferFrom, approve, balanceOf)
///         4. The initialization function (replaces a constructor for proxy compatibility)
///         5. Reentrancy protection
///
/// @dev ARCHITECTURE COMPARISON WITH UNISWAP V2:
///
///      Uniswap V2 Pair inherits from UniswapV2ERC20 and handles:
///        - LP token (ERC-20) + pool logic in ONE contract
///        - mint() takes deposited tokens and mints LP tokens
///        - burn() burns LP tokens and returns underlying
///
///      Compound's CErc20 inherits a deeper chain but follows the same principle:
///        - cToken (ERC-20) + lending logic in ONE contract per market
///        - mint() takes deposited tokens and mints cTokens
///        - redeem() burns cTokens and returns underlying
///
///      The key difference: Compound adds BORROWING on top. Users can:
///        1. Supply tokens (like Uniswap's addLiquidity)
///        2. Use them as collateral to borrow OTHER tokens (no Uniswap equivalent)
///        3. Get liquidated if collateral value drops (no Uniswap equivalent)
///
///      WHY doTransferIn/doTransferOut:
///      The real Compound has both CErc20 (for ERC-20 tokens) and CEther (for native ETH).
///      The transfer functions are virtual so each variant can implement token movement
///      differently:
///        - CErc20: uses IERC20.transferFrom() and IERC20.transfer()
///        - CEther: uses msg.value and address.transfer()
///      Our simplified version only implements CErc20.
contract CErc20 is CTokenLiquidate {

    /// @notice The underlying ERC-20 token for this market
    /// @dev For example, if this is cUSDC, underlying is the USDC token contract.
    ///      Each CErc20 market wraps exactly ONE underlying token.
    address public underlying;

    /// @notice Reentrancy guard state
    /// @dev Uses the check-effects-interactions pattern PLUS a reentrancy guard.
    ///      The guard prevents attacks where a malicious token's transfer callback
    ///      re-enters the CToken before state updates are complete.
    ///
    ///      This is especially important for ERC-777 tokens or any token with transfer hooks.
    ///      While Compound historically only supported standard ERC-20s, the guard provides
    ///      defense in depth.
    modifier nonReentrant() {
        require(_notEntered, "CToken: re-entered");
        _notEntered = false;
        _;
        _notEntered = true;
    }

    /// @notice Initialize the CErc20 market
    /// @dev This replaces a constructor. In the real Compound, cTokens are deployed behind
    ///      proxies, so initialization happens separately from deployment. We keep this
    ///      pattern for educational consistency, but skip the proxy complexity.
    ///
    ///      The initial exchange rate is typically 0.02e18 (meaning 1 underlying = 50 cTokens).
    ///      This seemingly arbitrary ratio exists so that cToken balances have more precision
    ///      than underlying balances. Since cTokens have 8 decimals and most underlying
    ///      tokens have 18, the 50:1 ratio helps maintain precision in the exchange rate
    ///      as it grows over time.
    ///
    /// @param underlying_ The ERC-20 token this cToken wraps
    /// @param comptroller_ The Comptroller (risk engine)
    /// @param interestRateModel_ The interest rate model
    /// @param initialExchangeRateMantissa_ Initial cToken-to-underlying rate (e.g., 0.02e18)
    /// @param name_ The cToken name (e.g., "Compound USD Coin")
    /// @param symbol_ The cToken symbol (e.g., "cUSDC")
    /// @param decimals_ The cToken decimals (typically 8)
    function initialize(
        address underlying_,
        address comptroller_,
        address interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) external {
        // Only allow initialization once
        require(admin == address(0), "CErc20: already initialized");
        require(initialExchangeRateMantissa_ > 0, "CErc20: invalid initial exchange rate");

        admin = msg.sender;

        // Set the Comptroller
        comptroller = IComptroller(comptroller_);

        // Set the interest rate model
        interestRateModel = IInterestRateModel(interestRateModel_);

        // Set initial exchange rate
        initialExchangeRateMantissa = initialExchangeRateMantissa_;

        // Initialize interest accrual state
        accrualBlockNumber = block.number;
        borrowIndex = expScale; // 1e18 = 1.0 (no interest accrued yet)

        // Set ERC-20 metadata
        name = name_;
        symbol = symbol_;
        decimals = decimals_;

        // Set the underlying token
        underlying = underlying_;

        // Initialize reentrancy guard
        _notEntered = true;
    }

    // ============ User-Facing Entry Points ============

    /// @notice Supply underlying tokens to the protocol and receive cTokens
    /// @dev The user must first approve this contract to spend their underlying tokens.
    ///      Flow: user approves -> calls mint -> doTransferIn pulls tokens -> mintInternal mints cTokens
    ///
    ///      Note the order: doTransferIn FIRST, then mintInternal. This is because
    ///      mintFresh needs to know the actual amount received (which may differ from
    ///      mintAmount for fee-on-transfer tokens).
    ///
    /// @param mintAmount The amount of underlying tokens to supply
    /// @return 0 on success
    function mint(uint256 mintAmount) external nonReentrant returns (uint256) {
        doTransferIn(msg.sender, mintAmount);
        mintInternal(mintAmount);
        return 0;
    }

    /// @notice Redeem cTokens for underlying tokens
    /// @dev Burns exactly redeemTokens cTokens and returns the corresponding underlying.
    ///      The amount of underlying received depends on the current exchange rate.
    /// @param redeemTokens The number of cTokens to burn
    /// @return 0 on success
    function redeem(uint256 redeemTokens) external nonReentrant returns (uint256) {
        redeemInternal(redeemTokens);
        return 0;
    }

    /// @notice Redeem cTokens for an exact amount of underlying tokens
    /// @dev Burns enough cTokens to produce exactly redeemAmount of underlying.
    ///      The number of cTokens burned depends on the current exchange rate.
    /// @param redeemAmount The amount of underlying tokens to receive
    /// @return 0 on success
    function redeemUnderlying(uint256 redeemAmount) external nonReentrant returns (uint256) {
        redeemUnderlyingInternal(redeemAmount);
        return 0;
    }

    /// @notice Borrow underlying tokens from the protocol
    /// @dev The borrower must have sufficient collateral in entered markets.
    ///      The Comptroller checks cross-market solvency before allowing the borrow.
    /// @param borrowAmount The amount of underlying tokens to borrow
    /// @return 0 on success
    function borrow(uint256 borrowAmount) external nonReentrant returns (uint256) {
        borrowInternal(borrowAmount);
        return 0;
    }

    /// @notice Repay your own borrowed tokens
    /// @dev Pass type(uint256).max to repay the entire borrow balance.
    /// @param repayAmount The amount to repay (or type(uint256).max for full repay)
    /// @return 0 on success
    function repayBorrow(uint256 repayAmount) external nonReentrant returns (uint256) {
        repayBorrowInternal(repayAmount);
        return 0;
    }

    /// @notice Repay another user's borrowed tokens
    /// @dev Anyone can repay anyone's borrow. No approval needed (repaying helps the borrower).
    /// @param borrower The account whose borrow to repay
    /// @param repayAmount The amount to repay (or type(uint256).max for full repay)
    /// @return 0 on success
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external nonReentrant returns (uint256) {
        repayBorrowBehalfInternal(borrower, repayAmount);
        return 0;
    }

    /// @notice Liquidate an underwater borrower's position
    /// @dev The liquidator repays some of the borrower's debt and receives collateral
    ///      from the specified cTokenCollateral market at a discount.
    /// @param borrower The account to liquidate
    /// @param repayAmount The amount of this market's underlying to repay
    /// @param cTokenCollateral The market to seize collateral from
    /// @return 0 on success
    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        address cTokenCollateral
    ) external nonReentrant returns (uint256) {
        liquidateBorrowInternal(borrower, repayAmount, CTokenInterface(cTokenCollateral));
        return 0;
    }

    // ============ Underlying Token Transfers ============

    /// @notice Get the amount of underlying tokens held by this contract
    /// @dev Called by exchangeRateStoredInternal() to calculate the exchange rate:
    ///      exchangeRate = (cash + totalBorrows - totalReserves) / totalSupply
    ///
    ///      "Cash" is the underlying tokens physically present in this contract.
    ///      Tokens that have been borrowed are NOT in the contract (they're with the borrower),
    ///      but they're tracked in totalBorrows.
    /// @return The underlying token balance of this contract
    function getCashPrior() internal view override returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /// @notice Transfer underlying tokens INTO this contract (from a user)
    /// @dev Uses ERC-20 transferFrom. The caller must have approved this contract.
    ///
    ///      IMPORTANT: We check the balance before and after to determine the actual
    ///      amount received. This handles fee-on-transfer tokens correctly: if a token
    ///      charges a 1% transfer fee, transferFrom(100) only adds 99 to our balance.
    ///      We use the actual received amount for all calculations.
    ///
    ///      The real Compound V2 uses this exact pattern. It's critical for supporting
    ///      tokens like USDT (which has a fee mechanism, though currently set to 0).
    ///
    /// @param from The account to transfer from
    /// @param amount The requested transfer amount
    /// @return The actual amount received (may be less for fee-on-transfer tokens)
    function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
        uint256 balanceBefore = IERC20(underlying).balanceOf(address(this));

        // Transfer tokens from the user to this contract
        bool success = IERC20(underlying).transferFrom(from, address(this), amount);
        require(success, "CErc20: transfer in failed");

        // Calculate actual amount received (handles fee-on-transfer tokens)
        uint256 balanceAfter = IERC20(underlying).balanceOf(address(this));
        uint256 actualAmount = balanceAfter - balanceBefore;

        return actualAmount;
    }

    /// @notice Transfer underlying tokens OUT of this contract (to a user)
    /// @dev Uses ERC-20 transfer. Called during redeem, borrow, and when returning
    ///      excess repayment.
    /// @param to The account to transfer to
    /// @param amount The amount to transfer
    function doTransferOut(address to, uint256 amount) internal override {
        bool success = IERC20(underlying).transfer(to, amount);
        require(success, "CErc20: transfer out failed");
    }

    // ============ ERC-20 Token Functions ============
    //
    // The cToken IS an ERC-20 token. Users can transfer, approve, and trade cTokens
    // just like any other ERC-20. However, transfers are subject to Comptroller approval
    // (transferAllowed) because moving cTokens changes the sender's collateral position.

    /// @notice Get the cToken balance of an account
    /// @param owner The account to query
    /// @return The cToken balance
    function balanceOf(address owner) external view returns (uint256) {
        return accountTokens[owner];
    }

    /// @notice Transfer cTokens to another account
    /// @dev Calls Comptroller.transferAllowed() to verify the sender has enough
    ///      remaining collateral after the transfer.
    /// @param dst The recipient
    /// @param amount The number of cTokens to transfer
    /// @return True on success
    function transfer(address dst, uint256 amount) external nonReentrant returns (bool) {
        return _transferTokens(msg.sender, dst, amount);
    }

    /// @notice Transfer cTokens from one account to another (requires approval)
    /// @param src The sender
    /// @param dst The recipient
    /// @param amount The number of cTokens to transfer
    /// @return True on success
    function transferFrom(address src, address dst, uint256 amount) external nonReentrant returns (bool) {
        // Check and update allowance
        uint256 currentAllowance = transferAllowances[src][msg.sender];
        require(currentAllowance >= amount, "CErc20: transfer amount exceeds allowance");

        // Update allowance (skip for max approval, gas optimization)
        if (currentAllowance != type(uint256).max) {
            transferAllowances[src][msg.sender] = currentAllowance - amount;
        }

        return _transferTokens(src, dst, amount);
    }

    /// @notice Approve another account to transfer your cTokens
    /// @param spender The account to approve
    /// @param amount The maximum amount they can transfer
    /// @return True on success
    function approve(address spender, uint256 amount) external returns (bool) {
        transferAllowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Get the transfer allowance for a spender
    /// @param owner The token owner
    /// @param spender The approved spender
    /// @return The remaining allowance
    function allowance(address owner, address spender) external view returns (uint256) {
        return transferAllowances[owner][spender];
    }

    /// @notice Internal token transfer logic
    /// @dev Checks with Comptroller before allowing the transfer. This is crucial:
    ///      if the sender has used their cTokens as collateral (entered the market),
    ///      transferring them away reduces their collateral. The Comptroller checks
    ///      whether the sender would still be solvent after the transfer.
    /// @param src The sender
    /// @param dst The recipient
    /// @param tokens The number of cTokens to transfer
    /// @return True on success
    function _transferTokens(address src, address dst, uint256 tokens) internal returns (bool) {
        require(src != dst, "CErc20: cannot transfer to self");

        // Check with Comptroller (may revert if sender would become undercollateralized)
        uint256 allowed = comptroller.transferAllowed(address(this), src, dst, tokens);
        require(allowed == 0, "CErc20: transfer rejected by comptroller");

        // Update balances
        accountTokens[src] -= tokens;
        accountTokens[dst] += tokens;

        emit Transfer(src, dst, tokens);
        return true;
    }

    // ============ View Functions ============

    /// @notice Get the underlying balance of a cToken holder (in underlying token units)
    /// @dev This is the "real" value of a user's cToken holdings:
    ///      underlyingBalance = cTokenBalance * exchangeRate
    ///
    ///      This is analogous to calculating an LP position's value in Uniswap V2:
    ///      LP value = lpTokens * (reserveX / totalSupply), for each reserve token.
    ///
    /// @param owner The account to query
    /// @return The underlying token value of the account's cTokens
    function balanceOfUnderlying(address owner) external view returns (uint256) {
        Exp memory exchangeRate = Exp({ mantissa: exchangeRateStoredInternal() });
        return mul_ScalarTruncate(exchangeRate, accountTokens[owner]);
    }

    /// @notice Get the current exchange rate (cToken to underlying)
    /// @return The exchange rate as a mantissa (scaled by 1e18)
    function exchangeRateStored() external view returns (uint256) {
        return exchangeRateStoredInternal();
    }

    /// @notice Get a borrower's current borrow balance (including accrued interest)
    /// @param account The borrower's address
    /// @return The current borrow balance in underlying units
    function borrowBalanceStored(address account) external view returns (uint256) {
        return borrowBalanceStoredInternal(account);
    }
}
