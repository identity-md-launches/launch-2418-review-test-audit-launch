// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {IMDPhysicalHook} from "src/IMDPhysicalHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @dev Stateful specification oracle. Authorization, activation, rules, command count and clock
/// are tracked independently; expected values are never copied from the hook after an action.
contract RelaySequenceHandler is Test {
    IMDPhysicalHook public immutable hook;
    address private immutable controller = msg.sender;
    PoolKey private key;
    address[3] public actors;
    address public expectedOwner;
    address public expectedPending;
    bool public expectedBound;
    bool public expectedEnabled;
    bool public expectedBuy = true;
    bool public expectedSell;
    uint256 public expectedMinimum = 0.05 ether;
    uint32 public expectedCooldown = 10;
    uint256 public expectedCount;
    uint256 public expectedLast;

    constructor(IMDPhysicalHook hook_, PoolKey memory key_) {
        hook = hook_;
        key = key_;
        actors = [address(this), makeAddr("relay administrator A"), makeAddr("relay administrator B")];
        expectedOwner = address(this);
    }

    function acceptInitialOwnership() external {
        require(msg.sender == controller);
        hook.acceptOwnership();
    }

    function bind(uint8 callerSeed, bool correct) external {
        address caller = actors[callerSeed % 3];
        PoolKey memory candidate = key;
        if (!correct) candidate.fee = 3000;
        vm.prank(caller);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.bindPool, (candidate)));
        bool expected = caller == expectedOwner && !expectedBound && correct;
        assertEq(ok, expected, "binding authorization or initialization changed");
        if (expected) expectedBound = true;
    }

    function enable(uint8 callerSeed, bool value) external {
        address caller = actors[callerSeed % 3];
        vm.prank(caller);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.setEnabled, (value)));
        bool expected = caller == expectedOwner && (!value || expectedBound);
        assertEq(ok, expected, "enable bypassed the owner/binding protocol");
        if (expected) expectedEnabled = value;
    }

    function changeRule(uint8 callerSeed, bool buy, bool sell, uint64 threshold, uint8 cooldown) external {
        address caller = actors[callerSeed % 3];
        uint256 minimum = _bound(threshold, 0, 2 ether);
        uint32 seconds_ = uint32(_bound(cooldown, 0, 20));
        vm.prank(caller);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.setRule, (buy, sell, minimum, seconds_)));
        bool expected = caller == expectedOwner && minimum > 0;
        assertEq(ok, expected, "rule update admitted an unauthorized caller or zero threshold");
        if (expected) {
            expectedBuy = buy;
            expectedSell = sell;
            expectedMinimum = minimum;
            expectedCooldown = seconds_;
        }
    }

    function nominate(uint8 callerSeed, uint8 nomineeSeed) external {
        address caller = actors[callerSeed % 3];
        address nominee = nomineeSeed % 4 == 3 ? address(0) : actors[nomineeSeed % 3];
        vm.prank(caller);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.transferOwnership, (nominee)));
        assertEq(ok, caller == expectedOwner);
        if (ok) expectedPending = nominee;
    }

    function accept(uint8 callerSeed) external {
        address caller = actors[callerSeed % 3];
        vm.prank(caller);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.acceptOwnership, ()));
        assertEq(ok, caller == expectedPending, "ownership moved without the pending owner's acceptance");
        if (ok) {
            expectedOwner = expectedPending;
            expectedPending = address(0);
        }
    }

    function renounce(uint8 callerSeed) external {
        vm.prank(actors[callerSeed % 3]);
        (bool ok,) = address(hook).call(abi.encodeCall(hook.renounceOwnership, ()));
        assertFalse(ok, "renunciation stranded an enabled device");
    }

    function elapse(uint8 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + _bound(seconds_, 0, 21));
    }

    function initializeCallback(bool validCaller, bool validFactory) external {
        address manager = address(hook.poolManager());
        address factory = hook.launchFactory();
        address sender = validFactory ? factory : address(this);
        vm.prank(validCaller ? manager : address(this));
        (bool ok, bytes memory result) =
            address(hook).call(abi.encodeCall(hook.beforeInitialize, (sender, key, uint160(1 << 96))));
        assertEq(ok, validCaller && validFactory);
        if (ok) assertEq(abi.decode(result, (bytes4)), IHooks.beforeInitialize.selector);
        // Invariants below ensure even successful initialization never binds, enables or resets rules.
    }

    function swap(uint8 kind, uint64 amountSeed, bool foreign, bool spoof, int256 amountSpecified) external {
        int128 amount = int128(int256(_bound(amountSeed, 0, 2 ether)));
        int128 imdDelta;
        int128 otherDelta;
        uint8 variant = kind % 6;
        if (variant == 0) {
            imdDelta = -amount;
            otherDelta = 1;
        }
        if (variant == 1) {
            imdDelta = amount;
            otherDelta = -1;
        }
        if (variant == 2) {
            imdDelta = amount;
            otherDelta = 1;
        }
        if (variant == 3) {
            imdDelta = -amount;
            otherDelta = -1;
        }
        if (variant == 4) {
            imdDelta = amount;
            otherDelta = 0;
        }
        if (variant == 5) {
            imdDelta = type(int128).min;
            otherDelta = 1;
        }
        PoolKey memory used = key;
        if (foreign) used.fee = 3000;
        bool first = Currency.unwrap(key.currency0) == hook.imdToken();
        BalanceDelta delta = first ? toBalanceDelta(imdDelta, otherDelta) : toBalanceDelta(otherDelta, imdDelta);
        address manager = address(hook.poolManager());
        vm.recordLogs();
        vm.prank(spoof ? address(this) : manager);
        (bool ok, bytes memory result) = address(hook)
            .call(
                abi.encodeCall(
                    hook.afterSwap,
                    (actors[1], used, IPoolManager.SwapParams(true, amountSpecified, 0), delta, hex"badc0de0")
                )
            );
        assertEq(ok, !spoof, "a swap was blocked or a fabricated callback was accepted");
        if (ok) {
            (bytes4 selector, int128 adjustment) = abi.decode(result, (bytes4, int128));
            assertEq(selector, IHooks.afterSwap.selector);
            assertEq(adjustment, 0);
        }
        uint256 magnitude = uint256(imdDelta < 0 ? -int256(imdDelta) : int256(imdDelta));
        bool shouldEmit = !spoof && !foreign && expectedBound && expectedEnabled
            && int256(imdDelta) * int256(otherDelta) < 0 && magnitude >= expectedMinimum
            && (expectedCount == 0 || vm.getBlockTimestamp() >= expectedLast + expectedCooldown);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, shouldEmit ? 1 : 0, "wrong number of gateway commands");
        if (shouldEmit) {
            ++expectedCount;
            expectedLast = vm.getBlockTimestamp();
            assertEq(logs[0].emitter, address(hook));
            assertEq(logs[0].topics.length, 4);
            assertEq(
                logs[0].topics[0], keccak256("RelayTriggered(uint256,bytes32,bytes32,uint8,bool,uint256,bool,uint256)")
            );
            assertEq(logs[0].topics[1], bytes32(expectedCount));
            assertEq(logs[0].topics[2], bytes32("imd-physical-room-1"));
            assertEq(logs[0].topics[3], PoolId.unwrap(PoolIdLibrary.toId(key)));
            assertEq(
                logs[0].data,
                abi.encode(
                    uint8(4), imdDelta < 0 ? expectedBuy : expectedSell, magnitude, imdDelta < 0, expectedLast + 120
                )
            );
        }
    }
}

