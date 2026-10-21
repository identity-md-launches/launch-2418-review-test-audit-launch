// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Emits relay-4 commands; an external gateway delivers them to the physical board.
contract IMDPhysicalHook is IHooks, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    IPoolManager public constant poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address public immutable launchFactory;
    address public constant imdToken = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    bytes32 public constant deviceId = bytes32("imd-physical-room-1");
    uint8 public constant relay = 4;
    uint256 public constant commandTtlSeconds = 120;
    uint160 public constant HOOK_FLAGS = 0x2040;

    PoolKey public poolKey;
    bytes32 public poolId;
    bool public poolBound;
    bool public enabled;
    bool public buyState = true;
    bool public sellState;
    uint256 public minImdAmount = 0.05 ether;
    uint32 public cooldownSeconds = 10;
    uint256 public lastCommandId;
    uint256 public lastTriggerAt;

    error OnlyPoolManager();
    error OnlyLaunchFactory();
    error InvalidLaunchFactory();
    error PoolAlreadyBound();
    error InvalidPool();
    error PoolNotBound();
    error InvalidThreshold();
    error CallbackDisabled();

    event PoolBound(
        bytes32 indexed poolId, address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks
    );
    event RuleUpdated(bool buyState, bool sellState, uint256 minImdAmount, uint32 cooldownSeconds);
    event EnabledUpdated(bool enabled);
    event RelayTriggered(
        uint256 indexed commandId,
        bytes32 indexed deviceId,
        bytes32 indexed poolId,
        uint8 relay,
        bool desiredState,
        uint256 imdAmount,
        bool isBuy,
        uint256 expiresAt
    );

    constructor(address initialOwner, address initialFactory) Ownable(initialOwner) {
        if (initialFactory == address(0)) revert InvalidLaunchFactory();
        launchFactory = initialFactory;
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.afterSwap = true;
    }

    function bindPool(PoolKey calldata key) external onlyOwner {
        if (poolBound) revert PoolAlreadyBound();
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        if (a == address(0) || a >= b || address(key.hooks) != address(this) || (a == imdToken) == (b == imdToken)) {
            revert InvalidPool();
        }
        poolKey = key;
        poolId = PoolId.unwrap(PoolIdLibrary.toId(key));
        poolBound = true;
        emit PoolBound(poolId, a, b, key.fee, key.tickSpacing, address(key.hooks));
    }

    function rule() external view returns (uint8, bool, bool, uint256, uint32) {
        return (relay, buyState, sellState, minImdAmount, cooldownSeconds);
    }

    function setRule(bool buyState_, bool sellState_, uint256 minImdAmount_, uint32 cooldownSeconds_)
        external
        onlyOwner
    {
        if (minImdAmount_ == 0) revert InvalidThreshold();
        buyState = buyState_;
        sellState = sellState_;
        minImdAmount = minImdAmount_;
        cooldownSeconds = cooldownSeconds_;
        emit RuleUpdated(buyState_, sellState_, minImdAmount_, cooldownSeconds_);
    }

    function setEnabled(bool enabled_) external onlyOwner {
        if (enabled_ && !poolBound) revert PoolNotBound();
        enabled = enabled_;
        emit EnabledUpdated(enabled_);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (!enabled || !poolBound || PoolId.unwrap(PoolIdLibrary.toId(key)) != poolId) {
            return (IHooks.afterSwap.selector, 0);
        }

        bool imdIs0 = Currency.unwrap(key.currency0) == imdToken;
        int128 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
        int128 otherDelta = imdIs0 ? delta.amount1() : delta.amount0();
        bool isBuy = imdDelta < 0 && otherDelta > 0;
        if (!isBuy && !(imdDelta > 0 && otherDelta < 0)) return (IHooks.afterSwap.selector, 0);
        // Widen before negation, including int128.min.
        uint256 amount = uint256(imdDelta < 0 ? -int256(imdDelta) : int256(imdDelta));
        if (amount < minImdAmount || (lastCommandId != 0 && block.timestamp - lastTriggerAt < cooldownSeconds)) {
            return (IHooks.afterSwap.selector, 0);
        }
        lastTriggerAt = block.timestamp;
        emit RelayTriggered(
            ++lastCommandId,
            deviceId,
            poolId,
            relay,
            isBuy ? buyState : sellState,
            amount,
            isBuy,
            block.timestamp + commandTtlSeconds
        );
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (sender != launchFactory) revert OnlyLaunchFactory();
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert CallbackDisabled();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert CallbackDisabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackDisabled();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert CallbackDisabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackDisabled();
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert CallbackDisabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackDisabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackDisabled();
    }
}
