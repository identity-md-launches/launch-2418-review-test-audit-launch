# Validation

No token or hook has been deployed on mainnet by this repository. Job `582906e4-3ecf-48b2-ab13-e3a2c52743e8` stopped
before deployment because the original afterSwap-only hook conflicted with protected admission; this commit carries the
factory-gated `beforeInitialize` (flags `0x2040`) plus the three audit-driven changes listed in `ADAPTATION.md`.

## Reproduced issues and fixes

- Counterfactual initialization (job 582906e4): `beforeInitialize` admits only the PoolManager with `sender == launchFactory`
  and never binds or enables. `test/IMDPhysicalHook.init.t.sol` fails on the original afterSwap-only source and passes here.
- Audit `a152f7ee`: the PoolManager was a compiled constant; the pinned floor failed unless the verifier built its manager
  at that address. It is now the `$poolManager` constructor argument (first), followed by `$owner` and `$factory`.
- Audit `16ef6c00`: `bindPool` accepted a key no pool was initialized for and could not be corrected. It now requires
  `sqrtPriceX96 != 0` for the key in the PoolManager.
- Audit `cf32bd75`: inherited one-step `renounceOwnership` could freeze an enabled relay without an owner. It now reverts.

## Verified results (2026-10-21)

- Offline suite with the verifier's fuzz seed: **38 passed, 0 failed, 2 skipped** (the two skipped need `RH_RPC` and ran
  below). Fuzz runs: 512.
- Canonical Robinhood integration suite on a local fork: **8 passed, 0 failed, 0 skipped**. Canonical PoolManager and IMD
  bytecode intact; the unit fixture's local PoolManager deploy is skipped when the address already has code.
- Real-LaunchFactory rehearsal on a local fork (around block 94560933): **2 passed, 0 failed, 0 skipped**, both token
  orders. The real factory deploys the token and the `(poolManager, owner, factory)` hook, initializes and seeds Director/IMD
  80/10/10; the owner is the explicit wallet; `poolManager()` is the canonical manager; bind, enable, buy and sell commands
  1 and 2 succeed; each launch call stays below the 16,777,216 gas cap.
- Reproduced current protected admission floor (pinned `Hook`, `Owners`, `OwnToken`, `Token` protected tests):
  **16 passed, 0 failed, 0 skipped** with the token probe below IMD, **16 passed** above IMD, and **16 passed** with a
  non-canonical `IMD_POOL_MANAGER`, which the constant-manager build failed (`test_initializesFromTheLaunchFactory`
  failed and `test_theFactoryCollectsItsFeesWithTheHookLive` skipped).
- Hook creation code: 5,734 bytes before the three 32-byte constructor arguments; runtime: 4,897 bytes.

Foundry v1.8.3 and Solidity 0.8.26 remain pinned (Cancun, optimizer 200, via IR, bytecode hash none, FFI disabled).
Dependency provenance is in `DEPENDENCIES.json`.

## Reproduce

```sh
FOUNDRY_FUZZ_SEED=0xc59360b1fc5918340b5f23d218d10f16c1da967703989519e5bf5e02e9020917 forge test -vv
IMDIRECTOR_CANONICAL_FORK=true forge test --fork-url https://rpc.mainnet.chain.robinhood.com --match-contract IMDPhysicalHookIntegrationTest -vv
RH_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract IMDirectorLaunchForkTest -vv

git clone https://github.com/identity-md-launches/launch-2255-launch-curb-curb-uniswap /tmp/imd-admission-reference
git -C /tmp/imd-admission-reference checkout b810098c73b7de0cf08257aa01a08b279e965c7f
python3 script/check_published_admission.py --reference /tmp/imd-admission-reference
```

The factory ABI and historical launch-input fixture in `test/support/IMDLaunchTypes.sol` and
`test/fixtures/kept-launch-input.hex` are MIT-licensed test material from the same pinned public example. Its historical
record/attestation fields are rehearsal data, not a new attestation or an actual launch approval. IMD must still review,
attest and deploy the final supplied source through its own pipeline.

One-time `bindPool` remains an owner responsibility: verify the exact initialized Director/IMD PoolKey and poolId from the
launch's `Initialize` event before signing. A key the PoolManager has not initialized is refused and does not consume the
bind; a wrong but initialized key on this hook cannot occur unless the factory opened it.