abstract contract RelaySequenceInvariantBase is HookTestBase {
    RelaySequenceHandler private handler;
    PoolKey private expectedKey;

    function imdFirst() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        expectedKey = _key(imdFirst());
        _initialize(expectedKey);
        handler = RelaySequenceHandler(
            deployCode("IMDPhysicalHook.invariant.t.sol:RelaySequenceHandler", abi.encode(hook, expectedKey))
        );
        hook.transferOwnership(address(handler));
        handler.acceptInitialOwnership();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.bind.selector;
        selectors[1] = handler.enable.selector;
        selectors[2] = handler.changeRule.selector;
        selectors[3] = handler.nominate.selector;
        selectors[4] = handler.accept.selector;
        selectors[5] = handler.renounce.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.initializeCallback.selector;
        selectors[8] = handler.swap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ownerActivationAndRelayHistoryMatchTheSequence() public view {
        assertEq(hook.owner(), handler.expectedOwner());
        assertTrue(hook.owner() != address(0));
        assertEq(hook.pendingOwner(), handler.expectedPending());
        assertEq(hook.poolBound(), handler.expectedBound());
        assertEq(hook.enabled(), handler.expectedEnabled());
        assertFalse(hook.enabled() && !hook.poolBound());
        assertEq(hook.poolId(), handler.expectedBound() ? PoolId.unwrap(PoolIdLibrary.toId(expectedKey)) : bytes32(0));
        assertEq(hook.lastCommandId(), handler.expectedCount());
        assertEq(hook.lastTriggerAt(), handler.expectedLast());
        assertEq(hook.buyState(), handler.expectedBuy());
        assertEq(hook.sellState(), handler.expectedSell());
        assertEq(hook.minImdAmount(), handler.expectedMinimum());
        assertEq(hook.cooldownSeconds(), handler.expectedCooldown());
        assertEq(hook.relay(), 4);
        assertEq(hook.deviceId(), DEVICE);
        assertEq(hook.imdToken(), IMD);
        assertEq(hook.commandTtlSeconds(), 120);
        assertEq(hook.launchFactory(), FACTORY);
        assertEq(address(hook.poolManager()), MANAGER);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RelaySequenceImdFirstInvariantTest is RelaySequenceInvariantBase {
    function imdFirst() internal pure override returns (bool) {
        return true;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract RelaySequenceImdSecondInvariantTest is RelaySequenceInvariantBase {
    function imdFirst() internal pure override returns (bool) {
        return false;
    }
}
