import { expect } from 'chai'
import HRE from 'hardhat'
import { constants, utils } from 'ethers'
import { Deployment } from 'hardhat-deploy/types'
import {
  Collateral,
  Collateral__factory,
  Controller,
  Controller__factory,
  Forwarder,
  Forwarder__factory,
  Incentivizer,
  Incentivizer__factory,
  PerennialLens,
  PerennialLens__factory,
  ProxyAdmin,
  ProxyAdmin__factory,
  TimelockController,
  TimelockController__factory,
  UpgradeableBeacon,
  UpgradeableBeacon__factory,
} from '../../../../types/generated'
import { getMultisigAddress } from '../../../../../common/testutil/constants'

const { ethers } = HRE

describe('Core - Mainnet Verification', () => {
  let deployments: { [name: string]: Deployment }
  let controller: Controller
  let collateral: Collateral
  let incentivizer: Incentivizer
  let proxyAdmin: ProxyAdmin
  let upgradeableBeacon: UpgradeableBeacon
  let timelock: TimelockController
  let forwarder: Forwarder
  let lens: PerennialLens

  beforeEach(async () => {
    const [signer] = await ethers.getSigners()
    deployments = await HRE.deployments.all()
    controller = Controller__factory.connect(deployments['Controller_Proxy'].address, signer)
    collateral = Collateral__factory.connect(deployments['Collateral_Proxy'].address, signer)
    incentivizer = Incentivizer__factory.connect(deployments['Incentivizer_Proxy'].address, signer)
    proxyAdmin = ProxyAdmin__factory.connect(deployments['ProxyAdmin'].address, signer)
    upgradeableBeacon = UpgradeableBeacon__factory.connect(deployments['UpgradeableBeacon'].address, signer)
    timelock = TimelockController__factory.connect(deployments['TimelockController'].address, signer)
    forwarder = Forwarder__factory.connect(deployments['Forwarder'].address, signer)
    lens = PerennialLens__factory.connect(deployments['PerennialLens_V01'].address, signer)
  })

  describe('controller', () => {
    it('is already initialized', async () => {
      await expect(
        controller.callStatic.initialize(collateral.address, incentivizer.address, upgradeableBeacon.address),
      ).to.be.revertedWithCustomError(controller, 'UInitializableAlreadyInitializedError')
    })

    it('has the correct parameters and configuration', async () => {
      const timelockAddress = timelock.address

      expect(await controller.collateral()).to.equal(collateral.address)
      expect(await controller.incentivizer()).to.equal(incentivizer.address)
      expect(await controller.productBeacon()).to.equal(upgradeableBeacon.address)

      // Protocol owner
      expect(await controller['owner()']()).to.equal(timelockAddress)
      expect(await controller['treasury()']()).to.equal(timelockAddress)
      expect(await controller['pendingOwner()']()).to.equal(constants.AddressZero)

      // Coordinator 0 == Protocol owner
      expect(await controller['owner(uint256)'](0)).to.equal(timelockAddress)
      expect(await controller['treasury(uint256)'](0)).to.equal(timelockAddress)
      expect(await controller['pendingOwner(uint256)'](0)).to.equal(constants.AddressZero)

      // Coordinator 1 == Protocol owner at launch
      expect(await controller['owner(uint256)'](1)).to.equal(getMultisigAddress('mainnet'))
      expect(await controller['treasury(uint256)'](1)).to.equal(getMultisigAddress('mainnet'))
      expect(await controller['pendingOwner(uint256)'](1)).to.equal(constants.AddressZero)

      expect(await controller.protocolFee()).to.equal(0)
      expect(await controller.minFundingFee()).to.equal(0)
      expect(await controller.liquidationFee()).to.equal(utils.parseEther('0.10'))
      expect(await controller.incentivizationFee()).to.equal(0)
      expect(await controller.minCollateral()).to.equal(utils.parseEther('100'))
      expect(await controller.programsPerProduct()).to.equal(0)

      expect(await controller.pauser()).to.equal(getMultisigAddress('mainnet'))
      expect(await controller.paused()).to.be.false

      const longEtherAddress = deployments['Product_LongEther'].address
      expect(await controller.isProduct(longEtherAddress)).to.be.true
      expect(await controller.coordinatorFor(longEtherAddress)).to.equal(1)
      expect(await controller['owner(address)'](longEtherAddress)).to.equal(getMultisigAddress('mainnet'))
      expect(await controller['treasury(address)'](longEtherAddress)).to.equal(getMultisigAddress('mainnet'))

      const shortEtherAddress = deployments['Product_ShortEther'].address
      expect(await controller.isProduct(shortEtherAddress)).to.be.true
      expect(await controller.coordinatorFor(shortEtherAddress)).to.equal(1)
      expect(await controller['owner(address)'](shortEtherAddress)).to.equal(getMultisigAddress('mainnet'))
      expect(await controller['treasury(address)'](shortEtherAddress)).to.equal(getMultisigAddress('mainnet'))
    })
  })

  describe('collateral', () => {
    it('is already initialized', async () => {
      await expect(collateral.callStatic.initialize(controller.address)).to.be.revertedWithCustomError(
        collateral,
        'UInitializableAlreadyInitializedError',
      )
    })

    it('has the correct configuration', async () => {
      expect(await collateral.controller()).to.equal(controller.address)
      expect(await collateral.token()).to.equal(deployments['DSU'].address)
    })
  })

  describe('incentivizer', () => {
    it('is already initialized', async () => {
      await expect(incentivizer.callStatic.initialize(controller.address)).to.be.revertedWithCustomError(
        incentivizer,
        'UInitializableAlreadyInitializedError',
      )
    })

    it('has the correct configuration', async () => {
      expect(await incentivizer.controller()).to.equal(controller.address)
    })
  })

  describe('proxyAdmin', () => {
    it('has the correct configuration', async () => {
      expect(await proxyAdmin.owner()).to.equal(timelock.address)

      expect(await proxyAdmin.getProxyAdmin(controller.address)).to.equal(proxyAdmin.address)
      expect(await proxyAdmin.getProxyImplementation(controller.address)).to.equal(
        deployments['Controller_Impl'].address,
      )

      expect(await proxyAdmin.getProxyAdmin(collateral.address)).to.equal(proxyAdmin.address)
      expect(await proxyAdmin.getProxyImplementation(collateral.address)).to.equal(
        deployments['Collateral_Impl'].address,
      )

      expect(await proxyAdmin.getProxyAdmin(incentivizer.address)).to.equal(proxyAdmin.address)
      expect(await proxyAdmin.getProxyImplementation(incentivizer.address)).to.equal(
        deployments['Incentivizer_Impl'].address,
      )
    })
  })

  describe('upgradeablebeacon', () => {
    it('has the correct configuration', async () => {
      expect(await upgradeableBeacon.owner()).to.equal(timelock.address)
      expect(await upgradeableBeacon.implementation()).to.equal(deployments['Product_Impl'].address)
    })
  })

  describe('timelock', () => {
    it('has the correct configuration', async () => {
      expect(await timelock.getMinDelay()).to.equal(172800) // 48 hours
      const timelockAdminRole = await timelock.TIMELOCK_ADMIN_ROLE()
      const timelockProposerRole = await timelock.PROPOSER_ROLE()
      const timelockExecutorRole = await timelock.EXECUTOR_ROLE()
      const eqMultisigAddress = '0x589CDCf60aea6B961720214e80b713eB66B89A4d'
      const pnlLabsMultisigAddress = '0xA20ea565cD799e01A86548af5a2929EB7c767fC9'
      const deployerSigAddress = '0x66a7fDB96C583c59597de16d8b2B989231415339'

      expect(await timelock.hasRole(timelockAdminRole, timelock.address)).to.be.true
      expect(await timelock.hasRole(timelockAdminRole, getMultisigAddress('mainnet') || '')).to.be.true /* false */
      expect(await timelock.hasRole(timelockAdminRole, pnlLabsMultisigAddress)).to.be.false
      expect(await timelock.hasRole(timelockAdminRole, eqMultisigAddress)).to.be.false
      expect(await timelock.hasRole(timelockAdminRole, deployerSigAddress)).to.be.false

      expect(await timelock.hasRole(timelockProposerRole, getMultisigAddress('mainnet') || '')).to.be.true
      expect(await timelock.hasRole(timelockProposerRole, pnlLabsMultisigAddress)).to.be.false
      expect(await timelock.hasRole(timelockProposerRole, eqMultisigAddress)).to.be.false
      expect(await timelock.hasRole(timelockProposerRole, deployerSigAddress)).to.be.false

      expect(await timelock.hasRole(timelockExecutorRole, ethers.constants.AddressZero)).to.be.true
    })
  })

  describe('lens', () => {
    it('has the correct configuration', async () => {
      const mainnetProvider = new ethers.providers.JsonRpcProvider(process.env.MAINNET_NODE_URL)
      expect(await mainnetProvider.resolveName('perennial-lens.eth')).to.equal(lens.address)
      expect(await lens.callStatic.controller()).to.equal(controller.address)
    })
  })

  /* describe('forwarder', () => {
    it('has the correct configuration', async () => {
      expect(await forwarder.DSU()).to.equal(deployments['DSU'].address)
      expect(await forwarder.USDC()).to.equal(deployments['USDC'].address)
      expect(await forwarder.batcher()).to.equal(deployments['Batcher'].address)
    })
  }) */
})
