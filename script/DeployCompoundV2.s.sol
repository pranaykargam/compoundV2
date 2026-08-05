// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.8.0;

import {Script} from "forge-std/Script.sol";
import {CErc20} from "../src/CErc20.sol";
import {ComptrollerHooks} from "../src/ComptrollerHooks.sol";
import {SimplePriceOracle} from "../src/PriceOracle.sol";
import {JumpRateModel} from "../src/InterestRateModel.sol";

/// @notice Deploys and configures one ERC-20-backed Compound V2 market.
/// @dev Set UNDERLYING to an already-deployed ERC-20 address before broadcasting.
contract DeployCompoundV2 is Script {
    uint256 internal constant EXP_SCALE = 1e18;
    uint256 internal constant INITIAL_EXCHANGE_RATE = 2e16;

    function run() external returns (CErc20 cToken, ComptrollerHooks comptroller, SimplePriceOracle oracle) {
        address underlying = vm.envAddress("UNDERLYING");

        vm.startBroadcast();
        oracle = new SimplePriceOracle();
        comptroller = new ComptrollerHooks();
        JumpRateModel rateModel = new JumpRateModel(0, 1e17, 1e18, 8e17);
        cToken = new CErc20();

        comptroller._setOracle(oracle);
        comptroller._setCloseFactor(5e17);
        comptroller._setLiquidationIncentive(108e16);
        cToken.initialize(
            underlying,
            address(comptroller),
            address(rateModel),
            INITIAL_EXCHANGE_RATE,
            "Compound Token",
            "cTOKEN",
            8
        );
        comptroller._supportMarket(address(cToken));
        oracle.setUnderlyingPrice(address(cToken), EXP_SCALE);
        comptroller._setCollateralFactor(address(cToken), 75e16);
        vm.stopBroadcast();
    }
}
