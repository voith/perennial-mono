// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@equilibria/perennial/contracts/test/TestnetUSDC.sol";
import "@equilibria/perennial/contracts/test/TestnetDSU.sol";
import "@equilibria/perennial/contracts/test/TestnetReserve.sol";
import "@equilibria/perennial/contracts/test/TestnetBatcher.sol";
import "@equilibria/perennial/contracts/collateral/Collateral.sol";
import "@equilibria/perennial/contracts/product/Product.sol";
import "@equilibria/perennial/contracts/incentivizer/Incentivizer.sol";
import "@equilibria/perennial/contracts/controller/Controller.sol";
import "@equilibria/perennial/contracts/forwarder/Forwarder.sol";
import "@equilibria/perennial/contracts/interfaces/types/PayoffDefinition.sol";
import "@equilibria/perennial/contracts/lens/PerennialLens.sol";
import "@equilibria/perennial/contracts/multiinvoker/MultiInvoker.sol";
import "@equilibria/perennial-oracle/contracts/ChainlinkFeedOracle.sol";
import "@equilibria/perennial-oracle/contracts/types/ChainlinkAggregator.sol";
import "@equilibria/perennial-vaults/contracts/BalancedVault.sol";

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import "./mocks/ChainlinkTCAPAggregatorV3.sol";
import "./contracts/TcapPayoffProvider.sol";


