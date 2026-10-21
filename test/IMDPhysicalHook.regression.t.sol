// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {IMDPhysicalHook} from "src/IMDPhysicalHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract IMDPhysicalHookRegressionTest is HookTestBase {
    using PoolIdLibrary for PoolKey;

    bytes32 private constant RELAY_TOPIC =
        keccak256("RelayTriggered(uint256,bytes32,bytes32,uint8,bool,uint256,bool,uint256)");
    event PoolBound(
        bytes32 indexed poolId, address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks
    );
    event RuleUpdated(bool buyState, bool sellState, uint256 minImdAmount, uint32 cooldownSeconds);
    event EnabledUpdated(bool enabled);

    /// Unlike a memory alias of the valid key, this actually attempts a different poolId.
    function testMistypedInitializedKeyCannotConsumeCorrectBinding() public {
        PoolKey memory valid = _key(true);
        _initialize(valid);
        PoolKey memory wrong = _key(true);
        wrong.fee = 3000;
        assertTrue(PoolId.unwrap(valid.toId()) != PoolId.unwrap(wrong.toId()));
        vm.expectRevert(IMDPhysicalHook.PoolNotInitialized.selector);
        hook.bindPool(wrong);
        assertFalse(hook.poolBound());
        assertEq(hook.poolId(), bytes32(0));
        vm.expectEmit(true, false, false, true, address(hook));
        emit PoolBound(
            PoolId.unwrap(valid.toId()),
            Currency.unwrap(valid.currency0),
            Currency.unwrap(valid.currency1),
            valid.fee,
            valid.tickSpacing,
            address(hook)
        );
        hook.bindPool(valid);
        assertEq(hook.poolId(), PoolId.unwrap(valid.toId()));
        assertFalse(hook.enabled(), "binding must not also enable");
    }

    function testRuleAndEnabledEventsAndRejectedRuleAreAtomic() public {
        _enable(false);
        vm.expectEmit(false, false, false, true, address(hook));
        emit RuleUpdated(false, true, 7, type(uint32).max);
        hook.setRule(false, true, 7, type(uint32).max);
        vm.expectRevert(IMDPhysicalHook.InvalidThreshold.selector);
        hook.setRule(true, false, 0, 0);
        (, bool buy, bool sell, uint256 minimum, uint32 cooldown) = hook.rule();
        assertFalse(buy);
        assertTrue(sell);
        assertEq(minimum, 7);
        assertEq(cooldown, type(uint32).max);
        vm.expectEmit(false, false, false, true, address(hook));
        emit EnabledUpdated(false);
        hook.setEnabled(false);
    }

    function testPendingOwnerCannotAdministerAndReplacedNomineeCannotAccept() public {
        PoolKey memory key = _enable(true);
        _trigger(key, -1 ether, 1);
        address first = makeAddr("first nominee");
        address next = makeAddr("replacement nominee");
        hook.transferOwnership(first);
        _assertNoAdministration(first, key);
        hook.transferOwnership(next);
        vm.prank(first);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, first));
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
        assertEq(hook.pendingOwner(), address(0));
        _assertNoAdministration(address(this), key);
        vm.prank(next);
        hook.setEnabled(false);
        assertFalse(hook.enabled());
        assertEq(hook.lastCommandId(), 1);
        assertEq(hook.lastTriggerAt(), 1000);
        assertEq(hook.poolId(), PoolId.unwrap(key.toId()));
    }

    function testCancellingPendingTransferPreservesCurrentOwnerAndEmergencyDisable() public {
        PoolKey memory key = _enable(true);
        address next = makeAddr("cancelled nominee");
        hook.transferOwnership(next);
        hook.transferOwnership(address(0));
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        hook.acceptOwnership();
        assertEq(hook.owner(), address(this));
        assertEq(hook.pendingOwner(), address(0));
        hook.setEnabled(false);
        _trigger(key, -1 ether, 1);
        assertEq(hook.lastCommandId(), 0);
    }

    function testFactoryAndOriginNeverGainActivationRights() public {
        PoolKey memory key = _key(true);
        _initialize(key);
        _assertNoAdministration(FACTORY, key);
        address origin = makeAddr("launch origin");
        vm.prank(FACTORY, origin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, FACTORY));
        hook.bindPool(key);
        _assertNoAdministration(origin, key);
        assertFalse(hook.poolBound());
        assertFalse(hook.enabled());
    }

    function _assertNoAdministration(address caller, PoolKey memory key) private {
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(denied);
        hook.bindPool(key);
        vm.expectRevert(denied);
        hook.setEnabled(false);
        vm.expectRevert(denied);
        hook.setRule(false, true, 1, 0);
        vm.expectRevert(denied);
        hook.transferOwnership(caller);
        vm.expectRevert(denied);
        hook.renounceOwnership();
        vm.stopPrank();
    }

    function testEveryForeignPoolKeyFieldIsIgnored() public {
        PoolKey memory bound = _enable(true);
        for (uint256 field; field < 5; ++field) {
            PoolKey memory foreign = _key(true);
            if (field == 0) foreign.currency0 = Currency.wrap(address(uint160(IMD) - 1));
            if (field == 1) foreign.currency1 = Currency.wrap(address(uint160(Currency.unwrap(bound.currency1)) + 1));
            if (field == 2) foreign.fee = bound.fee + 1;
            if (field == 3) foreign.tickSpacing = bound.tickSpacing + 1;
            if (field == 4) foreign.hooks = IHooks(makeAddr("foreign hook"));
            assertTrue(PoolId.unwrap(foreign.toId()) != hook.poolId());
            vm.recordLogs();
            _trigger(foreign, -1 ether, 1);
            assertEq(vm.getRecordedLogs().length, 0);
            assertEq(hook.lastCommandId(), 0);
            assertEq(hook.lastTriggerAt(), 0);
        }
        _trigger(bound, -1 ether, 1);
        assertEq(hook.lastCommandId(), 1);
    }

    function testEveryDisabledCallbackRevertsEvenForManager() public {
        PoolKey memory key = _enable(true);
        IPoolManager.ModifyLiquidityParams memory liquidity = IPoolManager.ModifyLiquidityParams(-60, 60, 0, bytes32(0));
        IPoolManager.SwapParams memory swap = IPoolManager.SwapParams(true, -1, 1);
        bytes[8] memory calls = [
            abi.encodeCall(hook.afterInitialize, (FACTORY, key, uint160(1 << 96), int24(0))),
            abi.encodeCall(hook.beforeAddLiquidity, (FACTORY, key, liquidity, bytes(""))),
            abi.encodeCall(
                hook.afterAddLiquidity, (FACTORY, key, liquidity, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes(""))
            ),
            abi.encodeCall(hook.beforeRemoveLiquidity, (FACTORY, key, liquidity, bytes(""))),
            abi.encodeCall(
                hook.afterRemoveLiquidity,
                (FACTORY, key, liquidity, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes(""))
            ),
            abi.encodeCall(hook.beforeSwap, (FACTORY, key, swap, bytes(""))),
            abi.encodeCall(hook.beforeDonate, (FACTORY, key, 1, 1, bytes(""))),
            abi.encodeCall(hook.afterDonate, (FACTORY, key, 1, 1, bytes("")))
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(MANAGER);
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(IMDPhysicalHook.CallbackDisabled.selector));
        }
        assertEq(hook.lastCommandId(), 0);
    }

    function testMaxThresholdSuppressesCommandsWithoutBlockingCallbacks() public {
        PoolKey memory key = _enable(false);
        hook.setRule(true, false, type(uint256).max, 0);
        vm.recordLogs();
        _trigger(key, type(int128).min, type(int128).max);
        _trigger(key, type(int128).max, type(int128).min);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.lastCommandId(), 0);
        hook.setRule(true, false, 1, 0);
        _trigger(key, type(int128).min, 1);
        assertEq(hook.lastCommandId(), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSignedDeltaAndRawGatewayABI(
        int128 imdDelta,
        int128 otherDelta,
        bool imdFirst,
        bool buyState,
        bool sellState,
        uint128 thresholdSeed,
        int256 specified,
        bool direction,
        bytes calldata hookData
    ) public {
        PoolKey memory key = _enable(imdFirst);
        uint256 minimum = _bound(thresholdSeed, 1, uint256(1) << 127);
        hook.setRule(buyState, sellState, minimum, 0);
        BalanceDelta delta = imdFirst ? toBalanceDelta(imdDelta, otherDelta) : toBalanceDelta(otherDelta, imdDelta);
        // The independent oracle uses the product of the signed deltas; int128 * int128 fits int256.
        bool oppositeSigns = int256(imdDelta) * int256(otherDelta) < 0;
        uint256 magnitude = uint256(imdDelta < 0 ? -int256(imdDelta) : int256(imdDelta));
        bool expected = oppositeSigns && magnitude >= minimum;
        vm.recordLogs();
        vm.prank(MANAGER);
        (bytes4 selector, int128 adjustment) = hook.afterSwap(
            makeAddr("untrusted router"), key, IPoolManager.SwapParams(direction, specified, 0), delta, hookData
        );
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(adjustment, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, expected ? 1 : 0);
        assertEq(hook.lastCommandId(), expected ? 1 : 0);
        assertEq(hook.lastTriggerAt(), expected ? 1000 : 0);
        if (expected) {
            assertEq(logs[0].emitter, address(hook));
            assertEq(logs[0].topics.length, 4);
            assertEq(logs[0].topics[0], RELAY_TOPIC);
            assertEq(logs[0].topics[1], bytes32(uint256(1)));
            assertEq(logs[0].topics[2], DEVICE);
            assertEq(logs[0].topics[3], hook.poolId());
            assertEq(
                logs[0].data,
                abi.encode(uint8(4), imdDelta < 0 ? buyState : sellState, magnitude, imdDelta < 0, uint256(1120))
            );
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzChangedCooldownAppliesToLastEmission(uint32 cooldown, bool imdFirst) public {
        PoolKey memory key = _enable(imdFirst);
        _trigger(key, -1 ether, 1);
        hook.setEnabled(false);
        hook.setRule(false, true, MIN, cooldown);
        hook.setEnabled(true);
        assertEq(hook.lastTriggerAt(), 1000);
        if (cooldown > 0) {
            vm.warp(1000 + uint256(cooldown) - 1);
            vm.recordLogs();
            _trigger(key, 1 ether, -1);
            assertEq(vm.getRecordedLogs().length, 0);
            assertEq(hook.lastCommandId(), 1);
            assertEq(hook.lastTriggerAt(), 1000);
        }
        vm.warp(1000 + uint256(cooldown));
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(2, DEVICE, hook.poolId(), 4, true, 1 ether, false, 1120 + uint256(cooldown));
        _trigger(key, 1 ether, -1);
        assertEq(hook.lastCommandId(), 2);
    }
}
