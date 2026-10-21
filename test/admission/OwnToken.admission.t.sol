// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Ported from the pinned protected admission input. See README.md for mechanical adaptations.

import {AdmissionInputs} from "./AdmissionSupport.sol";

/// @notice The ERC-20 a hook launch's own token answers to here, declared here for the reason the
/// token floor gives: what is judged is the deployed bytecode, reached through an interface of ours.
interface IOwnToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice A contract that holds the token and pays it out, standing in for the swarm's distributor
/// and the PoolManager: a launch sends its token to contracts and has contracts pay it on.
contract OwnTokenPayer {
    function pay(IOwnToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice What a hook launch's own token owes the launch, whatever else it does. It runs only for a
/// launch ordered with its own token (`IMD_CUSTOM_TOKEN`), beside the token floor every launch passes.
/// @dev LaunchFactory deploys the token and refuses the launch unless it holds the whole supply the
/// manifest names (`SupplyMismatch`). It then sends the swarm's tenth to the launch's distributor,
/// seeds the pool through the PoolManager and sends the rest to the requester; the distributor pays
/// claims; traders move the token through the PoolManager. LaunchFactory has no `distributorOf` a
/// token could ask, so none of those can be exempted from a rule that taxes, burns or refuses a
/// transfer: they must move what they are asked. A token may give its holders rules to use on one
/// another, a freeze bought with the token among them, but no hand that holds none of it may move or
/// freeze a holder's balance: that would be a privilege, not a rule.
abstract contract OwnTokenProtectedTest is AdmissionInputs {
    address constant HOLDER = address(0x401D);
    address constant OTHER = address(0x07E5);
    address constant STRANGER = address(0xBEEF);

    /// @dev Where the launch factory stands in the floor: the token is deployed from here, as LaunchFactory deploys it.
    address factory;
    IOwnToken token;
    uint256 expectedSupply;

    function setUp() public {
        // Skipped, never passed, for the standard token or a launch with no token code to hand over.
        bytes memory creationCode = tokenCreationCode();
        if (uint256(1) == 0 || creationCode.length == 0) {
            revert("admission prerequisite missing or failed");
            return;
        }
        factory = FACTORY_PROBE;
        expectedSupply = uint256(1e27);
        uint256 chain = uint256(4663);
        if (chain != 0) vm.chainId(chain);

        address deployed;
        vm.prank(factory);
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "token deployment reverted");
        token = IOwnToken(deployed);
    }

    /// @dev The factory counts the whole supply as its own before it splits any of it.
    function test_mintsTheManifestSupplyToTheFactory() public view {
        assertEq(token.totalSupply(), expectedSupply, "the token mints another supply than its manifest names");
        assertEq(
            token.balanceOf(factory),
            expectedSupply,
            "the token mints somewhere other than the launch factory that deploys it"
        );
    }

    /// @dev The launch's own transfers, between the factory, contracts and wallets, each move exactly
    /// what they are asked and leave the supply as it was.
    function test_theLaunchFlowsMoveExactly() public {
        OwnTokenPayer distributor = new OwnTokenPayer();
        OwnTokenPayer pool = new OwnTokenPayer();
        uint256 swarm = expectedSupply / 10;
        uint256 seed = expectedSupply / 2;
        // the factory pays the swarm's tenth, seeds the pool and sends the rest to the requester
        _sends(factory, address(distributor), swarm);
        _sends(factory, address(pool), seed);
        _sends(factory, HOLDER, token.balanceOf(factory));
        // the distributor pays a claim, the pool pays a buyer and takes a seller's tokens, and wallets trade
        _paid(distributor, OTHER, swarm / 3);
        _paid(pool, OTHER, seed / 7);
        _sends(OTHER, address(pool), token.balanceOf(OTHER) / 2);
        _sends(HOLDER, OTHER, token.balanceOf(HOLDER) / 3);
        assertEq(token.totalSupply(), expectedSupply, "a launch transfer changed the supply");
    }

    /// @dev Nobody but a holder moves or freezes its balance. Every privileged call in the list is tried
    /// from a wallet holding none of the token, which a rule bought with the token cannot be used from;
    /// afterwards the holder must hold what it held and still be able to transfer.
    function test_noHandWithoutTheTokenMovesOrFreezesAHolder() public {
        vm.prank(factory);
        assertTrue(token.transfer(HOLDER, expectedSupply / 1_000), "the factory could not pay a holder");
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0, "the holder received nothing");
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            vm.prank(STRANGER);
            (bool ok,) = address(token).call(data);
            ok;
        }
        vm.prank(STRANGER);
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(IOwnToken.transferFrom.selector, HOLDER, STRANGER, 1));
        moved;
        assertEq(
            token.balanceOf(HOLDER), held, "a call from a wallet holding none of the token moved a holder's balance"
        );
        vm.prank(HOLDER);
        assertTrue(
            token.transfer(OTHER, held / 2),
            "a call from a wallet holding none of the token stopped a holder's transfers"
        );
    }

    function _sends(address from, address to, uint256 amount) private {
        uint256 had = token.balanceOf(from);
        uint256 before = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "a launch transfer returned false");
        assertEq(token.balanceOf(to) - before, amount, "a launch transfer arrived short");
        assertEq(had - token.balanceOf(from), amount, "a launch transfer took other than it moved");
    }

    function _paid(OwnTokenPayer payer, address to, uint256 amount) private {
        uint256 before = token.balanceOf(to);
        assertTrue(payer.pay(token, to, amount), "a contract's transfer returned false");
        assertEq(token.balanceOf(to) - before, amount, "a contract's transfer arrived short");
    }
}

contract OwnTokenAdmissionTokenBelowTest is OwnTokenProtectedTest {}

contract OwnTokenAdmissionTokenAboveTest is OwnTokenProtectedTest {
    function tokenProbeAddress() internal pure override returns (address) {
        return address(type(uint160).max);
    }
}
