// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

contract TestCoin is ERC20 {
    constructor() ERC20("Integration coin", "TEST") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev Upstream PoolManager construction is executed at the canonical address, preserving
///      its NoDelegateCall immutable. No callback or permission validation is overridden.
contract IMDPhysicalHookIntegrationTest is HookTestBase {
    using PoolIdLibrary for PoolKey;

    PoolKey private key;
    PoolSwapTest private swaps;
    PoolModifyLiquidityTest private liquidity;
    bool private imdIs0;
    bytes32 private constant RELAY_TOPIC =
        keccak256("RelayTriggered(uint256,bytes32,bytes32,uint8,bool,uint256,bool,uint256)");

    function _pool(bool imdFirst) private {
        imdIs0 = imdFirst;
        bool canonicalFork = vm.envOr("IMDIRECTOR_CANONICAL_FORK", false);
        if (canonicalFork) {
            assertEq(block.chainid, 4663);
            assertGt(MANAGER.code.length, 0);
            deal(IMD, address(this), 1_000_000 ether);
        } else {
            deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), MANAGER);
            deployCodeTo("IMDPhysicalHook.integration.t.sol:TestCoin", IMD);
        }
        address other = imdFirst ? address(0x9000000000000000000000000000000000000000) : address(0x1000);
        deployCodeTo("IMDPhysicalHook.integration.t.sol:TestCoin", other);
        swaps = new PoolSwapTest(IPoolManager(MANAGER));
        liquidity = new PoolModifyLiquidityTest(IPoolManager(MANAGER));
        ERC20(IMD).approve(address(swaps), type(uint256).max);
        ERC20(other).approve(address(swaps), type(uint256).max);
        ERC20(IMD).approve(address(liquidity), type(uint256).max);
        ERC20(other).approve(address(liquidity), type(uint256).max);
        key = _key(imdFirst);
        // Factory-sender initialization and seeding succeed with afterSwap-only permissions.
        vm.prank(0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645);
        IPoolManager(MANAGER).initialize(key, uint160(1 << 96));
        liquidity.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), "");
    }

    function _swap(bool buy, int256 amount) private returns (BalanceDelta delta) {
        bool zeroForOne = buy == imdIs0;
        return swaps.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, amount, zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _assertEvent(BalanceDelta delta, bool buy, uint256 id) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != RELAY_TOPIC) continue;
            ++found;
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[2], DEVICE);
            assertEq(logs[i].topics[3], PoolId.unwrap(key.toId()));
            (uint8 relay, bool state, uint256 amount, bool isBuy, uint256 expiry) =
                abi.decode(logs[i].data, (uint8, bool, uint256, bool, uint256));
            int256 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
            assertEq(relay, 4);
            assertEq(state, buy);
            assertEq(isBuy, buy);
            assertEq(amount, uint256(imdDelta < 0 ? -imdDelta : imdDelta));
            assertEq(expiry, vm.getBlockTimestamp() + 120);
        }
        assertEq(found, 1);
    }

    function _assertNoRelay() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(hook));
        }
    }

    function testRealBuySellBothCurrencyOrders() public {
        _realBuySell(true);
    }

    function testRealBuySellImdAsCurrency1() public {
        _realBuySell(false);
    }

    function _realBuySell(bool imdFirst) private {
        _pool(imdFirst);
        hook.bindPool(key);
        hook.setEnabled(true);
        vm.recordLogs();
        BalanceDelta bought = _swap(true, -1 ether);
        _assertEvent(bought, true, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.recordLogs();
        BalanceDelta sold = _swap(false, -1 ether);
        _assertEvent(sold, false, 2);
        assertEq(hook.lastCommandId(), 2);
        assertEq(ERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(
            ERC20(imdFirst ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0)).balanceOf(address(hook)),
            0
        );
    }

    function testRealExactOutputUsesActualImdDelta() public {
        _exactOutput(true);
    }

    function testRealExactOutputWithImdAsCurrency1() public {
        _exactOutput(false);
    }

    function _exactOutput(bool imdFirst) private {
        _pool(imdFirst);
        hook.bindPool(key);
        hook.setEnabled(true);
        vm.recordLogs();
        BalanceDelta bought = _swap(true, 1 ether);
        _assertEvent(bought, true, 1);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.recordLogs();
        BalanceDelta sold = _swap(false, 1 ether);
        _assertEvent(sold, false, 2);
    }

    function testUnboundDisabledThresholdAndCooldownDoNotRevertSwap() public {
        _pool(true);
        vm.recordLogs();
        _swap(true, -1 ether);
        _assertNoRelay();
        assertFalse(hook.poolBound());
        hook.bindPool(key);
        vm.recordLogs();
        _swap(true, -1 ether);
        _assertNoRelay();
        hook.setEnabled(true);
        vm.recordLogs();
        _swap(true, -0.01 ether);
        _assertNoRelay();
        _swap(true, -1 ether);
        vm.recordLogs();
        _swap(false, -1 ether);
        _assertNoRelay();
        assertEq(hook.lastCommandId(), 1);
        hook.setEnabled(false);
        vm.warp(vm.getBlockTimestamp() + 10);
        vm.recordLogs();
        _swap(false, -1 ether);
        _assertNoRelay();
        assertEq(hook.lastCommandId(), 1);
    }

    function testPublicForeignInitializeCannotCaptureBinding() public {
        _pool(true);
        PoolKey memory foreign = key;
        foreign.fee = 3000;
        vm.prank(address(0xbeef));
        IPoolManager(MANAGER).initialize(foreign, uint160(1 << 96));
        liquidity.modifyLiquidity(foreign, IPoolManager.ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), "");
        assertFalse(hook.poolBound());
        hook.bindPool(key);
        hook.setEnabled(true);
        vm.recordLogs();
        swaps.swap(
            foreign,
            IPoolManager.SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        _assertNoRelay();
        assertEq(hook.lastCommandId(), 0);
        vm.recordLogs();
        BalanceDelta bought = _swap(true, -1 ether);
        _assertEvent(bought, true, 1);
    }

    function testWholeTransactionRevertRollsBackCommand() public {
        _pool(true);
        hook.bindPool(key);
        hook.setEnabled(true);
        vm.expectRevert(bytes("revert after real swap"));
        this.swapThenRevert();
        assertEq(hook.lastCommandId(), 0);
        assertEq(hook.lastTriggerAt(), 0);
        vm.recordLogs();
        BalanceDelta bought = _swap(true, -1 ether);
        _assertEvent(bought, true, 1);
    }

    function swapThenRevert() external {
        require(msg.sender == address(this));
        _swap(true, -1 ether);
        revert("revert after real swap");
    }

    function testRealPoolFeeCollectionIsNotBlockedByHook() public {
        _pool(true);
        hook.bindPool(key);
        hook.setEnabled(true);
        _swap(true, -1 ether);
        vm.recordLogs();
        BalanceDelta fees =
            liquidity.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 0, bytes32(0)), "");
        _assertNoRelay();
        assertTrue(fees.amount0() > 0 || fees.amount1() > 0);
        assertEq(hook.lastCommandId(), 1);
    }
}