contract IntegrationTest is Test {
    TestnetUSDC USDC;
    TestnetDSU DSU;
    TestnetReserve reserve;
    TestnetBatcher batcher;
    Collateral collateral;
    Product product;
    Incentivizer incentivizer;
    Controller controller;
    Collateral collateralImpl;
    Product productImpl;
    Incentivizer incentivizerImpl;
    Controller controllerImpl;
    TimelockController timelock;
    ProxyAdmin proxyAdmin;
    UpgradeableBeacon productBeacon;
    TransparentUpgradeableProxy incentivizerProxy;
    TransparentUpgradeableProxy collateralProxy;
    TransparentUpgradeableProxy controllerProxy;
    PerennialLens lens;
    MultiInvoker multiInvokerImpl;
    TransparentUpgradeableProxy multiInvokerProxy;
    MultiInvoker multiInvoker;
    Forwarder forwarder;
    BalancedVault vaultImpl;
    TransparentUpgradeableProxy vaultProxy;
    BalancedVault vault;
    IProduct long;
    IProduct short;
    ChainlinkTCAPAggregatorV3 tcapOracle;

    Fixed18 makerFeeRate = Fixed18Lib.from(int256(15)).div(Fixed18Lib.from(int256(1000)));
    Fixed18 takerFeeRate = Fixed18Lib.from(int256(15)).div(Fixed18Lib.from(int256(1000)));

    // cryptex controlled contracts
    uint256 coordinatorID;

    address perennialOwner = address(0x51);
    address cryptexOwner = address(0x52);
    address userA = address(0x53);
    address userB = address(0x54);
    address userC = address(0x55);
    address cryptexTreasury = address(0x56);
    address perennialTreasury = address(0x57);

    event AccountSettle(IProduct indexed product, address indexed account, Fixed18 amount, UFixed18 newShortfall);

    function setUp() external {
        vm.startPrank(perennialOwner);
        USDC = new TestnetUSDC();
        DSU = new TestnetDSU(perennialOwner);
        reserve = new TestnetReserve(Token18.wrap(address(DSU)), Token6.wrap(address(USDC)));
        batcher = new TestnetBatcher(reserve, Token6.wrap(address(USDC)), Token18.wrap(address(DSU)));
        collateralImpl = new Collateral(Token18.wrap(address(DSU)));
        productImpl = new Product();
        incentivizerImpl = new Incentivizer();
        controllerImpl = new Controller();
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = perennialOwner;
        executors[0] = address(0x0);
        timelock = new TimelockController(60, proposers, executors, perennialOwner);
        proxyAdmin = new ProxyAdmin();
        productBeacon = new UpgradeableBeacon(address(productImpl));
        incentivizerProxy = new TransparentUpgradeableProxy(address(incentivizerImpl), address(proxyAdmin), bytes(''));
        incentivizer = Incentivizer(address(incentivizerProxy));
        collateralProxy = new TransparentUpgradeableProxy(address(collateralImpl), address(proxyAdmin), bytes(''));
        collateral = Collateral(address(collateralProxy));
        controllerProxy = new TransparentUpgradeableProxy(address(controllerImpl), address(proxyAdmin), bytes(''));
        controller = Controller(address(controllerProxy));
        incentivizer.initialize(controller);
        collateral.initialize(controller);
        controller.initialize(collateral, incentivizer, productBeacon);
        controller.updateCoordinatorPendingOwner(0, perennialOwner);
        controller.updateCoordinatorTreasury(0, perennialTreasury);
        controller.updateProtocolFee(UFixed18.wrap(0));
        lens = new PerennialLens(controller);
        forwarder = new Forwarder(Token6.wrap(address(USDC)), Token18.wrap(address(DSU)), batcher, collateral);
        multiInvokerImpl = new MultiInvoker(Token6.wrap(address(USDC)), batcher, reserve, controller);
        multiInvokerProxy = new TransparentUpgradeableProxy(address(multiInvokerImpl), address(proxyAdmin), bytes(''));
        multiInvoker = MultiInvoker(address(multiInvokerProxy));
        multiInvoker.initialize();
        vm.stopPrank();
        cryptexSetup();
    }

    function parseEther(uint256 value) public returns(uint256) {
        return value * 10 ** 18;
    }

    function cryptexSetup() public {
        vm.startPrank(cryptexOwner);
        coordinatorID = controller.createCoordinator();
        tcapOracle = new ChainlinkTCAPAggregatorV3();
        ChainlinkFeedOracle oracle = new ChainlinkFeedOracle(ChainlinkAggregator.wrap(address(tcapOracle)));
        TcapPayoffProvider payoffProvider = new TcapPayoffProvider();
        IProduct.ProductInfo memory productInfo = IProduct.ProductInfo({
            name: 'Total Market Cap',
            symbol: 'TCAP',
            payoffDefinition: PayoffDefinition({
                payoffType: PayoffDefinitionLib.PayoffType.CONTRACT,
                payoffDirection: PayoffDefinitionLib.PayoffDirection.LONG,
                data: bytes30(bytes20(address(payoffProvider))) >> 80
            }),
            oracle: oracle,
            maintenance: UFixed18Lib.from(10).div(UFixed18Lib.from(100)),
            fundingFee: UFixed18Lib.from(5).div(UFixed18Lib.from(100)),
            makerFee: UFixed18Lib.from(15).div(UFixed18Lib.from(1000)),
            takerFee: UFixed18Lib.from(15).div(UFixed18Lib.from(1000)),
            positionFee: UFixed18Lib.from(100).div(UFixed18Lib.from(100)),
            makerLimit: UFixed18.wrap(parseEther(4000)),
            utilizationCurve: JumpRateUtilizationCurve({
              minRate: Fixed18Lib.from(int256(0)).pack(),
              maxRate: Fixed18Lib.from(int256(80)).div(Fixed18Lib.from(int256(100))).pack(),
              targetRate: Fixed18Lib.from(int256(6)).div(Fixed18Lib.from(int256(100))).pack(),
              targetUtilization: UFixed18Lib.from(80).div(UFixed18Lib.from(100)).pack()
            })
        });
        long = controller.createProduct(coordinatorID, productInfo);
        productInfo.payoffDefinition.payoffDirection = PayoffDefinitionLib.PayoffDirection.SHORT;
        short = controller.createProduct(coordinatorID, productInfo);
        controller.updateCoordinatorTreasury(coordinatorID, cryptexTreasury);
        vaultImpl = new BalancedVault(
            Token18.wrap(address(DSU)),
            controller,
            long,
            short,
            UFixed18.wrap(parseEther(25) / 10),
            UFixed18.wrap(parseEther(3000000))
        );
        vaultProxy = new TransparentUpgradeableProxy(address(vaultImpl), address(proxyAdmin), bytes(''));
        vault = BalancedVault(address(vaultProxy));
        vault.initialize('Cryptex Vault Alpha', 'CVA');
        vm.stopPrank();

        vm.deal(userA, 30000 ether);
        vm.deal(userB, 30000 ether);
        vm.deal(userC, 30000 ether);
        deal({token: address(DSU), to: userA, give: 1000000 ether});
        deal({token: address(DSU), to: userB, give: 1000000 ether});
        deal({token: address(DSU), to: userC, give: 1000000 ether});
        tcapOracle.next();
    }

    function testPerennialSetup() external {
		assertEq(address(collateral.controller()), address(controller));
        assertEq(address(incentivizer.controller()), address(controller));
        assertEq(address(controller.productBeacon()), address(productBeacon));
        assertEq(proxyAdmin.owner(), perennialOwner);
        assertEq(address(controller.coordinators(0).pendingOwner), perennialOwner);
        assertEq(address(multiInvoker.batcher()), address(batcher));
        assertEq(address(multiInvoker.reserve()), address(reserve));
    }

    function testCryptexSetup() external {
        assertEq(address(vault.controller()), address(controller));
        assertEq(address(vault.collateral()), address(collateral));
        assertEq(address(vault.long()), address(long));
        assertEq(address(vault.short()), address(short));
    }

    function depositTo(address account, IProduct _product, UFixed18 position) public {
        vm.startPrank(account);
        DSU.approve(address(collateral), uint256(UFixed18.unwrap(position)));
        collateral.depositTo(account, _product, position);
        vm.stopPrank();
    }

    function testOpenPositionFees() external {
        UFixed18 initialCollateral = UFixed18Lib.from(20000);
        Fixed18 makerPosition = Fixed18Lib.from(int256(1)).div(Fixed18Lib.from(int256(1000))); // 0.001
        Fixed18 takerPosition = Fixed18Lib.from(int256(1)).div(Fixed18Lib.from(int256(1000))); // 0.001

        depositTo(userA, long, initialCollateral);
        depositTo(userB, long, initialCollateral);
        depositTo(userC, long, initialCollateral);

        IOracleProvider.OracleVersion memory currentVersion = long.currentVersion();
        Fixed18 makerFee = makerPosition.mul(currentVersion.price).mul(makerFeeRate);
        Fixed18 takerFee = takerPosition.mul(currentVersion.price).mul(takerFeeRate);

        vm.startPrank(userA);
        vm.expectEmit(true, true, true, true, address(collateral));
        emit AccountSettle(long, userA, Fixed18(makerFee).mul(Fixed18.wrap(int256(-1))), UFixed18.wrap(0));
        long.openMake(UFixed18Lib.from(makerPosition));
        vm.stopPrank();

        vm.startPrank(userB);
        vm.expectEmit(true, true, true, true, address(collateral));
        emit AccountSettle(long, userB, Fixed18(makerFee).mul(Fixed18.wrap(int256(-2))), UFixed18.wrap(0));
        long.openMake(UFixed18Lib.from(makerPosition.mul(Fixed18Lib.from(int256(2)))));
        vm.stopPrank();

        vm.startPrank(userC);
        vm.expectEmit(true, true, true, true, address(collateral));
        emit AccountSettle(long, userC, takerFee.mul(Fixed18.wrap(int256(-1))), UFixed18.wrap(0));
        long.openTake(UFixed18Lib.from(takerPosition));
        vm.stopPrank();

        assertEq(
            UFixed18.unwrap(collateral.collateral(userA, long)),
            UFixed18.unwrap(initialCollateral.sub(UFixed18Lib.from(makerFee)))
        );
        assertEq(
            UFixed18.unwrap(collateral.collateral(userB, long)),
            UFixed18.unwrap(initialCollateral.sub(UFixed18Lib.from(makerFee.mul(Fixed18Lib.from(int256(2))))))
        );
        assertEq(
            UFixed18.unwrap(collateral.collateral(userC, long)),
            UFixed18.unwrap(initialCollateral.sub(UFixed18Lib.from(takerFee)))
        );
    }

    function testCreditFeesTOTreasury() external {
        UFixed18 initialCollateral = UFixed18Lib.from(20000);
        Fixed18 makerPosition = Fixed18Lib.from(int256(1)).div(Fixed18Lib.from(int256(1000))); // 0.001
        Fixed18 takerPosition = Fixed18Lib.from(int256(1)).div(Fixed18Lib.from(int256(1000))); // 0.001

        depositTo(userA, long, initialCollateral);
        depositTo(userB, long, initialCollateral);
        depositTo(userC, long, initialCollateral);

        vm.prank(userA);
        long.openMake(UFixed18Lib.from(makerPosition));
        vm.prank(userB);
        long.openMake(UFixed18Lib.from(makerPosition.mul(Fixed18Lib.from(int256(2)))));
        vm.prank(userC);
        long.openTake(UFixed18Lib.from(takerPosition));

        IOracleProvider.OracleVersion memory currentVersion = long.currentVersion();
        Fixed18 makerFee = makerPosition.mul(Fixed18Lib.from(int256(3))).mul(currentVersion.price).mul(makerFeeRate);
        Fixed18 takerFee = takerPosition.mul(currentVersion.price).mul(takerFeeRate);
        Fixed18 totalFee = makerFee.add(takerFee);

        tcapOracle.next();
        long.settle();
        assertEq(UFixed18.unwrap(collateral.fees(perennialTreasury)), 0);
        assertEq(UFixed18.unwrap(collateral.fees(cryptexTreasury)), UFixed18.unwrap(UFixed18Lib.from(totalFee)));
    }
}
