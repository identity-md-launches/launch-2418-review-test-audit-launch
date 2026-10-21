// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPhysicalHook} from "src/IMDPhysicalHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// The launch factory deploys the hook and initializes its pool in one transaction. Both the hook
/// address (CREATE2, mined) and the token address are predictable, so the pool can be initialized
/// by anyone before the hook has code unless the hook declares an initialization callback.
contract InitFrontRunTest is Test {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ATTACKER = address(0xBAD);

    function _flags() internal returns (uint160 flags) {
        // This pure permission probe does not read the immutable launchFactory.
        address probe = address(0x1234);
        vm.etch(probe, vm.getDeployedCode("IMDPhysicalHook.sol:IMDPhysicalHook"));
        Hooks.Permissions memory p = IMDPhysicalHook(probe).getHookPermissions();
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) flags |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) flags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) flags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }

    function test_launchHookDeclaresAnInitializationCallback() public {
        vm.etch(address(0x1234), vm.getDeployedCode("IMDPhysicalHook.sol:IMDPhysicalHook"));
        Hooks.Permissions memory p = IMDPhysicalHook(address(0x1234)).getHookPermissions();
        assertTrue(p.beforeInitialize || p.afterInitialize, "launch hooks require an initialization callback");
    }

    function test_predictedLaunchPoolCannotBeInitializedBeforeHookExists() public {
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), MANAGER);
        uint160 flags = _flags();
        // The address the factory will deploy the hook to: carries the declared flags, has no code yet.
        address predictedHook =
            address((uint160(uint256(keccak256("predicted hook"))) & ~uint160(Hooks.ALL_HOOK_MASK)) | flags);
        // The launch token address the factory will deploy (predictable from the factory nonce/salt).
        address predictedToken = address(0x9000000000000000000000000000000000000000);
        assertEq(predictedHook.code.length, 0);
        PoolKey memory launchKey = PoolKey({
            currency0: Currency.wrap(IMD),
            currency1: Currency.wrap(predictedToken),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(predictedHook)
        });

        vm.prank(ATTACKER);
        (bool frontRun,) =
            MANAGER.call(abi.encodeCall(IPoolManager.initialize, (launchKey, uint160(1 << 96) / 1000)));
        assertFalse(frontRun, "anyone initialized the launch pool before the hook was deployed");
    }
}
