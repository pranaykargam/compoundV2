// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.5.11;

import {Test} from "forge-std/Test.sol";
import {CErc20} from "../src/CErc20.sol";
import {ComptrollerHooks} from "../src/ComptrollerHooks.sol";
import {SimplePriceOracle} from "../src/PriceOracle.sol";
import {JumpRateModel} from "../src/InterestRateModel.sol";
import {LiquidationComptrollerReference} from "../src/LiquidationComptrollerReference.sol";
import {ExponentialNoError} from "../src/ExponentialNoError.sol";

contract ExponentialHarness is ExponentialNoError {
    function multiply(uint256 a, uint256 b) external pure returns (uint256) {
        return mul_(a, b);
    }

    function divideByExp(uint256 a, uint256 b) external pure returns (uint256) {
        return div_(a, Exp({mantissa: b}));
    }

    function multiplyExp(uint256 a, uint256 b) external pure returns (uint256) {
        return mul_(Exp({mantissa: a}), Exp({mantissa: b})).mantissa;
    }
}

contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) allowance[from][msg.sender] = approved - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CompoundV2Test is Test {
    uint256 internal constant WAD = 1e18;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    MockERC20 internal underlying;
    CErc20 internal cToken;
    ComptrollerHooks internal comptroller;
    SimplePriceOracle internal oracle;
    JumpRateModel internal rateModel;
    ExponentialHarness internal math;

    function setUp() public {
        underlying = new MockERC20();
        oracle = new SimplePriceOracle();
        comptroller = new ComptrollerHooks();
        rateModel = new JumpRateModel(0, 1e17, 1e18, 8e17);
        math = new ExponentialHarness();
        cToken = new CErc20();
        cToken.initialize(address(underlying), address(comptroller), address(rateModel), 2e16, "Compound Mock", "cMOCK", 8);

        comptroller._setOracle(oracle);
        comptroller._setCloseFactor(5e17);
        comptroller._setLiquidationIncentive(108e16);
        comptroller._supportMarket(address(cToken));
        oracle.setUnderlyingPrice(address(cToken), WAD);
        comptroller._setCollateralFactor(address(cToken), 75e16);

        underlying.mint(alice, 2_000 * WAD);
        underlying.mint(bob, 2_000 * WAD);
        vm.prank(alice);
        underlying.approve(address(cToken), type(uint256).max);
        vm.prank(bob);
        underlying.approve(address(cToken), type(uint256).max);
    }

    function testInterestRateModelBelowAndAboveKink() public view {
        assertEq(rateModel.utilizationRate(100 * WAD, 0, 0), 0);
        uint256 belowKink = rateModel.getBorrowRate(100 * WAD, 50 * WAD, 0);
        uint256 aboveKink = rateModel.getBorrowRate(10 * WAD, 90 * WAD, 0);
        assertGt(aboveKink, belowKink);
        assertGt(rateModel.getSupplyRate(100 * WAD, 50 * WAD, 0, 1e17), 0);
    }

    function testExponentialNoErrorMath() public view {
        assertEq(math.multiply(4, 7), 28);
        assertEq(math.divideByExp(21 * WAD, 3 * WAD), 7 * WAD);
        assertEq(math.multiplyExp(2 * WAD, 3 * WAD), 6 * WAD);
    }

    function testOracleRejectsNonOwnerPriceUpdates() public {
        vm.prank(alice);
        vm.expectRevert("SimplePriceOracle: only admin");
        oracle.setUnderlyingPrice(address(cToken), 2 * WAD);
    }

    function testOracleAndComptrollerMarketConfiguration() public {
        assertEq(oracle.getUnderlyingPrice(address(cToken)), WAD);
        assertEq(comptroller.mintAllowed(address(cToken), alice, WAD), 0);
        vm.prank(alice);
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        uint256[] memory results = comptroller.enterMarkets(markets);
        assertEq(results[0], 0);
        assertTrue(comptroller.checkMembership(alice, address(cToken)));
        assertEq(comptroller.getAssetsIn(alice).length, 1);
    }

    function testMintRedeemAndCTokenTransfers() public {
        vm.prank(alice);
        cToken.mint(100 * WAD);
        uint256 minted = cToken.balanceOf(alice);
        assertEq(minted, 5_000 * WAD);
        assertEq(cToken.balanceOfUnderlying(alice), 100 * WAD);

        vm.prank(alice);
        cToken.transfer(bob, 1_000 * WAD);
        assertEq(cToken.balanceOf(bob), 1_000 * WAD);
        vm.prank(alice);
        cToken.approve(bob, 500 * WAD);
        vm.prank(bob);
        cToken.transferFrom(alice, bob, 500 * WAD);
        assertEq(cToken.allowance(alice, bob), 0);

        vm.prank(bob);
        cToken.redeemUnderlying(10 * WAD);
        assertEq(underlying.balanceOf(bob), 2_010 * WAD);
    }

    function testCTokenSnapshotAndExchangeRateViews() public {
        vm.prank(alice);
        cToken.mint(20 * WAD);
        (uint256 err, uint256 tokens, uint256 borrows, uint256 exchangeRate) = cToken.getAccountSnapshot(alice);
        assertEq(err, 0);
        assertEq(tokens, 1_000 * WAD);
        assertEq(borrows, 0);
        assertEq(exchangeRate, 2e16);
        assertEq(cToken.exchangeRateStored(), 2e16);
    }

    function testCTokenRejectsSecondInitialization() public {
        vm.expectRevert("CErc20: already initialized");
        cToken.initialize(address(underlying), address(comptroller), address(rateModel), 2e16, "Again", "AGAIN", 8);
    }

    function testMintRejectsUnlistedMarket() public {
        CErc20 unlisted = new CErc20();
        unlisted.initialize(address(underlying), address(comptroller), address(rateModel), 2e16, "Unlisted", "uMOCK", 8);
        vm.prank(alice);
        underlying.approve(address(unlisted), WAD);
        vm.prank(alice);
        vm.expectRevert("Comptroller: market not listed");
        unlisted.mint(WAD);
    }

    function testBorrowRepayAndInterestAccrual() public {
        vm.prank(alice);
        cToken.mint(1_000 * WAD);
        vm.prank(alice);
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        comptroller.enterMarkets(markets);

        vm.prank(alice);
        cToken.borrow(100 * WAD);
        assertEq(cToken.borrowBalanceStored(alice), 100 * WAD);
        assertEq(cToken.totalBorrows(), 100 * WAD);

        vm.roll(block.number + 100);
        cToken.accrueInterest();
        assertGt(cToken.borrowBalanceStored(alice), 100 * WAD);
        vm.prank(alice);
        cToken.repayBorrow(type(uint256).max);
        assertEq(cToken.borrowBalanceStored(alice), 0);
        assertEq(cToken.totalBorrows(), 0);
    }

    function testRepayBorrowOnBehalf() public {
        vm.prank(alice);
        cToken.mint(1_000 * WAD);
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        vm.prank(alice);
        comptroller.enterMarkets(markets);
        vm.prank(alice);
        cToken.borrow(100 * WAD);

        vm.prank(bob);
        cToken.repayBorrowBehalf(alice, 40 * WAD);
        assertEq(cToken.borrowBalanceStored(alice), 60 * WAD);
        assertEq(cToken.totalBorrows(), 60 * WAD);
    }

    function testExitMarketRemovesMembershipWhenNoBorrow() public {
        vm.prank(alice);
        cToken.mint(100 * WAD);
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        vm.prank(alice);
        comptroller.enterMarkets(markets);
        vm.prank(alice);
        assertEq(comptroller.exitMarket(address(cToken)), 0);
        assertFalse(comptroller.checkMembership(alice, address(cToken)));
        assertEq(comptroller.getAssetsIn(alice).length, 0);
    }

    function testLiquidityAndBorrowPolicyRejectInsufficientCollateral() public {
        vm.prank(alice);
        cToken.mint(100 * WAD);
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        vm.prank(alice);
        comptroller.enterMarkets(markets);
        vm.prank(alice);
        vm.expectRevert("Comptroller: insufficient collateral for borrow");
        cToken.borrow(76 * WAD);
    }

    function testLiquidationTransfersCollateralAndReducesDebt() public {
        MockERC20 debtUnderlying = new MockERC20();
        CErc20 debtMarket = new CErc20();
        debtMarket.initialize(address(debtUnderlying), address(comptroller), address(rateModel), 2e16, "Compound Debt", "cDEBT", 8);
        comptroller._supportMarket(address(debtMarket));
        oracle.setUnderlyingPrice(address(debtMarket), WAD);

        debtUnderlying.mint(bob, 2_000 * WAD);
        vm.prank(bob);
        debtUnderlying.approve(address(debtMarket), type(uint256).max);
        vm.prank(bob);
        debtMarket.mint(1_000 * WAD);

        vm.prank(alice);
        cToken.mint(1_000 * WAD);
        address[] memory markets = new address[](1);
        markets[0] = address(cToken);
        vm.prank(alice);
        comptroller.enterMarkets(markets);
        vm.prank(alice);
        debtMarket.borrow(500 * WAD);

        // Make the collateral worth half as much, creating a shortfall.
        oracle.setUnderlyingPrice(address(cToken), 5e17);
        (, , uint256 shortfall) = comptroller.getAccountLiquidity(alice);
        assertGt(shortfall, 0);
        uint256 bobTokensBefore = cToken.balanceOf(bob);

        vm.prank(bob);
        debtMarket.liquidateBorrow(alice, 200 * WAD, address(cToken));
        assertEq(debtMarket.borrowBalanceStored(alice), 300 * WAD);
        assertGt(cToken.balanceOf(bob), bobTokensBefore);
    }

    function testLiquidationReferenceAcceptsZeroDebtRepayment() public {
        LiquidationComptrollerReference liquidationPolicy = new LiquidationComptrollerReference();
        assertEq(liquidationPolicy.liquidateBorrowAllowed(address(cToken), address(cToken), alice, 0), 0);
    }
}
