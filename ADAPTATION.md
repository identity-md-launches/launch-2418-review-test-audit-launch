# Adaptation for the IMD `univ4_hook` launch on Robinhood Chain (4663)

Each change to the project, the file it touches, and the launch rule or reproduced audit finding that required it.
Everything else (gateway event ABI, relay semantics, activation protocol, token, economics, fee) is unchanged.

## Changes

### 1. PoolManager is a constructor argument (`$poolManager`), not a compiled constant

- Files: `src/IMDPhysicalHook.sol` (constructor, `poolManager` immutable, `InvalidPoolManager`), `launch.json`
  (`constructorArgs` is now `["$poolManager", "$owner", "$factory"]`), `test/HookTestBase.sol`, `test/IMDPhysicalHook.t.sol`,
  `test/IMDirectorLaunch.fork.t.sol`, `script/check_published_admission.py`, `SPEC.md` item 1, `README.md`.
- Required by: the launch reference ("Take the PoolManager as a constructor argument and never hardcode a PoolManager
  address in source, scripts or the manifest; the manifest writes that argument as `$poolManager`") and audit finding
  `a152f7ee` (low), which reproduced: with the constant, the pinned `Hook.protected.t.sol` and `Owners.protected.t.sol`
  pass only when the verifier is told to build its manager at that exact address; the hook refused every callback with
  `OnlyPoolManager` otherwise. This is the routine manifest/factory compatibility fix the brief authorizes when backed by a
  concrete finding. `$owner` and `$factory` keep their relative order; the owner and factory semantics are unchanged.
- Behaviour kept: on chain 4663 the deployer resolves `$poolManager` to the canonical PoolManager
  `0x8366a39cc670b4001a1121b8f6a443a643e40951`, which the fork rehearsal against the real LaunchFactory confirms
  (`hook.poolManager() == MANAGER`). The constructor only stores the address and refuses zero; it makes no call, so it runs
  on an empty chain in the launch checks.
- Tests: `testPoolManagerComesFromTheConstructor` (a hook built for another manager answers that manager and refuses the
  canonical address), `testRejectsZeroPoolManager`, and the reproduced protected floor run with a non-canonical
  `IMD_POOL_MANAGER` (16 passed, see below), which failed on the previous code.

### 2. `bindPool` requires a pool the PoolManager has initialized

- File: `src/IMDPhysicalHook.sol` (`bindPool`, `PoolNotInitialized`), `SPEC.md` item 2, `README.md` activation step 1.
- Required by: audit finding `16ef6c00` (low), reproduced on the arriving code: the owner could bind a key for a pool that
  was never initialized (for example the right currencies with fee 3000), `PoolAlreadyBound` then blocked the correct key
  forever, and relay 4 was permanently dead with only a redeployment as remedy. `bindPool` now reads
  `StateLibrary.getSlot0` for the key's poolId and reverts unless `sqrtPriceX96 != 0`. Because `beforeInitialize` admits
  only the launch factory, every initialized pool on this hook is one the factory opened, so this also enforces "the pool
  the factory opened". Binding stays one-shot and owner-only; nothing binds or enables automatically.
- Tests: `testBindRequiresAnInitializedPoolAndStaysCorrectable` (unit, real PoolManager at the hook's manager address) and
  the added assertion in `testFactoryOnlyForeignInitializeCannotCaptureBinding` (integration). The unit fixture
  (`HookTestBase`) now runs a real `PoolManager` at the manager address and opens pools from the factory before binding;
  the canonical-fork mode keeps the deployed PoolManager bytecode intact (`MANAGER.code.length != 0` skips the deploy).

### 3. One-step `renounceOwnership` is disabled

- File: `src/IMDPhysicalHook.sol` (`renounceOwnership` override reverting `RenounceDisabled`), `SPEC.md` item 9,
  `README.md` review boundaries.
- Required by: audit finding `cf32bd75` (low), reproduced: after `setEnabled(true)` a single `renounceOwnership()` left
  `owner() == address(0)`, every `setEnabled(false)`/`setRule` reverted for all callers, and buys kept emitting
  `RelayTriggered`. SPEC item 9 says ownership moves only with the pending owner's acceptance; the override makes that the
  only path. Two-step `transferOwnership`/`acceptOwnership` is unchanged.
- Test: `testRenounceOwnershipIsDisabled`.

### 4. Documentation and helper updates

- `launch.json`: `constructorArgs` and `notes` updated to the new constructor; nothing else in the manifest changed.
  (The manifest step rewrites this file after acceptance; it is kept consistent so a manifest check of the tree passes.)
- `script/check_published_admission.py`: encodes the three-argument constructor with the canonical PoolManager first.
- `abi/IMDPhysicalHook.json`, `abi/IMDirectorToken.json`: the final ABIs, exported with `forge inspect`.
- `VALIDATION.md`: results of the runs listed below. `README.md`: hook configuration record and the note that no job
  deploys anything.

## Audit findings that did not change code

- `1f36301726ed` (info): relay 4 can be held OFF by a 0.05 IMD sell every cooldown while buys in the window are
  skipped. Reproduced by reading `afterSwap`: the cooldown is global and first-eligible-wins, exactly as SPEC items 5 and
  6 require. This is a documented design property the owner tunes with `setRule` (raise `minImdAmount`, change
  `sellState`, or lengthen the cooldown); changing it would alter the requested relay semantics, which the brief forbids.
- `6c411cef45ab` (info): scope statement, no defect.

## What the brief asked that this job does not do

- Deploying, broadcasting, verifying contracts and reporting receipts, addresses, the PoolKey and the poolId: IMD's
  deployer performs the launch through the LaunchFactory after attestation; no job may call the factory or sign. The
  values exist only after that launch. The owner reads the real `Initialize` event, calls `bindPool` once, the operator
  connects the gateway, and the owner calls `setEnabled(true)`; relay reactions stay disabled until then.
- The 80% pool / 10% remainderTo / 10% swarm split and the 2,500 IMD opening cap are the factory's and the policy's; the
  contracts allocate nothing. `pool.initialPrice` is nominal; the deployer derives the opening price.

## Verification performed (2026-10-21)

- `forge build` and `forge test` with `FOUNDRY_FUZZ_SEED=0xc59360b1fc5918340b5f23d218d10f16c1da967703989519e5bf5e02e9020917`:
  38 passed, 0 failed, 2 skipped (the two real-factory fork tests need `RH_RPC`), 512 fuzz runs.
- Real-LaunchFactory fork rehearsal (`RH_RPC=https://rpc.mainnet.chain.robinhood.com`, around block 94560933): 2 passed,
  both token orders, 80/10/10 allocation, owner `0x755a...aa92`, `poolManager()` canonical, bind/enable, buy and sell
  commands 1 and 2, under the 16,777,216 gas cap.
- Canonical-fork integration suite (`IMDIRECTOR_CANONICAL_FORK=true --fork-url ...`): 8 passed.
- Reproduced protected admission floor (the four pinned `.imd/reads/protected/univ4_hook/*.protected.t.sol`, copied into
  `test/scratch/protected/` with imports pointed at this repository's vendored v4-core and scratch stand-ins for
  `HookFlags`, `MockERC20`, `Swapper` and `OwnerChecks`; `IMD_CUSTOM_TOKEN=1`, `IMD_FACTORY_PROBE=0x...FaC7`,
  creation code = hook bytecode ++ abi.encode(poolManager, owner, factory)): 16 passed, 0 failed, 0 skipped with the
  token probe below IMD, 16 passed with it above IMD, and 16 passed with a non-canonical `IMD_POOL_MANAGER`
  (`0x...00Ab`), the case the previous constant-manager build failed.
