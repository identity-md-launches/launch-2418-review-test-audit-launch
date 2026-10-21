// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Ported from the pinned protected admission input. See README.md for mechanical adaptations.

import {AdmissionInputs} from "./AdmissionSupport.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {HookFlags} from "./AdmissionSupport.sol";
import {MockERC20} from "./AdmissionSupport.sol";

/// @notice What a launch hook must report about itself.
/// @dev Not part of `IHooks` — v4 never calls it, so a hook can omit it and still function. A launch
/// hook may not: the address is mined for the declared flags, and asking the implementation is the
/// only way to know it agrees with them.
interface IHookPermissions {
    function getHookPermissions() external pure returns (Hooks.Permissions memory);
}

/// @notice The baseline every launch hook passes before it is admitted.
/// @dev These live in our toolchain rather than the delivered repository, so a contributor cannot
/// relax them — the fleet never sees this file. They run against the attested creation code, so what
/// is judged is what is deployed.
abstract contract HookProtectedTest is AdmissionInputs {
    using StateLibrary for IPoolManager;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant SUPPLY = 1_000_000 ether;

    PoolManager manager;
    MockERC20 token0;
    MockERC20 token1;

    address hook;
    uint160 declaredFlags;
    PoolKey key;

    function setUp() public {
        bytes memory creationCode = hookCreationCode();
        declaredFlags = uint160(uint256(0x2040));

        // The launch's chain, and its pair token, before anything is built. A hook may refuse to
        // deploy anywhere but its chain, or until its pair token exists, and both hold where the
        // factory deploys it. Job 147699d2's hook did both, and every one of its floor tests failed
        // in setUp on forge's default chain with nothing at its pair token.
        uint256 chain = uint256(4663);
        if (chain != 0) vm.chainId(chain);
        address paired = PAIR;
        if (paired != address(0) && paired.code.length == 0) {
            // The pair token lives on the launch chain, not here: an empty ERC-20 at its address
            // stands in for it, which is all construction and initialization read.
            vm.etch(paired, deployCode("AdmissionSupport.sol:MockERC20", abi.encode("Pair", "PAIR", uint256(0))).code);
        }

        // A real hook takes its pool manager as a constructor argument, so the address is already
        // baked into the creation code we were handed. We cannot change that, so we put a working
        // manager where the hook expects one, its constructor run in place. A copy of a manager
        // built elsewhere would not do: `PoolManager` inherits `NoDelegateCall`, which records the
        // address it was built at and refuses every call made to its code anywhere else, so the
        // copy could be read but never initialized.
        address expected = managerProbe();

        if (expected == address(0)) {
            manager = PoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        } else {
            vm.etch(expected, abi.encodePacked(vm.getCode("PoolManager.sol:PoolManager"), abi.encode(address(this))));
            (bool built, bytes memory runtime) = expected.call("");
            require(built, "the pool manager's constructor reverted at the hook's manager address");
            vm.etch(expected, runtime);
            manager = PoolManager(expected);
        }

        // A hook built against `$token` was encoded with the token probe's address, and the factory
        // deploys the launch token before the hook. Put the real token there first, constructor run
        // in place (forge-std's deployCodeTo), so a hook that reads its token at construction finds it.
        address tokenProbe = tokenProbeAddress();
        if (tokenProbe != address(0)) {
            bytes memory tokenCode = tokenCreationCode();
            require(tokenCode.length > 0, "the hook names $token but the launch token's creation code was not given");
            vm.etch(tokenProbe, tokenCode);
            (bool built, bytes memory runtime) = tokenProbe.call("");
            require(built, "the launch token's constructor reverted at the token probe");
            vm.etch(tokenProbe, runtime);
        }

        hook = deployAtFlags(creationCode, declaredFlags);

        MockERC20 a = MockERC20(deployCode("AdmissionSupport.sol:MockERC20", abi.encode("A", "A", SUPPLY)));
        MockERC20 b = MockERC20(deployCode("AdmissionSupport.sol:MockERC20", abi.encode("B", "B", SUPPLY)));
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    /// @dev Mines a salt until CREATE2 lands the hook on an address carrying the declared bits, the
    /// same way the deployer will. A hook that cannot be placed at a matching address is one
    /// `PoolManager` would refuse, and finding that here costs nothing.
    function deployAtFlags(bytes memory creationCode, uint160 flags) internal returns (address at) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 200_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, flags)) continue;

            bytes32 salt = bytes32(i);
            assembly ("memory-safe") {
                at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            }
            require(at != address(0), "hook deployment reverted");
            return at;
        }
        revert("no salt produced an address carrying the declared flags");
    }

    /// @notice The implementation agrees with the address it was mined for.
    /// @dev The single most important check here. `PoolManager` calls exactly the callbacks the
    /// address advertises; a hook whose address claims a permission it does not implement is called
    /// for a callback it reverts on, and that revert takes the pool with it.
    function test_permissionsMatchTheDeclaredFlags() public view {
        Hooks.Permissions memory p = IHookPermissions(hook).getHookPermissions();
        assertTrue(p.beforeInitialize || p.afterInitialize, "launch hooks require an initialization callback");

        uint160 implemented = 0;
        if (p.beforeInitialize) implemented |= HookFlags.BEFORE_INITIALIZE;
        if (p.afterInitialize) implemented |= HookFlags.AFTER_INITIALIZE;
        if (p.beforeAddLiquidity) implemented |= HookFlags.BEFORE_ADD_LIQUIDITY;
        if (p.afterAddLiquidity) implemented |= HookFlags.AFTER_ADD_LIQUIDITY;
        if (p.beforeRemoveLiquidity) implemented |= HookFlags.BEFORE_REMOVE_LIQUIDITY;
        if (p.afterRemoveLiquidity) implemented |= HookFlags.AFTER_REMOVE_LIQUIDITY;
        if (p.beforeSwap) implemented |= HookFlags.BEFORE_SWAP;
        if (p.afterSwap) implemented |= HookFlags.AFTER_SWAP;
        if (p.beforeDonate) implemented |= HookFlags.BEFORE_DONATE;
        if (p.afterDonate) implemented |= HookFlags.AFTER_DONATE;
        if (p.beforeSwapReturnDelta) implemented |= HookFlags.BEFORE_SWAP_RETURN_DELTA;
        if (p.afterSwapReturnDelta) implemented |= HookFlags.AFTER_SWAP_RETURN_DELTA;
        if (p.afterAddLiquidityReturnDelta) implemented |= HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA;
        if (p.afterRemoveLiquidityReturnDelta) implemented |= HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA;

        assertEq(implemented, declaredFlags & HookFlags.ALL, "getHookPermissions disagrees with the manifest");
        assertEq(HookFlags.flagsOf(hook), declaredFlags & HookFlags.ALL, "the address disagrees too");
    }

    /// @notice Nothing in the code makes the reviewed behaviour non-final.
    /// @dev Also checked off chain from the attestation. Repeated here against the deployed runtime
    /// code, because this is the copy the pool will actually call. Only what execution can reach is
    /// read: from the start or a JUMPDEST, to STOP, JUMP, RETURN, REVERT, INVALID or SELFDESTRUCT.
    /// The constants solc keeps after its code are data, and their bytes are not instructions.
    function test_runtimeCodeHasNoEscapeHatch() public view {
        bytes memory code = hook.code;
        assertGt(code.length, 0, "the hook deployed no runtime code");
        assertLe(code.length, 24_576, "over the EIP-170 limit");

        bool reachable = true;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x60 + 1;
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xff, "runtime code contains SELFDESTRUCT");
                assertTrue(op != 0xf4, "runtime code contains DELEGATECALL");
                assertTrue(op != 0xf2, "runtime code contains CALLCODE");
            }
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }

    /// @notice Only the pool manager may drive a hook callback.
    /// @dev A hook that accepts a callback from anywhere lets a caller move its accounting without
    /// the pool ever being touched. Every callback the hook declares is offered from this test's own
    /// address, and every one of them has to refuse.
    function test_callbacksRefuseCallersOtherThanThePoolManager() public {
        Hooks.Permissions memory p = IHookPermissions(hook).getHookPermissions();

        if (p.beforeInitialize) {
            expectRefusal(abi.encodeCall(IHooks.beforeInitialize, (address(this), key, SQRT_PRICE_1_1)));
        }
        if (p.afterInitialize) {
            expectRefusal(abi.encodeCall(IHooks.afterInitialize, (address(this), key, SQRT_PRICE_1_1, 0)));
        }
        if (p.beforeAddLiquidity) {
            expectRefusal(
                abi.encodeCall(
                    IHooks.beforeAddLiquidity,
                    (address(this), key, IPoolManager.ModifyLiquidityParams(-60, 60, 1 ether, bytes32(0)), "")
                )
            );
        }
        if (p.beforeRemoveLiquidity) {
            expectRefusal(
                abi.encodeCall(
                    IHooks.beforeRemoveLiquidity,
                    (address(this), key, IPoolManager.ModifyLiquidityParams(-60, 60, -1 ether, bytes32(0)), "")
                )
            );
        }
        if (p.beforeSwap) {
            expectRefusal(
                abi.encodeCall(
                    IHooks.beforeSwap,
                    (address(this), key, IPoolManager.SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2), "")
                )
            );
        }
        if (p.beforeDonate) {
            expectRefusal(abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, "")));
        }
    }

    /// @notice The launch factory can open the launch's own pool on this hook.
    /// @dev The factory deploys the hook and calls `PoolManager.initialize` itself, on the pool the
    /// launch opens: its token, the paired currency, the manifest's fee and spacing. A hook that
    /// refuses that call cannot launch. Job 203c263c's gate hook accepted initialization from one
    /// constructor-given factory, and its manifest gave it the burn address there; every check
    /// passed, and the launch would have reverted in the deployer's simulation after the audits.
    /// The verifier builds the hook with `$factory` resolved to `IMD_FACTORY_PROBE` and asks from
    /// there, so a hook that names its factory any other way (a literal for one chain) is refused
    /// here too, with the placeholder to use.
    function test_initializesFromTheLaunchFactory() public {
        address factory = FACTORY_PROBE;
        if (factory == address(0)) {
            // The launch pool's terms come with the factory probe; without them there is no pool to open.
            revert("admission prerequisite missing or failed");
            return;
        }
        // Its stand-in was put in place in setUp, before the hook was built.
        address paired = PAIR;
        address launchToken = launchTokenForPool();
        (address c0, address c1) = launchToken < paired ? (launchToken, paired) : (paired, launchToken);
        PoolKey memory launchKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: uint24(uint256(12500)),
            tickSpacing: int24(int256(uint256(60))),
            hooks: IHooks(hook)
        });
        uint160 price = uint160(openingPrice());

        vm.prank(factory);
        try manager.initialize(launchKey, price) {}
        catch {
            fail(
                "the hook refused PoolManager.initialize from the launch factory on the launch's pool: name the factory with $factory, "
                "and accept the pool it opens (the launch token, the paired currency, the manifest's fee and tick spacing)"
            );
        }
    }

    /// @dev The launch token where a `$token` hook was built to find it, else one deployed from the
    /// launch token's creation code, else a stand-in: the hook learns the token from the key.
    function launchTokenForPool() internal returns (address) {
        address tokenProbe = tokenProbeAddress();
        if (tokenProbe != address(0)) return tokenProbe;
        bytes memory tokenCode = tokenCreationCode();
        if (tokenCode.length == 0) {
            return deployCode("AdmissionSupport.sol:MockERC20", abi.encode("Launch", "LAUNCH", SUPPLY));
        }
        address at;
        assembly ("memory-safe") {
            at := create(0, add(tokenCode, 0x20), mload(tokenCode))
        }
        require(at != address(0), "the launch token's constructor reverted");
        return at;
    }

    function expectRefusal(bytes memory call) internal {
        (bool ok,) = hook.call(call);
        assertFalse(ok, "a hook callback accepted a caller that was not the pool manager");
    }

    /**
     * The rest of the pool lifecycle — seed, trade both ways, unwind — is deliberately not here.
     *
     * Opening the pool is (`test_initializesFromTheLaunchFactory`), now that the manager is built in
     * place at the hook's address. Seeding and trading need the factory's own position logic and the
     * real pair token's behaviour, so they belong where both exist — the fork rehearsal, against
     * recent mainnet state. That is a separate check, and the admission gate records it separately,
     * precisely so that "did not run" cannot read as "passed".
     */

    function readPrice() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
    }
}

contract HookAdmissionTokenBelowTest is HookProtectedTest {}

contract HookAdmissionTokenAboveTest is HookProtectedTest {
    function tokenProbeAddress() internal pure override returns (address) {
        return address(type(uint160).max);
    }
}

contract HookAdmissionAlternateManagerTest is HookProtectedTest {
    function managerProbe() internal pure override returns (address) {
        return address(0xA11CE);
    }
}
