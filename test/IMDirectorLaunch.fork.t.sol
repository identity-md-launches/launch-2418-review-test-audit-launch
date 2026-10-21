// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDirectorToken} from "../src/IMDirectorToken.sol";
import {IMDPhysicalHook} from "../src/IMDPhysicalHook.sol";
import {IImdLaunchFactory, IImdRegistry} from "./support/IMDLaunchTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/// @dev Local fork only. Uses the real factory, manager and IMD code without mocks or etching.
///      Launch ABI and a historical call fixture come from IMD's published launch-2255 example.
contract IMDirectorLaunchForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant FACTORY = 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645;
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant OWNER = 0x755aEE18B71697b9c6dab6d3F0F05c63B58CAA92;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint160 constant FLAGS = 0x2040;
    IImdLaunchFactory constant factory = IImdLaunchFactory(FACTORY);

    function testRealFactoryLaunchTokenBelowImd() public { _rehearse(true); }
    function testRealFactoryLaunchTokenAboveImd() public { _rehearse(false); }

    function _rehearse(bool tokenBelow) private {
        string memory rpc = vm.envOr("RH_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);
        IImdLaunchFactory.LaunchParams memory p = _params(tokenBelow);
        uint256 beforeGas = gasleft();
        vm.prank(factory.deployer());
        (address token, address hookAddress, address distributor) = factory.launch(p);
        assertLt(beforeGas - gasleft(), 16_777_216);
        assertEq(token < IMD, tokenBelow);
        assertEq(IMDirectorToken(token).name(), "IMDirector");
        assertEq(IMDirectorToken(token).symbol(), "Director");
        assertEq(IMDirectorToken(token).decimals(), 18);
        assertEq(IERC20(token).totalSupply(), SUPPLY);
        assertEq(IERC20(token).balanceOf(distributor), SUPPLY / 10);
        assertGe(IERC20(token).balanceOf(OWNER), SUPPLY / 10);
        assertLe(IERC20(token).balanceOf(OWNER), SUPPLY * 101 / 1000);
        assertEq(IERC20(token).balanceOf(OWNER) + IERC20(token).balanceOf(MANAGER)
            + IERC20(token).balanceOf(distributor), SUPPLY);
        assertTrue(IImdRegistry(factory.registry()).isRecorded(p.launchNumber));

        IMDPhysicalHook hook = IMDPhysicalHook(hookAddress);
        assertEq(hook.owner(), OWNER);
        assertEq(hook.launchFactory(), FACTORY);
        assertEq(address(hook.poolManager()), MANAGER);
        assertEq(uint160(hookAddress) & 0x3fff, FLAGS);
        assertFalse(hook.poolBound());
        assertFalse(hook.enabled());
        PoolKey memory key = PoolKey(Currency.wrap(tokenBelow ? token : IMD),
            Currency.wrap(tokenBelow ? IMD : token), 12500, 60, IHooks(hookAddress));
        vm.prank(OWNER);
        hook.bindPool(key);
        assertEq(hook.poolId(), PoolId.unwrap(key.toId()));
        vm.prank(OWNER);
        hook.setEnabled(true);

        PoolSwapTest swaps = new PoolSwapTest(IPoolManager(MANAGER));
        deal(IMD, address(this), 10 ether);
        IERC20(IMD).approve(address(swaps), type(uint256).max);
        IERC20(token).approve(address(swaps), type(uint256).max);
        bool buyZeroForOne = !tokenBelow;
        swaps.swap(key, IPoolManager.SwapParams(buyZeroForOne, -1 ether,
            buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.lastCommandId(), 1);
        assertGt(IERC20(token).balanceOf(address(this)), 0);
        vm.warp(vm.getBlockTimestamp() + 10);
        swaps.swap(key, IPoolManager.SwapParams(!buyZeroForOne,
            -int256(IERC20(token).balanceOf(address(this))),
            buyZeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false), "");
        assertEq(hook.lastCommandId(), 2);
        assertEq(IERC20(token).balanceOf(hookAddress), 0);
        assertEq(IERC20(IMD).balanceOf(hookAddress), 0);
    }

    function _params(bool tokenBelow) private view returns (IImdLaunchFactory.LaunchParams memory p) {
        bytes memory input = vm.parseBytes(vm.readFile("test/fixtures/kept-launch-input.hex"));
        bytes memory args = new bytes(input.length - 4);
        for (uint256 i; i < args.length; ++i) args[i] = input[i + 4];
        p = abi.decode(args, (IImdLaunchFactory.LaunchParams));
        bytes memory tokenCode = type(IMDirectorToken).creationCode;
        uint64 number = p.launchNumber + 10000;
        address token;
        while (true) {
            token = factory.predictToken(number, tokenCode);
            if ((token < IMD) == tokenBelow && !IImdRegistry(factory.registry()).isRecorded(number)) break;
            ++number;
        }
        bytes memory hookCode = abi.encodePacked(type(IMDPhysicalHook).creationCode, abi.encode(MANAGER, OWNER, FACTORY));
        p.launchNumber = number;
        p.tokenCreationCode = tokenCode;
        p.hookCreationCode = hookCode;
        p.hookSalt = _salt(hookCode);
        p.hookFlags = FLAGS;
        p.totalSupply = SUPPLY;
        p.poolBps = 8000;
        p.remainderTo = OWNER;
        p.requester = OWNER;
        p.pairedCurrency = Currency.wrap(IMD);
        p.fee = 12500;
        p.tickSpacing = 60;
        uint256 seed = SUPPLY * 8000 / 10000 * 999 / 1000;
        if (tokenBelow) {
            p.sqrtPriceX96 = 125270724187523965593206900;
            (p.tickLower, p.tickUpper) = (-128940, 887220);
            uint160 a = TickMath.getSqrtPriceAtTick(p.tickLower);
            uint160 b = TickMath.getSqrtPriceAtTick(p.tickUpper);
            p.liquidity = uint128(FullMath.mulDiv(seed, FullMath.mulDiv(a, b, 1 << 96), b - a));
        } else {
            p.sqrtPriceX96 = 50108289675009586237282760313921;
            (p.tickLower, p.tickUpper) = (-887220, 128940);
            p.liquidity = uint128(FullMath.mulDiv(seed, 1 << 96,
                TickMath.getSqrtPriceAtTick(p.tickUpper) - TickMath.getSqrtPriceAtTick(p.tickLower)));
        }
    }

    function _salt(bytes memory code) private pure returns (bytes32) {
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 1_000_000; ++i) {
            address predicted = address(uint160(uint256(keccak256(
                abi.encodePacked(bytes1(0xff), FACTORY, bytes32(i), hash)))));
            if (uint160(predicted) & 0x3fff == FLAGS) return bytes32(i);
        }
        revert("no matching salt");
    }
}
