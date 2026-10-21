// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Ported from the pinned protected admission input. See README.md for mechanical adaptations.

import {AdmissionInputs} from "./AdmissionSupport.sol";

/// @notice The subset of ERC-20 a launch actually depends on.
/// @dev Declared here rather than imported so the floor does not inherit a definition from whichever
/// library the delivered project happened to vendor. What is asserted is the deployed bytecode's
/// behaviour, so the interface used to reach it must be ours.
interface IToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice The baseline every launch token passes before it is admitted.
/// @dev The factory already refuses a launch whose token did not mint the whole supply to it —
/// `SupplyMismatch`, checked once, at launch. That is a safe failure and it is not what this is for.
/// This is for everything the factory cannot see: a second mint path that dilutes holders an hour
/// later, a proxy that swaps the implementation, a self-destruct. None of those affect the balance
/// the factory counts, and all of them happen after it has stopped looking.
///
/// This is a floor and not a proof. A backdoor behind an unusual selector passes it. What it rules
/// out is the shapes that recur, and it runs against the attested creation code, so what is judged
/// is what is deployed.
abstract contract TokenProtectedTest is AdmissionInputs {
    /// @dev Whoever deploys the token in `setUp`, standing in for the factory. The token must mint
    /// to its deployer, because that is the only address the factory can check.
    address deployer;

    IToken token;
    uint256 supplyAtDeployment;

    function setUp() public {
        /**
         * Skipped, never passed, when there is no token to deploy.
         *
         * `vm.envBytes` would fail the whole floor — including the hook's half — for an attestation
         * that legitimately has no token code to hand over. But an empty `setUp` that let the tests
         * run against address zero would report six passes for six assertions nobody made, which is
         * the failure this entire layer exists to prevent. `vm.skip` is neither: forge counts these
         * separately from passes, so the verifier's own "a run that asserted nothing is not a pass"
         * check still sees the truth.
         */
        bytes memory creationCode = tokenCreationCode();
        if (creationCode.length == 0) {
            revert("admission prerequisite missing or failed");
            return;
        }

        deployer = address(this);
        // On the launch's chain, as the factory deploys it, for a token that checks where it is.
        uint256 chain = uint256(4663);
        if (chain != 0) vm.chainId(chain);

        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0), "token deployment reverted");

        token = IToken(deployed);
        supplyAtDeployment = token.totalSupply();
    }

    /// @dev The launch splits a supply the factory believes it holds. A token that minted anywhere
    /// else leaves every split short, and the factory's own check is the last thing between that and
    /// a pool seeded with tokens nobody has.
    function test_mintsTheWholeSupplyToItsDeployer() public view {
        assertGt(supplyAtDeployment, 0, "a token that minted nothing has nothing to launch");
        assertEq(token.balanceOf(deployer), supplyAtDeployment, "the deployer does not hold the whole supply");
    }

    /// @dev The number the factory counts. It reverts with `SupplyMismatch` unless it holds exactly
    /// the policy's supply, at launch, after every step was accepted and the job delivered; launch 684
    /// minted a million where the policy says a billion and parked there. Asked here, the build that
    /// got it wrong can still be revised.
    function test_mintsThePolicySupply() public {
        uint256 expected = uint256(1e27);
        // A skip and not a return: a verifier that sends no policy supply has not checked it.
        if (expected == 0) {
            revert("admission prerequisite missing or failed");
            return;
        }
        assertEq(supplyAtDeployment, expected, "the token does not mint the launch policy's supply");
        assertEq(token.balanceOf(deployer), expected, "the deployer does not hold the launch policy's supply");
    }

    /// @dev Cross-checked against the manifest, because the manifest's number is what a human reads
    /// and what downstream tooling formats with. Two places stating a decimals that disagree is a
    /// price wrong by orders of magnitude.
    function test_decimalsMatchTheManifest() public {
        uint256 declared = uint256(18);
        // A skip and not a return: a bare return is a green PASS for a test that asserted nothing.
        if (declared == type(uint256).max) {
            revert("admission prerequisite missing or failed");
            return;
        }
        assertEq(uint256(token.decimals()), declared, "decimals disagree with the manifest");
    }

    /// @dev The one the factory cannot catch. Its supply check runs once, at launch; nothing stops a
    /// mint an hour later, and a holder cannot tell the difference between a token that cannot be
    /// diluted and one that simply has not been yet.
    ///
    /// A curated selector list rather than fuzzed calldata: random bytes never land on a four-byte
    /// selector, so a fuzz test here would pass on everything and mean nothing. These are the shapes
    /// that recur.
    function test_noCommonAdminCallIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];

        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            ok; // A revert is the expected answer; what matters is the state afterwards.

            assertLe(token.totalSupply(), supplyAtDeployment, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev Even from the deployer, which is the factory. The factory is the one address a token
    /// could plausibly be written to trust, and a mint reachable by it is still a mint.
    function test_notEvenTheDeployerCanMintMore() public {
        bytes memory data = abi.encodeWithSignature("mint(address,uint256)", deployer, uint256(1));
        (bool ok,) = address(token).call(data);
        ok;
        assertLe(token.totalSupply(), supplyAtDeployment, "the deployer can mint after launch");
    }

    /// @dev A transfer that moves something other than what it was asked to move makes every split
    /// the factory computes wrong, and a fee-on-transfer token breaks pool accounting outright.
    function test_transferMovesExactlyWhatItWasAsked() public {
        address recipient = address(0xCAFE);
        uint256 amount = supplyAtDeployment / 1_000;
        vm.assume(amount > 0);

        uint256 before = token.balanceOf(deployer);
        assertTrue(token.transfer(recipient, amount), "transfer returned false");

        assertEq(token.balanceOf(recipient), amount, "recipient received a different amount");
        assertEq(token.balanceOf(deployer), before - amount, "sender lost a different amount");
        assertEq(token.totalSupply(), supplyAtDeployment, "a transfer changed the supply");
    }

    /// @dev `DELEGATECALL` in a token is a proxy, and a proxy is a token whose behaviour is whatever
    /// its admin says tomorrow. `SELFDESTRUCT` is a token that can stop existing under a live pool.
    /// Neither has a use here, and both are invisible to every behavioural test above — a proxy
    /// passes all of them and then changes.
    ///
    /// The scan steps over `PUSH` immediates. Without that, any constant containing 0xF4 reads as a
    /// delegatecall and the floor fails honest tokens, which is the fastest way to have a check
    /// switched off. For the same reason it reads only what execution can reach: solc keeps data
    /// after its code, constants its optimizer copies out among them, and a token that emitted
    /// `Transfer` from five places had the topic's 0xF2 read as CALLCODE there (2026-10-19). Code is
    /// entered at its start or at a JUMPDEST and a run ends at STOP, JUMP, RETURN, REVERT, INVALID or
    /// SELFDESTRUCT, so a run from an entry is what counts; a JUMPDEST in the data can be jumped to,
    /// and starts one.
    function test_runtimeCodeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0, "the token has no runtime code");

        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;

            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }

            if (reachable) {
                assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
                assertTrue(op != 0xF2, "runtime code contains CALLCODE");
                assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }
}

contract TokenAdmissionTokenBelowTest is TokenProtectedTest {}

contract TokenAdmissionTokenAboveTest is TokenProtectedTest {
    function tokenProbeAddress() internal pure override returns (address) {
        return address(type(uint160).max);
    }
}
