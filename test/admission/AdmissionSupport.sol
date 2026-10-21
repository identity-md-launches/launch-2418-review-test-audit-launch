// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPhysicalHook} from "src/IMDPhysicalHook.sol";
import {IMDirectorToken} from "src/IMDirectorToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Explicit offline admission inputs; never mutates process-wide environment variables.
/// Probe addresses represent test roles, not a deployment or recipient recommendation.
abstract contract AdmissionInputs is Test {
    // The vendored forge-std predates the protected floor's fail(string) overload.
    function fail(string memory reason) internal pure {
        revert(reason);
    }

    address internal constant OWNER_PROBE = address(0xD35C);
    address internal constant ORIGIN_PROBE = address(0x011619);
    address internal constant FACTORY_PROBE = address(0xFaC7);
    address internal constant PAIR = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    function managerProbe() internal pure virtual returns (address) {
        return 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    }

    function tokenProbeAddress() internal pure virtual returns (address) {
        return address(0x70CE);
    }

    function openingPrice() internal pure returns (uint256) {
        return tokenProbeAddress() < PAIR ? 125270724187523965593206900 : 50108289675009586237282760313921;
    }

    // Load artifacts from this build rather than embedding and optimizing another copy of each
    // deployment in every derived admission suite. Constructors still execute normally.
    function hookCreationCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            vm.getCode("IMDPhysicalHook.sol:IMDPhysicalHook"), abi.encode(managerProbe(), OWNER_PROBE, FACTORY_PROBE)
        );
    }

    function tokenCreationCode() internal view returns (bytes memory) {
        return vm.getCode("IMDirectorToken.sol:IMDirectorToken");
    }
}

/// @dev The protected Owners input references an unbundled OwnerChecks helper. This replacement
/// checks the explicit owner and both disallowed deployment identities, without inferring an owner.
abstract contract OwnerChecks is AdmissionInputs {
    function checkOwner(string memory, address target, address factory) internal view {
        IMDPhysicalHook h = IMDPhysicalHook(target);
        assertEq(h.owner(), OWNER_PROBE, "owner must be the explicit constructor argument");
        assertTrue(h.owner() != factory, "factory became owner");
        assertTrue(h.owner() != ORIGIN_PROBE, "launch origin became owner");
        assertEq(h.pendingOwner(), address(0));
        assertEq(h.launchFactory(), factory);
        assertFalse(h.enabled(), "launch activated reactions");
        assertFalse(h.poolBound(), "launch consumed the owner bind");
    }
}

library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = Hooks.BEFORE_INITIALIZE_FLAG;
    uint160 internal constant AFTER_INITIALIZE = Hooks.AFTER_INITIALIZE_FLAG;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY = Hooks.AFTER_ADD_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
    uint160 internal constant BEFORE_SWAP = Hooks.BEFORE_SWAP_FLAG;
    uint160 internal constant AFTER_SWAP = Hooks.AFTER_SWAP_FLAG;
    uint160 internal constant BEFORE_DONATE = Hooks.BEFORE_DONATE_FLAG;
    uint160 internal constant AFTER_DONATE = Hooks.AFTER_DONATE_FLAG;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    uint160 internal constant ALL = Hooks.ALL_HOOK_MASK;

    function matches(address a, uint160 flags) internal pure returns (bool) {
        return flagsOf(a) == flags & ALL;
    }

    function flagsOf(address a) internal pure returns (uint160) {
        return uint160(a) & ALL;
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}

/// @dev Funded test actor. Each swap and its entire settlement occur in one manager.unlock call.
contract Swapper is IUnlockCallback {
    IPoolManager private immutable manager;
    address private immutable controller = msg.sender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amount) external returns (BalanceDelta) {
        require(msg.sender == controller);
        return abi.decode(manager.unlock(abi.encode(key, zeroForOne, amount)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint256 amount) = abi.decode(data, (PoolKey, bool, uint256));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        settle(key.currency0, delta.amount0());
        settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(-int256(delta))));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(int256(delta)));
        }
    }
}
