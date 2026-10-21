// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./HookTestBase.sol";
import {IMDirectorToken} from "src/IMDirectorToken.sol";
import {IMDPhysicalHook} from "src/IMDPhysicalHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

contract AccountingPairToken is ERC20 {
    constructor() ERC20("Offline IMD accounting fixture", "IMD") {
        _mint(msg.sender, 1e27);
    }
}

contract IMDPhysicalHookAccountingTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    PoolKey private key;
    PoolKey private control;
    PoolSwapTest private swaps;
    PoolModifyLiquidityTest private liquidity;
    address private director;
    bool private first;

    function _constructAt(bytes memory code, address at) private {
        vm.etch(at, code);
        (bool ok, bytes memory runtime) = at.call("");
        assertTrue(ok);
        vm.etch(at, runtime);
    }

    function _pool(bool imdFirst, bool withControl) private {
        first = imdFirst;
        director = imdFirst ? address(0x9000000000000000000000000000000000000000) : address(0x1000);
        _constructAt(vm.getCode("IMDPhysicalHook.accounting.t.sol:AccountingPairToken"), IMD);
        _constructAt(vm.getCode("IMDirectorToken.sol:IMDirectorToken"), director);
        swaps = PoolSwapTest(deployCode("PoolSwapTest.sol:PoolSwapTest", abi.encode(IPoolManager(MANAGER))));
        liquidity = PoolModifyLiquidityTest(
            deployCode("PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest", abi.encode(IPoolManager(MANAGER)))
        );
        ERC20(IMD).approve(address(swaps), type(uint256).max);
        ERC20(director).approve(address(swaps), type(uint256).max);
        ERC20(IMD).approve(address(liquidity), type(uint256).max);
        ERC20(director).approve(address(liquidity), type(uint256).max);
        key = _key(imdFirst);
        _initialize(key);
        liquidity.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), "");
        if (withControl) {
            control = _key(imdFirst);
            control.hooks = IHooks(address(0));
            IPoolManager(MANAGER).initialize(control, uint160(1 << 96));
            liquidity.modifyLiquidity(
                control, IPoolManager.ModifyLiquidityParams(-600, 600, 1000 ether, bytes32(0)), ""
            );
        }
        hook.bindPool(key);
        hook.setEnabled(true);
    }

    function _swap(PoolKey memory pool, bool buy, int256 amount, uint160 limit) private returns (BalanceDelta) {
        bool zeroForOne = buy == first;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return swaps.swap(
            pool, IPoolManager.SwapParams(zeroForOne, amount, limit), PoolSwapTest.TestSettings(false, false), hex"ff00"
        );
    }

    function _noRelay() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(hook));
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzHookIsAccountingEquivalentToPoolWithoutHook(
        bool imdFirst,
        bool buy,
        bool exactOutput,
        uint96 amountSeed
    ) public {
        _pool(imdFirst, true);
        uint256 amount = _bound(amountSeed, 1, 5 ether);
        int256 specified = exactOutput ? int256(amount) : -int256(amount);
        BalanceDelta actual = _swap(key, buy, specified, 0);
        BalanceDelta expected = _swap(control, buy, specified, 0);
        assertEq(BalanceDelta.unwrap(actual), BalanceDelta.unwrap(expected), "hook changed trader accounting");
        IPoolManager manager = IPoolManager(MANAGER);
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint160 controlPrice, int24 controlTick, uint24 controlProtocol, uint24 controlFee) =
            manager.getSlot0(control.toId());
        assertEq(price, controlPrice);
        assertEq(tick, controlTick);
        assertEq(protocolFee, controlProtocol);
        assertEq(lpFee, 12500);
        assertEq(lpFee, controlFee);
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(key.toId());
        (uint256 control0, uint256 control1) = manager.getFeeGrowthGlobals(control.toId());
        assertEq(fee0, control0);
        assertEq(fee1, control1);
        assertEq(manager.getLiquidity(key.toId()), manager.getLiquidity(control.toId()));
        assertEq(ERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(ERC20(director).balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function testPriceLimitedBuyBelowThresholdDoesNotEmitInEitherOrder() public {
        _partial(false, true, false);
    }

    function testPriceLimitedBuyImdFirstDoesNotEmit() public {
        _partial(true, true, false);
    }

    function testPriceLimitedSellBelowThresholdDoesNotEmit() public {
        _partial(false, false, false);
    }

    function testPriceLimitedSellImdFirstDoesNotEmit() public {
        _partial(true, false, false);
    }

    function testPriceLimitedExactOutputUsesActualImd() public {
        _partial(false, true, true);
    }

    function testPriceLimitedExactOutputImdFirstUsesActualImd() public {
        _partial(true, true, true);
    }

    function _partial(bool imdFirst, bool buy, bool exactOutput) private {
        _pool(imdFirst, false);
        hook.setRule(true, false, 1 ether, 0);
        bool zeroForOne = buy == imdFirst;
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-1) : int24(1));
        vm.recordLogs();
        BalanceDelta delta = _swap(key, buy, exactOutput ? int256(100 ether) : -int256(100 ether), limit);
        _noRelay();
        int256 actualImd = first ? delta.amount0() : delta.amount1();
        uint256 magnitude = uint256(actualImd < 0 ? -actualImd : actualImd);
        assertGt(magnitude, 0, "the partial swap did not execute");
        assertLt(magnitude, 1 ether, "fixture did not limit the actual IMD amount");
        assertEq(hook.lastCommandId(), 0);
        assertEq(hook.lastTriggerAt(), 0);
        (uint160 price,,,) = IPoolManager(MANAGER).getSlot0(key.toId());
        assertEq(price, limit);
    }

    function testRevertedSettlementRollsBackPriceCommandAndTimestamp() public {
        _pool(true, false);
        _swap(key, true, -1 ether, 0);
        assertEq(hook.lastCommandId(), 1);
        uint256 last = hook.lastTriggerAt();
        (uint160 price, int24 tick,,) = IPoolManager(MANAGER).getSlot0(key.toId());
        uint256 imdBalance = ERC20(IMD).balanceOf(address(this));
        uint256 directorBalance = ERC20(director).balanceOf(address(this));
        vm.warp(vm.getBlockTimestamp() + 10);
        ERC20(IMD).approve(address(swaps), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(swaps), 0, 1 ether)
        );
        _swap(key, true, -1 ether, 0);
        assertEq(hook.lastCommandId(), 1);
        assertEq(hook.lastTriggerAt(), last);
        (uint160 priceAfter, int24 tickAfter,,) = IPoolManager(MANAGER).getSlot0(key.toId());
        assertEq(priceAfter, price);
        assertEq(tickAfter, tick);
        assertEq(ERC20(IMD).balanceOf(address(this)), imdBalance);
        assertEq(ERC20(director).balanceOf(address(this)), directorBalance);
        ERC20(IMD).approve(address(swaps), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(hook));
        emit RelayTriggered(2, DEVICE, hook.poolId(), 4, true, 1 ether, true, vm.getBlockTimestamp() + 120);
        _swap(key, true, -1 ether, 0);
        assertEq(hook.lastCommandId(), 2);
    }

    function testDisableAndRuleChangesCannotTrapLiquidityOrLPFees() public {
        _pool(false, false);
        _swap(key, true, -1 ether, 0);
        hook.setEnabled(false);
        hook.setRule(false, true, type(uint256).max, type(uint32).max);
        vm.recordLogs();
        BalanceDelta fees =
            liquidity.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, 0, bytes32(0)), "");
        _noRelay();
        assertTrue(fees.amount0() > 0 || fees.amount1() > 0);
        vm.recordLogs();
        BalanceDelta withdrawal =
            liquidity.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-600, 600, -1000 ether, bytes32(0)), "");
        _noRelay();
        assertGt(withdrawal.amount0(), 0);
        assertGt(withdrawal.amount1(), 0);
        assertEq(IPoolManager(MANAGER).getLiquidity(key.toId()), 0);
        assertEq(hook.lastCommandId(), 1);
    }
}
