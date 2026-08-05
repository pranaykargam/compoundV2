// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

/// @title PriceOracle — Interface for fetching asset prices
/// @notice The Comptroller uses this to value collateral and borrows across markets.
///         Every risk calculation depends on correct oracle prices.
abstract contract PriceOracle {
    /// @notice Indicator that this is a PriceOracle contract
    bool public constant isPriceOracle = true;

    /// @notice Get the underlying price of a cToken asset.
    /// @dev Returns the price as a mantissa (scaled by 1e18).
    ///      A return value of 0 means the price is unavailable.
    ///      The Comptroller will reject operations when price is 0.
    /// @param cToken The cToken to get the underlying price of
    /// @return The underlying asset price in ETH (mantissa)
    function getUnderlyingPrice(address cToken) virtual external view returns (uint256);
}


/// @title SimplePriceOracle — Admin-set oracle for testing
/// @notice Prices are set manually by the admin. NOT for production use.
///         In production, Compound uses Chainlink price feeds via an adapter contract.
contract SimplePriceOracle is PriceOracle {
    /// @notice Maps cToken address to its underlying price (mantissa)
    mapping(address => uint256) public prices;

    /// @notice Admin who can set prices
    address public admin;

    event PricePosted(address cToken, uint256 previousPrice, uint256 newPrice);

    constructor() {
        admin = msg.sender;
    }

    /// @notice Set the price for a cToken's underlying asset.
    /// @param cToken The cToken address
    /// @param underlyingPriceMantissa The price (scaled by 1e18)
    function setUnderlyingPrice(address cToken, uint256 underlyingPriceMantissa) external {
        require(msg.sender == admin, "SimplePriceOracle: only admin");
        uint256 previousPrice = prices[cToken];
        prices[cToken] = underlyingPriceMantissa;
        emit PricePosted(cToken, previousPrice, underlyingPriceMantissa);
    }

    /// @notice Get the underlying price of a cToken asset.
    function getUnderlyingPrice(address cToken) override external view returns (uint256) {
        return prices[cToken];
    }
}
