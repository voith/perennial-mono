// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.14;

import "@equilibria/root/control/unstructured/UInitializable.sol";
import "@equilibria/root/control/unstructured/UReentrancyGuard.sol";
import "./types/position/AccountPosition.sol";
import "./types/accumulator/AccountAccumulator.sol";
import "../controller/UControllerProvider.sol";

/**
 * @title Product
 * @notice Manages logic and state for a single product market.
 * @dev Cloned by the Controller contract to launch new product markets.
 */
contract Product is IProduct, UInitializable, UControllerProvider, UReentrancyGuard {
    /// @dev The parameter provider of the product market
    IProductProvider public productProvider;

    /// @dev The individual position state for each account
    mapping(address => AccountPosition) private _positions;

    /// @dev The global position state for the product
    VersionedPosition private _position;

    /// @dev The individual accumulator state for each account
    mapping(address => AccountAccumulator) private _accumulators;

    /// @dev The global accumulator state for the product
    VersionedAccumulator private _accumulator;

    /**
     * @notice Initializes the contract state
     * @param productProvider_ Product provider contract address
     */
    function initialize(IProductProvider productProvider_) external initializer(1) {
        __UControllerProvider__initialize(IController(msg.sender));
        __UReentrancyGuard__initialize();

        productProvider = productProvider_;
    }

    /**
     * @notice Surfaces global settlement externally
     */
    function settle() external nonReentrant notPausedProduct(IProduct(this)) {
        settleInternal();
    }

    /**
     * @notice Core global settlement flywheel
     * @dev
     *  a) last settle oracle version
     *  b) latest pre position oracle version
     *  c) current oracle version
     *
     *  Settles from a->b then from b->c if either interval is non-zero to account for a change
     *  in position quantity at (b).
     *
     *  Syncs each to instantaneously after the oracle update.
     */
    function settleInternal() internal returns (IOracleProvider.OracleVersion memory currentOracleVersion) {
        (IProductProvider _provider, IController _controller) = (productProvider, controller());

        // Get current oracle version
        currentOracleVersion = _provider.sync();

        // Get latest oracle version
        uint256 _latestVersion = latestVersion();
        if (_latestVersion == currentOracleVersion.version) return currentOracleVersion; // short circuit entirely if a == c
        IOracleProvider.OracleVersion memory latestOracleVersion = _provider.atVersion(_latestVersion);

        // Get settle oracle version
        uint256 _settleVersion = _position.pre.settleVersion(currentOracleVersion.version);
        IOracleProvider.OracleVersion memory settleOracleVersion = _settleVersion == currentOracleVersion.version ?
            currentOracleVersion : // if b == c, don't re-call provider for oracle version
            _provider.atVersion(_settleVersion);

        // Initiate
        _controller.incentivizer().sync(currentOracleVersion);
        UFixed18 accumulatedFee;

        // value a->b
        accumulatedFee = accumulatedFee.add(_accumulator.accumulate(_controller, _provider, _position, latestOracleVersion, settleOracleVersion));

        // position a->b
        accumulatedFee = accumulatedFee.add(_position.settle(_provider, _latestVersion, settleOracleVersion));

        // short-circuit from a->c if b == c
        if (settleOracleVersion.version != currentOracleVersion.version) {

            // value b->c
            accumulatedFee = accumulatedFee.add(_accumulator.accumulate(_controller, _provider, _position, settleOracleVersion, currentOracleVersion));

            // position b->c (every accumulator version needs a position stamp)
            _position.settle(_provider, settleOracleVersion.version, currentOracleVersion);
        }

        // settle collateral
        _controller.collateral().settleProduct(accumulatedFee);

        emit Settle(settleOracleVersion.version, currentOracleVersion.version);
    }

    /**
     * @notice Surfaces account settlement externally
     * @param account Account to settle
     */
    function settleAccount(address account) external nonReentrant notPausedProduct(IProduct(this)) {
        IOracleProvider.OracleVersion memory currentOracleVersion = settleInternal();
        settleAccountInternal(account, currentOracleVersion);
    }

    /**
     * @notice Core account settlement flywheel
     * @param account Account to settle
     * @dev
     *  a) last settle oracle version
     *  b) latest pre position oracle version
     *  c) current oracle version
     *
     *  Settles from a->b then from b->c if either interval is non-zero to account for a change
     *  in position quantity at (b).
     *
     *  Syncs each to instantaneously after the oracle update.
     */
    function settleAccountInternal(address account, IOracleProvider.OracleVersion memory currentOracleVersion) internal {
        (IProductProvider _provider, IController _controller) = (productProvider, controller());

        // Get latest oracle version
        if (latestVersion(account) == currentOracleVersion.version) return; // short circuit entirely if a == c

        // Get settle oracle version
        uint256 _settleVersion = _positions[account].pre.settleVersion(currentOracleVersion.version);
        IOracleProvider.OracleVersion memory settleOracleVersion = _settleVersion == currentOracleVersion.version ?
            currentOracleVersion : // if b == c, don't re-call provider for oracle version
            _provider.atVersion(_settleVersion);

        // initialize
        Fixed18 accumulated;

        // sync incentivizer before accumulator
        _controller.incentivizer().syncAccount(account, settleOracleVersion);

        // value a->b
        accumulated = accumulated.add(
            _accumulators[account].syncTo(_accumulator, _positions[account], settleOracleVersion.version).sum());

        // position a->b
        accumulated = accumulated.sub(Fixed18Lib.from(_positions[account].settle(_provider, settleOracleVersion)));

        // short-circuit if a->c
        if (settleOracleVersion.version != currentOracleVersion.version) {
            // sync incentivizer before accumulator
            _controller.incentivizer().syncAccount(account, currentOracleVersion);

            // value b->c
            accumulated = accumulated.add(
                _accumulators[account].syncTo(_accumulator, _positions[account], currentOracleVersion.version).sum());
        }

        // settle collateral
        _controller.collateral().settleAccount(account, accumulated);

        emit AccountSettle(account, settleOracleVersion.version, currentOracleVersion.version);
    }

    /**
     * @notice Opens a taker position for `msg.sender`
     * @param amount Amount of the position to open
     */
    function openTake(UFixed18 amount)
    external
    nonReentrant
    notPausedProduct(IProduct(this))
    settleForAccount(msg.sender)
    takerInvariant
    positionInvariant
    liquidationInvariant
    maintenanceInvariant
    {
        IOracleProvider.OracleVersion memory currentVersion = productProvider.currentVersion();

        _positions[msg.sender].pre.openTake(currentVersion.version, amount);
        _position.pre.openTake(currentVersion.version, amount);

        emit TakeOpened(msg.sender, amount);
    }

    /**
     * @notice Closes a taker position for `msg.sender`
     * @param amount Amount of the position to close
     */
    function closeTake(UFixed18 amount)
    external
    nonReentrant
    notPausedProduct(IProduct(this))
    settleForAccount(msg.sender)
    closeInvariant
    liquidationInvariant
    {
        closeTakeInternal(msg.sender, amount);
    }

    function closeTakeInternal(address account, UFixed18 amount) internal {
        IOracleProvider.OracleVersion memory currentVersion = productProvider.currentVersion();

        _positions[account].pre.closeTake(currentVersion.version, amount);
        _position.pre.closeTake(currentVersion.version, amount);

        emit TakeClosed(account, amount);
    }

    /**
     * @notice Opens a maker position for `msg.sender`
     * @param amount Amount of the position to open
     */
    function openMake(UFixed18 amount)
    external
    nonReentrant
    notPausedProduct(IProduct(this))
    settleForAccount(msg.sender)
    nonZeroVersionInvariant
    makerInvariant
    positionInvariant
    liquidationInvariant
    maintenanceInvariant
    {
        IOracleProvider.OracleVersion memory currentVersion = productProvider.currentVersion();

        _positions[msg.sender].pre.openMake(currentVersion.version, amount);
        _position.pre.openMake(currentVersion.version, amount);

        emit MakeOpened(msg.sender, amount);
    }

    /**
     * @notice Closes a maker position for `msg.sender`
     * @param amount Amount of the position to close
     */
    function closeMake(UFixed18 amount)
    external
    nonReentrant
    notPausedProduct(IProduct(this))
    settleForAccount(msg.sender)
    takerInvariant
    closeInvariant
    liquidationInvariant
    {
        closeMakeInternal(msg.sender, amount);
    }

    function closeMakeInternal(address account, UFixed18 amount) internal {
        IOracleProvider.OracleVersion memory currentVersion = productProvider.currentVersion();

        _positions[account].pre.closeMake(currentVersion.version, amount);
        _position.pre.closeMake(currentVersion.version, amount);

        emit MakeClosed(account, amount);
    }

    /**
     * @notice Closes all open and pending positions, locking for liquidation
     * @dev Only callable by the Collateral contract as part of the liquidation flow
     * @param account Account to close out
     */
    function closeAll(address account) external onlyCollateral settleForAccount(account) {
        AccountPosition storage accountPosition = _positions[account];
        Position memory p = accountPosition.position.next(_positions[account].pre);

        // Close all positions
        closeMakeInternal(account, p.maker);
        closeTakeInternal(account, p.taker);

        // Mark liquidation to lock position
        accountPosition.liquidation = true;
    }

    /**
     * @notice Returns the maintenance requirement for `account`
     * @param account Account to return for
     * @return The current maintenance requirement
     */
    function maintenance(address account) external view returns (UFixed18) {
        return _positions[account].maintenance(productProvider);
    }

    /**
     * @notice Returns the maintenance requirement for `account` after next settlement
     * @dev Assumes no price change and no funding, used to protect user from over-opening
     * @param account Account to return for
     * @return The next maintenance requirement
     */
    function maintenanceNext(address account) external view returns (UFixed18) {
        return _positions[account].maintenanceNext(productProvider);
    }

    /**
     * @notice Returns whether `account` has a completely zero'd position
     * @param account Account to return for
     * @return The the account is closed
     */
    function isClosed(address account) external view returns (bool) {
        return _positions[account].isClosed();
    }

    /**
     * @notice Returns whether `account` is currently locked for an in-progress liquidation
     * @param account Account to return for
     * @return Whether the account is in liquidation
     */
    function isLiquidating(address account) external view returns (bool) {
        return _positions[account].liquidation;
    }

    /**
     * @notice Returns `account`'s current position
     * @param account Account to return for
     * @return Current position of the account
     */
    function position(address account) external view returns (Position memory) {
        return _positions[account].position;
    }

    /**
     * @notice Returns `account`'s current pending-settlement position
     * @param account Account to return for
     * @return Current pre-position of the account
     */
    function pre(address account) external view returns (PrePosition memory) {
        return _positions[account].pre;
    }

    /**
     * @notice Returns the global latest settled oracle version
     * @return Latest settled oracle version of the product
     */
    function latestVersion() public view returns (uint256) {
        return _accumulator.latestVersion;
    }

    /**
     * @notice Returns the global position at oracleVersion `oracleVersion`
     * @dev Only valid for the version at which a global settlement occurred
     * @param oracleVersion Oracle version to return for
     * @return Global position at oracle version
     */
    function positionAtVersion(uint256 oracleVersion) public view returns (Position memory) {
        return _position.positionAtVersion(oracleVersion);
    }

    /**
     * @notice Returns the current global pending-settlement position
     * @return Global pending-settlement position
     */
    function pre() external view returns (PrePosition memory) {
        return _position.pre;
    }

    /**
     * @notice Returns the global accumulator value at oracleVersion `oracleVersion`
     * @dev Only valid for the version at which a global settlement occurred
     * @param oracleVersion Oracle version to return for
     * @return Global accumulator value at oracle version
     */
    function valueAtVersion(uint256 oracleVersion) external view returns (Accumulator memory) {
        return _accumulator.valueAtVersion(oracleVersion);
    }

    /**
     * @notice Returns the global accumulator share at oracleVersion `oracleVersion`
     * @dev Only valid for the version at which a global settlement occurred
     * @param oracleVersion Oracle version to return for
     * @return Global accumulator share at oracle version
     */
    function shareAtVersion(uint256 oracleVersion) external view returns (Accumulator memory) {
        return _accumulator.shareAtVersion(oracleVersion);
    }

    /**
     * @notice Returns `account`'s latest settled oracle version
     * @param account Account to return for
     * @return Latest settled oracle version of the account
     */
    function latestVersion(address account) public view returns (uint256) {
        return _accumulators[account].latestVersion;
    }

    /// @dev Limit total maker for guarded rollouts
    modifier makerInvariant {
        _;

        Position memory next = positionAtVersion(latestVersion()).next(_position.pre);

        if (next.maker.gt(productProvider.makerLimit())) revert ProductMakerOverLimitError();
    }

    /// @dev Limit maker short exposure to the range 0.0-1.0x of their position
    modifier takerInvariant {
        _;

        Position memory next = positionAtVersion(latestVersion()).next(_position.pre);
        UFixed18 socializationFactor = next.socializationFactor();

        if (socializationFactor.lt(UFixed18Lib.ONE)) revert ProductInsufficientLiquidityError(socializationFactor);
    }

    /// @dev Ensure that the user has only taken a maker or taker position, but not both
    modifier positionInvariant {
        _;

        if (_positions[msg.sender].isDoubleSided()) revert ProductDoubleSidedError();
    }

    /// @dev Ensure that the user hasn't closed more than is open
    modifier closeInvariant {
        _;

        if (_positions[msg.sender].isOverClosed()) revert ProductOverClosedError();
    }

    /// @dev Ensure that the user will have sufficient margin for maintenance after next settlement
    modifier maintenanceInvariant {
        _;

        if (controller().collateral().liquidatableNext(msg.sender, IProduct(this)))
            revert ProductInsufficientCollateralError();
    }

    /// @dev Ensure that the user is not currently being liquidated
    modifier liquidationInvariant {
        if (_positions[msg.sender].liquidation) revert ProductInLiquidationError();

        _;
    }

    /// @dev Helper to fully settle an account's state
    modifier settleForAccount(address account) {
        IOracleProvider.OracleVersion memory currentVersion = settleInternal();
        settleAccountInternal(account, currentVersion);

        _;
    }

    /// @dev Ensure we have bootstraped the oracle before creating positions
    modifier nonZeroVersionInvariant {
        if (latestVersion() == 0) revert ProductOracleBootstrappingError();

        _;
    }
}