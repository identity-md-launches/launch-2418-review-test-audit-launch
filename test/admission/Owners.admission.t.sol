// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Ported from the pinned protected admission input. See README.md for mechanical adaptations.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookFlags} from "./AdmissionSupport.sol";
import {MockERC20} from "./AdmissionSupport.sol";
import {Swapper} from "./AdmissionSupport.sol";
import {OwnerChecks} from "./AdmissionSupport.sol";

/// @dev The launch factory's part, from the factory's address: it deploys the hook, opens the pool,
/// holds the seeded position and collects its fees with a zero liquidity change, as `PoolFees` does.
contract LaunchFactoryProbe is IUnlockCallback {
    error HookTookFees(int128 amount0, int128 amount1);

    address private immutable controller = msg.sender;
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function tryDeploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        require(msg.sender == controller, "not the protected harness");
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
    }

    function initialize(PoolKey memory key, uint160 price) external {
        require(msg.sender == controller, "not the protected harness");
        manager.initialize(key, price);
    }

    /// @dev Adds `liquidity`, or collects with zero, on the factory's position; the delta it settled.
    function modify(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity)
        external
        returns (int128, int128)
    {
        require(msg.sender == controller, "not the protected harness");
        return abi.decode(manager.unlock(abi.encode(key, tickLower, tickUpper, liquidity)), (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        // A collect that would have the position pay is what `PoolFees` refuses.
        if (liquidity == 0 && (a0 < 0 || a1 < 0)) revert HookTookFees(a0, a1);
        settle(key.currency0, a0);
        settle(key.currency1, a1);
        return abi.encode(a0, a1);
    }

    function settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}

/// @notice The hook is not owned by its factory or by IMD, and the factory can collect its pool's fees.
/// @dev Deploys the hook from the factory probe, with the launch wallet's place as `tx.origin`, as
/// the launch does. The fee collect is a zero liquidity change, which v4 treats as a removal: a hook
/// with remove-liquidity callbacks runs on it, and one that reverts there, always or behind a switch
/// its owner sets, freezes the fees of the payer and the network for good. A seed or a swap this hook
/// refuses is not this test's to judge, and skips it; the collect after them is.
abstract contract HookOwnersProtectedTest is OwnerChecks {
    uint256 constant FUNDS = 1e30;

    PoolManager manager;
    LaunchFactoryProbe factory;
    address hook;

    function setUp() public {
        // The launch's chain, and its pair token, before anything is built, as in the hook floor: a hook
        // may refuse to deploy anywhere but its chain, or until its pair token has code.
        uint256 chain = uint256(4663);
        if (chain != 0) vm.chainId(chain);
        address paired = PAIR;
        if (paired != address(0) && paired.code.length == 0) {
            vm.etch(paired, deployCode("AdmissionSupport.sol:MockERC20", abi.encode("Pair", "PAIR", uint256(0))).code);
        }
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
        address tokenProbe = tokenProbeAddress();
        if (tokenProbe != address(0)) {
            bytes memory tokenCode = tokenCreationCode();
            require(tokenCode.length > 0, "the hook names $token but the launch token's creation code was not given");
            vm.etch(tokenProbe, tokenCode);
            (bool built, bytes memory runtime) = tokenProbe.call("");
            require(built, "the launch token's constructor reverted at the token probe");
            vm.etch(tokenProbe, runtime);
        }
        address at = FACTORY_PROBE;
        vm.etch(at, deployCode("Owners.admission.t.sol:LaunchFactoryProbe", abi.encode(manager)).code);
        factory = LaunchFactoryProbe(payable(at));
        hook = deployAtFlags(hookCreationCode(), uint160(uint256(0x2040)));
    }

    function test_theHookIsNotOwnedByTheFactoryOrIMD() public {
        checkOwner(string("IMDPhysicalHook"), hook, address(factory));
    }

    function test_theFactoryCollectsItsFeesWithTheHookLive() public {
        if (FACTORY_PROBE == address(0)) {
            // The launch pool's terms come with the factory probe; without them there is no pool to open.
            revert("admission prerequisite missing or failed");
            return;
        }
        // Its stand-in was put in place in setUp, before the hook was built.
        address paired = PAIR;
        address launchToken = tokenProbeAddress();
        if (launchToken == address(0)) {
            launchToken = deployCode("AdmissionSupport.sol:MockERC20", abi.encode("Launch", "LAUNCH", uint256(0)));
        }
        (address c0, address c1) = launchToken < paired ? (launchToken, paired) : (paired, launchToken);
        int24 spacing = int24(int256(uint256(60)));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: uint24(uint256(12500)),
            tickSpacing: spacing,
            hooks: IHooks(hook)
        });
        // Opening the pool from the factory is `test_initializesFromTheLaunchFactory`'s to report.
        try factory.initialize(key, uint160(openingPrice())) {}
        catch {
            revert("admission prerequisite missing or failed");
            return;
        }
        Swapper trader = Swapper(deployCode("AdmissionSupport.sol:Swapper", abi.encode(manager)));
        fund(launchToken, address(factory));
        fund(paired, address(factory));
        fund(launchToken, address(trader));
        fund(paired, address(trader));
        int24 lower = TickMath.minUsableTick(spacing);
        int24 upper = TickMath.maxUsableTick(spacing);
        try factory.modify(key, lower, upper, 1e18) {}
        catch {
            revert("admission prerequisite missing or failed");
            return;
        }
        // Trades accrue fees to collect; a hook that gates trading may refuse them, which is its own business.
        trader.swap(key, true, 1e15);
        trader.swap(key, false, 1e15);

        try factory.modify(key, lower, upper, 0) {}
        catch (bytes memory reason) {
            string memory name = string("IMDPhysicalHook");
            if (bytes4(reason) == LaunchFactoryProbe.HookTookFees.selector) {
                fail(
                    string.concat(
                        name,
                        " takes a share of the launch factory's fee collect (a zero liquidity change from the factory), so the pool's fees can ",
                        "never be claimed: return no delta from afterRemoveLiquidity when the sender is the launch factory ($factory)"
                    )
                );
            } else {
                fail(
                    string.concat(
                        name,
                        " refuses the launch factory's fee collect, a zero liquidity change from the factory, so the payer's and the network's ",
                        "fees could never be claimed: let it through in beforeRemoveLiquidity and afterRemoveLiquidity, with no owner switch that can block it"
                    )
                );
            }
        }
    }

    function fund(address token, address to) internal {
        if (token == address(0)) vm.deal(to, FUNDS);
        else deal(token, to, FUNDS);
    }

    /// @dev Mines a salt that lands the hook, deployed from the factory probe, on its declared flags.
    function deployAtFlags(bytes memory creationCode, uint160 flags) internal returns (address at) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 200_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, flags)) continue;
            vm.prank(address(this), ORIGIN_PROBE);
            at = factory.tryDeploy(creationCode, bytes32(i));
            require(at != address(0), "hook deployment reverted");
            return at;
        }
        revert("no salt produced an address carrying the declared flags");
    }
}

contract OwnersAdmissionTokenBelowTest is HookOwnersProtectedTest {}

contract OwnersAdmissionTokenAboveTest is HookOwnersProtectedTest {
    function tokenProbeAddress() internal pure override returns (address) {
        return address(type(uint160).max);
    }
}

contract OwnersAdmissionAlternateManagerTest is HookOwnersProtectedTest {
    function managerProbe() internal pure override returns (address) {
        return address(0xA11CE);
    }
}
