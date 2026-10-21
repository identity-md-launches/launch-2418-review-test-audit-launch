// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./HookTestBase.sol";
import {IMDPhysicalHook} from "../src/IMDPhysicalHook.sol";
import {IMDirectorToken} from "../src/IMDirectorToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract IMDPhysicalHookTest is HookTestBase {
    using PoolIdLibrary for PoolKey;

    function testInitialConfigurationAndPermissions() public view {
        assertEq(hook.owner(), address(this));
        assertEq(hook.pendingOwner(), address(0));
        assertEq(hook.imdToken(), IMD);
        assertEq(address(hook.poolManager()), MANAGER);
        assertEq(hook.deviceId(), DEVICE);
        assertEq(hook.relay(), 4);
        assertEq(hook.commandTtlSeconds(), 120);
        assertEq(uint160(address(hook)) & 0x3fff, 0x40);
        Hooks.Permissions memory p;
        p.afterSwap = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(p));
        assertFalse(hook.enabled());
        assertFalse(hook.poolBound());
        assertEq(hook.poolId(), bytes32(0));
        assertEq(hook.lastCommandId(), 0);
        assertEq(hook.lastTriggerAt(), 0);
        (uint8 relay, bool buy, bool sell, uint256 minimum, uint32 cooldown) = hook.rule();
        assertEq(relay, 4);
        assertTrue(buy);
        assertFalse(sell);
        assertEq(minimum, MIN);
        assertEq(cooldown, 10);
    }

    function testRejectsIncorrectAddressFlags() public {
        assertTrue(uint160(vm.computeCreateAddress(address(this), vm.getNonce(address(this)))) & 0x3fff != 0x40);
        vm.expectRevert();
        new IMDPhysicalHook(address(this));
    }

    function testExplicitOwnerIsIndependentOfFactory() public {
        IMDPhysicalHook owned = _deploy(address(0xbeef));
        assertEq(owned.owner(), address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        owned.setRule(false, true, 1, 0);
    }

    function testRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new IMDPhysicalHook(address(0));
    }

    function testCannotEnableBeforeBinding() public {
        hook.setEnabled(false);
        vm.expectRevert(IMDPhysicalHook.PoolNotBound.selector);
        hook.setEnabled(true);
    }

    function testBindingIsOnceAndSavesExactKey() public {
        PoolKey memory key = _enable(true);
        assertEq(hook.poolId(), PoolId.unwrap(key.toId()));
        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks h) = hook.poolKey();
        assertEq(Currency.unwrap(c0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(c1), Currency.unwrap(key.currency1));
        assertEq(fee, 12500);
        assertEq(spacing, 60);
        assertEq(address(h), address(hook));
        vm.expectRevert(IMDPhysicalHook.PoolAlreadyBound.selector);
        hook.bindPool(key);
    }

    function testInvalidBindings() public {
        PoolKey memory key = _key(true);
        key.currency0 = Currency.wrap(address(0));
        _invalid(key);
        key = _key(true);
        key.currency1 = key.currency0;
        _invalid(key);
        key = _key(true);
        (key.currency0, key.currency1) = (key.currency1, key.currency0);
        _invalid(key);
        key = _key(true);
        key.hooks = IHooks(address(1));
        _invalid(key);
        key = _key(true);
        key.currency0 = Currency.wrap(address(1));
        _invalid(key);
        assertFalse(hook.poolBound());
    }

    function _invalid(PoolKey memory key) private {
        vm.expectRevert(IMDPhysicalHook.InvalidPool.selector);
        hook.bindPool(key);
    }

    function testOwnerOnlySettingsAndTwoStepTransfer() public {
        address other = address(0xbeef);
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other);
        PoolKey memory key = _key(true);
        vm.startPrank(other);
        vm.expectRevert(denied);
        hook.bindPool(key);
        vm.expectRevert(denied);
        hook.setEnabled(false);
        vm.expectRevert(denied);
        hook.setRule(false, true, 1, 0);
        vm.expectRevert(denied);
        hook.transferOwnership(other);
        vm.stopPrank();
        hook.transferOwnership(other);
        assertEq(hook.owner(), address(this));
        assertEq(hook.pendingOwner(), other);
        vm.prank(other);
        hook.acceptOwnership();
        assertEq(hook.owner(), other);
        assertEq(hook.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hook.bindPool(key);
        vm.prank(other);
        hook.bindPool(key);
    }

    function testRejectsSpoofedAfterSwap() public {
        PoolKey memory key = _enable(true);
        vm.expectRevert(IMDPhysicalHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, IPoolManager.SwapParams(true, -1, 1), BalanceDelta.wrap(0), "");
    }

    function testUnboundDisabledAndForeignPoolEmitNothing() public {
        PoolKey memory key = _key(true);
        vm.recordLogs();
        _trigger(key, -1 ether, 1 ether);
        assertEq(vm.getRecordedLogs().length, 0);
        assertFalse(hook.poolBound());
        hook.bindPool(key);
        vm.recordLogs();
        _trigger(key, -1 ether, 1 ether);
        assertEq(vm.getRecordedLogs().length, 0);
        hook.setEnabled(true);
        key.fee = 3000;
        vm.recordLogs();
        _trigger(key, -1 ether, 1 ether);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.lastCommandId(), 0);
    }

    function testBuyAndSellForBothCurrencyOrders() public {
        _buySell(true);
        hook = _deploy(address(this));
        _buySell(false);
    }

    function _buySell(bool imdIs0) private {
        PoolKey memory key = _enable(imdIs0);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(1, DEVICE, PoolId.unwrap(key.toId()), 4, true, 1 ether, true, vm.getBlockTimestamp() + 120);
        _trigger(key, -1 ether, 2 ether);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(
            2, DEVICE, PoolId.unwrap(key.toId()), 4, false, 2 ether, false, vm.getBlockTimestamp() + 120
        );
        _trigger(key, 2 ether, -3 ether);
        assertEq(hook.lastCommandId(), 2);
        assertEq(hook.lastTriggerAt(), vm.getBlockTimestamp());
    }

    function testThresholdBelowEqualAndAbove() public {
        PoolKey memory key = _enable(true);
        _trigger(key, -int128(int256(MIN - 1)), 1);
        assertEq(hook.lastCommandId(), 0);
        assertEq(hook.lastTriggerAt(), 0);
        _trigger(key, -int128(int256(MIN)), 1);
        assertEq(hook.lastCommandId(), 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        _trigger(key, int128(int256(MIN + 1)), -1);
        assertEq(hook.lastCommandId(), 2);
    }

    function testCooldownBoundaryAndSkippedEventsDoNotMoveTimer() public {
        PoolKey memory key = _enable(true);
        _trigger(key, -1 ether, 1 ether);
        _trigger(key, 1 ether, -1 ether);
        assertEq(hook.lastCommandId(), 1);
        vm.warp(1009);
        _trigger(key, 1 ether, -1 ether);
        assertEq(hook.lastCommandId(), 1);
        assertEq(hook.lastTriggerAt(), 1000);
        vm.warp(1010);
        _trigger(key, -1, 1);
        assertEq(hook.lastTriggerAt(), 1000);
        _trigger(key, 1 ether, -1 ether);
        assertEq(hook.lastCommandId(), 2);
        assertEq(hook.lastTriggerAt(), 1010);
    }

    function testRuleChangesAndEnableDoNotResetCooldown() public {
        PoolKey memory key = _enable(true);
        _trigger(key, -1 ether, 1 ether);
        vm.warp(1005);
        hook.setEnabled(false);
        _trigger(key, -1 ether, 1 ether);
        hook.setRule(false, true, 1, 10);
        hook.setEnabled(true);
        _trigger(key, -1 ether, 1 ether);
        assertEq(hook.lastCommandId(), 1);
        assertEq(hook.lastTriggerAt(), 1000);
        vm.warp(1010);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(2, DEVICE, hook.poolId(), 4, false, 1 ether, true, 1130);
        _trigger(key, -1 ether, 1 ether);
        hook.setRule(false, true, 1, 0);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(3, DEVICE, hook.poolId(), 4, true, 1 ether, false, 1130);
        _trigger(key, 1 ether, -1 ether);
    }

    function testZeroThresholdRejected() public {
        vm.expectRevert(IMDPhysicalHook.InvalidThreshold.selector);
        hook.setRule(true, false, 0, 10);
    }

    function testZeroAndSameSignDeltasAreIgnored() public {
        PoolKey memory key = _enable(true);
        vm.recordLogs();
        _trigger(key, 0, 1);
        _trigger(key, 1, 0);
        _trigger(key, 0, 0);
        _trigger(key, 1 ether, 1 ether);
        _trigger(key, -1 ether, -1 ether);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(hook.lastCommandId(), 0);
    }

    function testInt128MinimumIsWidenedBeforeNegation() public {
        PoolKey memory key = _enable(false);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(1, DEVICE, hook.poolId(), 4, true, uint256(1) << 127, true, 1120);
        _trigger(key, type(int128).min, 1);
    }

    function testFirstCommandAtTimestampZeroStillEnforcesCooldown() public {
        PoolKey memory key = _enable(true);
        vm.warp(0);
        _trigger(key, -1 ether, 1 ether);
        _trigger(key, -1 ether, 1 ether);
        assertEq(hook.lastCommandId(), 1);
        assertEq(hook.lastTriggerAt(), 0);
    }

    function testFuzzActualDeltaAndRelayArePreserved(uint128 amount, bool buy, bool imdIs0) public {
        amount = uint128(bound(amount, MIN, uint128(type(int128).max)));
        PoolKey memory key = _enable(imdIs0);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(1, DEVICE, hook.poolId(), 4, buy, amount, buy, 1120);
        _trigger(key, buy ? -int128(amount) : int128(amount), buy ? int128(1) : int128(-1));
    }

    function testTokenMetadataSupplyAndPlainTransfers() public {
        IMDirectorToken token = new IMDirectorToken();
        assertEq(token.name(), "IMDirector");
        assertEq(token.symbol(), "Director");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
        token.transfer(address(0xbeef), 1 ether);
        assertEq(token.balanceOf(address(0xbeef)), 1 ether);
        (bool canMint,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(canMint);
    }
}
