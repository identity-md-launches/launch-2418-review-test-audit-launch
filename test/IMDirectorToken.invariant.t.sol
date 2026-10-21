// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDirectorToken} from "src/IMDirectorToken.sol";

/// @dev A closed population: every recipient is tracked, including the deployer/factory.
/// No deal(), minting, storage writes or token mocks can mask lost or newly created supply.
contract DirectorTokenHandler is Test {
    IMDirectorToken public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(IMDirectorToken token_, address factory) {
        token = token_;
        actors = [factory, address(this), makeAddr("holder A"), makeAddr("holder B"), makeAddr("spender")];
        expectedBalance[factory] = 1e27;
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        amount = _bound(amount, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount, bool unlimited) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : _bound(amount, 0, 1e27);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function spend(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 maximum = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        amount = _bound(amount, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function overdraw(uint8 ownerSeed, uint8 spenderSeed, bool direct) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        bytes memory data;
        if (direct) {
            data = abi.encodeCall(token.transfer, (spender, expectedBalance[owner] + 1));
            vm.prank(owner);
        } else {
            uint256 allowed = expectedAllowance[owner][spender];
            // This branch probes either insufficient allowance or insufficient balance, including
            // allowance rollback when spending first succeeds but the subsequent transfer fails.
            uint256 amount = allowed == type(uint256).max ? expectedBalance[owner] + 1 : allowed + 1;
            data = abi.encodeCall(token.transferFrom, (owner, spender, amount));
            vm.prank(spender);
        }
        (bool success,) = address(token).call(data);
        assertFalse(success, "an overdraft succeeded");
    }

    function forbiddenAdmin(uint8 callerSeed, uint8 operation) external {
        address caller = actors[callerSeed % actors.length];
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", caller, 1),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("burnFrom(address,uint256)", actors[0], 1),
            abi.encodeWithSignature("transferOwnership(address)", caller),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", actors[0]),
            abi.encodeWithSignature("initialize(address)", caller),
            abi.encodeWithSignature("upgradeTo(address)", caller)
        ];
        vm.prank(caller);
        (bool success,) = address(token).call(calls[operation % calls.length]);
        assertFalse(success, "fixed-supply token exposed an admin path");
    }
}

contract IMDirectorTokenInvariantTest is Test {
    IMDirectorToken private token;
    DirectorTokenHandler private handler;

    function setUp() public {
        token = IMDirectorToken(deployCode("IMDirectorToken.sol:IMDirectorToken"));
        handler = DirectorTokenHandler(
            deployCode("IMDirectorToken.invariant.t.sol:DirectorTokenHandler", abi.encode(token, address(this)))
        );
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.spend.selector;
        selectors[3] = handler.overdraw.selector;
        selectors[4] = handler.forbiddenAdmin.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyBalancesAndAllowancesAreConserved() public view {
        assertEq(token.totalSupply(), 1e27, "supply changed after deployment");
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "tax, theft or unexpected mint");
            total += balance;
            for (uint256 j; j < 5; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(actor, spender));
            }
        }
        assertEq(total, 1e27, "balances no longer sum to the fixed supply");
        assertEq(token.balanceOf(address(0)), 0);
    }
}
