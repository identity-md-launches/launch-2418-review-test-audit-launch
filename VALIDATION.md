# Validation of the initialization compatibility fix

2026-10-22 (Asia/Yekaterinburg). No token or hook has been deployed in mainnet. The user paid one 0.5 IMD Intake request; its job `582906e4-3ecf-48b2-ab13-e3a2c52743e8` stopped before deployment because the original afterSwap-only specification conflicted with protected admission.

## Reproduced issue and fix

The original commit `9701276d06b5c0f9840da7d5b144d51a22514dd9` permitted counterfactual pool initialization. Both tests in the accepted auditor proof fail on that original source. They now pass in `test/IMDPhysicalHook.init.t.sol`. The minimal production change adds `beforeInitialize`, flags `0x2040`, and an immutable nonzero factory supplied as `$factory` after `$owner`. Only the canonical PoolManager may call it and its sender must be that factory. Initialization does not bind, enable or emit relay commands. The gateway event, swap logic, owner activation sequence and token economics are preserved.

## Verified results

- Full offline suite: **34 passed, 0 failed, 2 explicitly skipped**. The two skipped cases require `RH_RPC`; they were run successfully in the separate real-factory rehearsal below. Fuzz runs: 512.
- Canonical Robinhood integration suite: **8 passed, 0 failed, 0 skipped**, at fork block 94534844. Canonical PoolManager and IMD bytecode remain intact. Local balances, pools and hook deployments do not leave the fork.
- Complete real-LaunchFactory rehearsal: **2 passed, 0 failed, 0 skipped**, at fork blocks 94533223 and 94533228. The actual factory deployer is impersonated only in the local EVM. No production contract code, callback validation or authorization is mocked or overwritten. The real factory creates the token and factory-gated hook, initializes and seeds Director/IMD with 80/10/10; owner is the explicit user wallet. Tests then bind and enable locally and execute successful buys and sells. Registry, supply, allocation, factory identity, permission bits and command counters are asserted. Each launch call stays below the 16,777,216 gas cap.
- Published IMD admission floor: **13 passed, 0 failed, 0 skipped in each token order** (4 hook, 2 ownership/fee collection, 7 token). Tests are copied unchanged into a temporary project from `identity-md-launches/launch-2255-launch-curb-curb-uniswap` at `b810098c73b7de0cf08257aa01a08b279e965c7f`, with that repository's compatible v4 dependencies. Our exact creation code and probe-resolved constructor arguments are supplied to it. These published tests are useful independent evidence; the current server-side floor and attestation remain authoritative.
- Hook creation code: 5,408 bytes before the two 32-byte constructor arguments; runtime: 4,647 bytes.

Foundry v1.8.3 and native Solidity 0.8.26 remain pinned (Cancun, optimizer 200, via IR, bytecode hash none, FFI disabled). Original dependency provenance is in `DEPENDENCIES.json`. The Foundry Solar preprocessor warns about the standard indirect `Ownable` constructor; native Solidity compilation and all executed tests succeed.

## Reproduce

```sh
forge test -vv
IMDIRECTOR_CANONICAL_FORK=true forge test --fork-url https://rpc.mainnet.chain.robinhood.com --match-contract IMDPhysicalHookIntegrationTest -vv
RH_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract IMDirectorLaunchForkTest -vv

git clone https://github.com/identity-md-launches/launch-2255-launch-curb-curb-uniswap /tmp/imd-admission-reference
git -C /tmp/imd-admission-reference checkout b810098c73b7de0cf08257aa01a08b279e965c7f
python3 script/check_published_admission.py --reference /tmp/imd-admission-reference
```

The factory ABI and historical launch-input fixture in `test/support/IMDLaunchTypes.sol` and `test/fixtures/kept-launch-input.hex` are MIT-licensed test material from the same pinned public example. Only the ABI import prefix was adapted; the fixture is unchanged (SHA-256 `7e35200aa8ec695aca23dc75115e33a40e94c51e72c0f0d8b9d924f2b775b01b`). Its historical record/attestation fields are rehearsal data, not a new attestation or an actual launch approval. IMD must still review, attest and deploy the final supplied source through its own pipeline.

One-time `bindPool` remains an owner responsibility: verify the exact initialized Director/IMD PoolKey and poolId before signing. A mistaken key cannot be corrected in this implementation.
