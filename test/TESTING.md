# Contributor test review

This contribution changes tests only. `src/`, `SPEC.md`, `launch.json`, ABIs, vendored
libraries and Foundry configuration are unchanged. It tests the corrected constructor
`(poolManager, owner, factory)`, retaining owner before factory, and permissions `0x2040`.

## Added coverage

| Suite | Properties exercised |
| --- | --- |
| `IMDPhysicalHook.regression.t.sol` | Owner activation and pending-owner isolation; replacement and cancellation of nominees; factory/origin isolation; exact administrative events; every unused callback; changes to every field of a foreign PoolKey; maximum threshold/cooldown; signed int128 deltas; exact gateway topics and ABI-encoded data independent of router parameters and hookData. |
| `IMDPhysicalHook.accounting.t.sol` | Real vendored PoolManager with the actual Director token and an offline IMD fixture. Exact input/output swaps in both token orders compared with an otherwise identical pool without a hook; identical deltas, price, tick, LP/protocol fees, liquidity and fee growth; zero hook balances, claims and deltas. Partial fills at price limits, settlement rollback, and fee collection/full withdrawal while reactions are disabled. |
| `IMDPhysicalHook.invariant.t.sol` | An independent model tracks ownership, nominations, one-time binding, enablement, rules, global cooldown, command IDs, timestamps and raw relay events across random call sequences in both token orders. Expected state is not copied from the implementation after actions. |
| `IMDirectorToken.invariant.t.sol` | Closed-population transfers, approvals, delegated spending, overdrafts and forbidden admin calls. Every balance and allowance matches independent bookkeeping and all balances sum to the unchanged `1e27` supply. No artificial balance writes or mint helpers in the invariant. |
| `admission/` | Current pinned Hook, Owners, OwnToken and Token checks: all 16 in each token order, plus six hook/owner checks with a different constructor-supplied manager. No RPC, environment setup or skips. See `admission/README.md` for the precise adaptations. |

The existing `testBindRequiresAnInitializedPoolAndStaysCorrectable` also now creates a
separate mistyped key. Its original `PoolKey memory mistyped = key` aliased the valid key,
so changing the mistyped fee changed both keys and failed to test correction to the original
pool. All its behavioral assertions are retained.

## Reproduction

The verifier seed is used for all reported offline results:

```sh
FOUNDRY_FUZZ_SEED=0xc59360b1fc5918340b5f23d218d10f16c1da967703989519e5bf5e02e9020917 forge test --offline -vv
forge build --offline
```

Fuzz and invariant settings live in Solidity NatSpec, not configuration files. The
original configuration already provides 512 fuzz runs; the new signed-delta and cooldown
fuzz tests request 1000. Handler calls are selected explicitly; expected failed contract
calls are caught and checked rather than counted as discarded invariant actions.

To keep local build output inside the writable test area, checks here set
`FOUNDRY_OUT=test/scratch/out` and `FOUNDRY_CACHE_PATH=test/scratch/cache`. These are optional
shell overrides; no submitted test imports or reads anything from `test/scratch`.

The original two real-factory tests correctly skip in an offline default run with no
`RH_RPC`. All added tests execute offline. Canonical-fork integration and real-factory
rehearsals remain distinct from offline tests and from an actual mainnet deployment.

## Original contribution results on 2026-10-21

Foundry 1.8.3, Solidity 0.8.26, the repository's unchanged Cancun/via-IR build settings,
and the seed above:

