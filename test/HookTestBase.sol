// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPhysicalHook} from "../src/IMDPhysicalHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

abstract contract HookTestBase is Test {
    using PoolIdLibrary for PoolKey;

    IMDPhysicalHook internal hook;
    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant FACTORY = 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645;
    bytes32 internal constant DEVICE = bytes32("imd-physical-room-1");
    uint256 internal constant MIN = 0.05 ether;

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

    function setUp() public virtual {
        vm.warp(1000);
        // bindPool reads the PoolManager's slot0, so the unit fixture runs a real PoolManager at the address the
        // hook is given. The canonical fork already has one there and keeps its bytecode intact.
        if (MANAGER.code.length == 0) deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), MANAGER);
        hook = _deploy(address(this));
    }

    function _deploy(address owner) internal returns (IMDPhysicalHook deployed) {
        return _deploy(MANAGER, owner);
    }

    function _deploy(address manager, address owner) internal returns (IMDPhysicalHook deployed) {
        bytes memory init = abi.encodePacked(type(IMDPhysicalHook).creationCode, abi.encode(manager, owner, FACTORY));
        bytes32 codeHash = keccak256(init);
        for (uint256 i;; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, codeHash)))));
            if (uint160(predicted) & 0x3fff != 0x2040 || predicted.code.length != 0) continue;
            deployed = new IMDPhysicalHook{salt: salt}(IPoolManager(manager), owner, FACTORY);
            assertEq(address(deployed), predicted);
            break;
        }
    }

    /// @dev Opens the pool as the launch factory does; initialization never binds or enables the hook.
    function _initialize(PoolKey memory key) internal {
        vm.prank(FACTORY);
        IPoolManager(MANAGER).initialize(key, uint160(1 << 96));
    }

    function _key(bool imdIs0) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(imdIs0 ? IMD : address(0x1000)),
            currency1: Currency.wrap(imdIs0 ? address(0x9000000000000000000000000000000000000000) : IMD),
            fee: 12500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _enable(bool imdIs0) internal returns (PoolKey memory key) {
        key = _key(imdIs0);
        _initialize(key);
        hook.bindPool(key);
        hook.setEnabled(true);
    }

    function _trigger(PoolKey memory key, int128 imdDelta, int128 otherDelta) internal {
        bool imdIs0 = Currency.unwrap(key.currency0) == IMD;
        BalanceDelta delta = imdIs0 ? toBalanceDelta(imdDelta, otherDelta) : toBalanceDelta(otherDelta, imdDelta);
        // amountSpecified and hookData deliberately do not represent the actual swap.
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(false, type(int256).max, 0);
        vm.prank(MANAGER);
        (bytes4 selector, int128 hookDelta) = hook.afterSwap(address(0xdead), key, params, delta, hex"1234");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(hookDelta, 0);
    }
}
