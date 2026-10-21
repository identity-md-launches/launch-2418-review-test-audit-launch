// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev The live LaunchFactory's launch entry point and its argument, as verified on Sourcify for
/// Robinhood Chain's factory 0xa25b02a1e93903b790e6aaf7da1b8b8d50294645 (src/LaunchFactory.sol,
/// src/LaunchRegistry.sol). Field order is the ABI and must not change.
interface IImdLaunchFactory {
    struct Launch {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct LaunchParams {
        uint64 launchNumber;
        bytes32 kind;
        bytes tokenCreationCode;
        bytes hookCreationCode;
        bytes32 hookSalt;
        uint160 hookFlags;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        Currency pairedCurrency;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Launch record;
        uint256[] agentIds;
        address requester;
    }

    function launch(LaunchParams calldata params) external returns (address token, address hook, address distributor);
    function deployer() external view returns (address);
    function registry() external view returns (address);
    function predictToken(uint64 launchNumber, bytes calldata tokenCreationCode) external view returns (address);
    function predictHook(bytes calldata hookCreationCode, bytes32 hookSalt) external view returns (address);
}

interface IImdRegistry {
    function isRecorded(uint64 launchNumber) external view returns (bool);
}