| Check | Result |
| --- | --- |
| `forge build --offline` | Passed; Foundry emitted lint warnings, with no build error. |
| Complete offline `forge test --offline -vv` | **98 passed, 0 failed, 2 skipped** across 19 suites. The two skips are the existing RPC-dependent factory rehearsals. |
| Current admission reproduction (included above) | **38 passed, 0 failed, 0 skipped**: 16 per token order plus six alternate-manager checks. |
| Relay invariants (included above) | Each order: 256 runs, 32,768 handler calls, 0 handler reverts. |
| Fixed-supply token invariant (included above) | 256 runs, 16,384 handler calls, 0 handler reverts. |
| Signed-delta and cooldown fuzz properties (included above) | 1,000 runs each, passed. |
| Pool accounting differential fuzz property (included above) | 512 runs, passed. |
| Existing canonical-fork integration suite | **8 passed, 0 failed, 0 skipped**, Robinhood chain 4663 at block **94,572,285**, canonical PoolManager/IMD bytecode retained. |
| Existing real-LaunchFactory fork rehearsal | **2 passed, 0 failed, 0 skipped**, both token orders, using latest state from the public RPC on this date. Includes the existing 80/10/10 allocation checks, explicit owner, manual bind/enable, buys/sells and per-launch gas bound. |

The fork runs used these commands, with the same output/cache overrides described above:

```sh
IMDIRECTOR_CANONICAL_FORK=true forge test --offline \
  --fork-url https://rpc.mainnet.chain.robinhood.com --fork-block-number 94572285 \
  --match-contract IMDPhysicalHookIntegrationTest -vv
RH_RPC=https://rpc.mainnet.chain.robinhood.com forge test --offline \
  --match-contract IMDirectorLaunchForkTest -vv
```

No new Solidity implementation defect was reproduced. The pool-key alias issue described
above was a test-fixture defect and was repaired within the permitted test scope.

## Compiler resource repair

The subsequent local check killed solc with SIGKILL while compiling 93 files. A fresh
offline build of the unchanged tree reproduced that failure. The test fixtures now load
creation code from the current build's artifacts with `vm.getCode` and construct routers,
invariant handlers and admission actors with `deployCode`. This removes repeated embedded
creation bytecode from the derived test contracts compiled with via-IR. The source imports
remain, so a clean build generates the required artifacts. No bytecode is downloaded or
checked in, and no submitted test depends on files under `test/scratch`.

All existing test methods, assertions, fuzz counts and invariant sequences are preserved.
Constructor arguments, deployment callers, mined CREATE2 addresses and PoolManager
construction at its expected address are preserved too. No source, manifest, dependency or
compiler configuration changes are part of this repair.

Verification after the repair, using the same seed and output/cache paths documented above:

| Check | Result |
| --- | --- |
| Fresh `forge build --offline`, all 93 source files | Passed; solc finished in **101.31 seconds** with warnings. |
| Full `forge test --offline -vv` | **98 passed, 0 failed, 2 skipped** across 19 suites in **38.34 seconds**. Only the two RPC-dependent factory rehearsals skipped. |
| Admission suites in that full run | **38 passed, 0 failed, 0 skipped**. |
| Invariants in that full run | 256 runs each; **32,768** calls per relay ordering and **16,384** token calls; zero handler reverts. |
| Canonical fork integration | **8 passed, 0 failed, 0 skipped**, Robinhood chain 4663 at block **94,583,253**. |
| Real-factory fork rehearsals | **2 passed, 0 failed, 0 skipped**, both token orders against current public RPC state. |

The public RPC returned `historical state ... is not available` for the original block
94,572,285. The current integration rerun used block 94,583,253 instead. Both fork commands
above were run with `--no-storage-caching`; the integration command used the new block.
These remain local fork simulations, without a broadcast or production activation.

## Scope and limitations

The hook is an observer, not a custodian. The token invariant covers the contract that
keeps balances; real-pool differential tests check that hook processing takes no funds or
claims. This is executable regression coverage, not formal verification or an independent
admission attestation.

The factory owns the 80/10/10 allocation and opening-cap policy, and the external gateway
owns hardware delivery. Local swaps cannot certify those external systems. No mainnet
transaction is signed or broadcast by these tests; they do not create a launch ID,
deployment receipt, production token/hook address or an activated device. Deployment and
owner acceptance remain separate, with reactions initially disabled.
