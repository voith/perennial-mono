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

    // cryptex controlled contracts
    uint256 coordinatorID;

    address perennialOwner = address(0x51);
    address cryptexOwner = address(0x52);

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
        ChainlinkTCAPAggregatorV3 tcapOracle = new ChainlinkTCAPAggregatorV3();
        ChainlinkFeedOracle oracle = new ChainlinkFeedOracle(ChainlinkAggregator.wrap(address(tcapOracle)));
        IProduct.ProductInfo memory productInfo = IProduct.ProductInfo({
            name: 'Total Market Cap',
            symbol: 'TCAP',
            payoffDefinition: PayoffDefinition({
                payoffType: PayoffDefinitionLib.PayoffType.PASSTHROUGH,
                payoffDirection: PayoffDefinitionLib.PayoffDirection.LONG,
                data: bytes30('')
            }),
            oracle: oracle,
            maintenance: UFixed18.wrap(parseEther(10) / 100),
            fundingFee: UFixed18.wrap(parseEther(5) / 100),
            makerFee: UFixed18.wrap(parseEther(15) / 1000),
            takerFee: UFixed18.wrap(parseEther(15) / 1000),
            positionFee: UFixed18.wrap(parseEther(100) / 1000),
            makerLimit: UFixed18.wrap(parseEther(4000)),
            utilizationCurve: JumpRateUtilizationCurve({
              minRate: PackedFixed18.wrap(int128(uint128(parseEther(0)))),
              maxRate: PackedFixed18.wrap(int128(uint128(parseEther(80) / 100))),
              targetRate: PackedFixed18.wrap(int128(uint128(parseEther(6) / 100))),
              targetUtilization: PackedUFixed18.wrap(uint128(parseEther(80) / 100))
            })
        });
        IProduct long = controller.createProduct(coordinatorID, productInfo);
        productInfo.payoffDefinition.payoffDirection = PayoffDefinitionLib.PayoffDirection.SHORT;
        IProduct short = controller.createProduct(coordinatorID, productInfo);
        vaultImpl = new BalancedVault(
            Token18.wrap(address(DSU)), controller, long, short, UFixed18.wrap(parseEther(25) / 10), UFixed18.wrap(parseEther(3000000))
        );
        vaultProxy = new TransparentUpgradeableProxy(address(vaultImpl), address(proxyAdmin), bytes(''));
        vault = BalancedVault(address(vaultProxy));
        vault.initialize('Cryptex Vault Alpha', 'CVA');
        vm.stopPrank();
    }

    function testPerennialSetup() external {
		assertEq(address(collateral.controller()), address(controller));
        assertEq(address(incentivizer.controller()), address(controller));
        assertEq(address(controller.productBeacon()), address(productBeacon));
        assertEq(proxyAdmin.owner(), perennialOwner);
        assertEq(address(controller.coordinators(0).pendingOwner), perennialOwner);
    }
}
