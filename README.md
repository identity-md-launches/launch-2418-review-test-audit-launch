# IMDirector / Director

Self-contained Foundry source for an IMD Protocol `univ4_hook` launch on Robinhood Chain mainnet (4663), paired with IMD. No deployment has been performed by this repository.

- Token name: `IMDirector`; symbol: `Director` (case-sensitive); decimals: 18.
- `IMDirectorToken` mints the entire fixed 1e27 supply to its deployer once. The IMD factory performs the allocation; the token has no owner, external mint or transfer tax.
- Requested allocation: 80% pool, 10% explicit remainder recipient, 10% swarm. These terms belong in request `economics`, not extra manifest fields.
- Standard pool fee: 12500 (1.25%). The physical hook adds 0% and needs no backend signer.
- `IMDPhysicalHook` declares `beforeInitialize` and `afterSwap` (exact address mask `0x2040`); no return-delta permissions. Initialization requires the PoolManager given at construction and an explicitly supplied factory sender. It does not bind the pool or enable reactions. Other callback implementations revert if called directly; PoolManager does not call disabled callbacks.
- Nothing here is deployed by this repository or by a job: IMD's verifier attests the source and IMD's deployer launches it through the LaunchFactory. The token, hook and pool addresses, the PoolKey and the poolId exist only after that launch; read them from the launch's `Initialize` event before binding.

## Hook configuration record

The configuration the hook implements, in the shape the OpenZeppelin Wizard's `generate_hook` uses (no generator was run; the Solidity is hand-written on the vendored v4-core interfaces):

```json
{"hook": "BaseHook", "name": "IMDPhysicalHook", "pausable": false, "currencySettler": false, "safeCast": false,
 "transientStorage": false, "shares": {"options": false},
 "permissions": {"beforeInitialize": true, "afterSwap": true, "afterInitialize": false, "beforeAddLiquidity": false,
  "afterAddLiquidity": false, "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false, "beforeSwap": false,
  "beforeDonate": false, "afterDonate": false, "beforeSwapReturnDelta": false, "afterSwapReturnDelta": false,
  "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false},
 "access": "ownable", "info": {"license": "MIT"}}
```

`beforeInitialize` is the launch's required initialization callback (it stops anyone opening the predicted pool before the hook has code and admits only the factory); `afterSwap` observes the signed BalanceDelta for relay 4. The hook takes no fee, so no return-delta permission is enabled and no settlement library is needed. The requested relay semantics (buys ON, sells OFF, 0.05 IMD minimum, 10 s cooldown, 120 s TTL) are the only logic. No remove-liquidity callback exists, so the factory's zero-liquidity fee collect always passes.

## Build

Pinned toolchain: Foundry v1.8.3, Solidity 0.8.26, Cancun, optimizer 200, via IR, metadata bytecode hash none. Dependencies are committed as ordinary source files, not submodules; provenance is in `DEPENDENCIES.json` and each library's license is retained.

```sh
forge build
forge test -vv
```

The integration tests execute upstream PoolManager construction at the canonical address, including its `NoDelegateCall` immutable, and use upstream liquidity/swap settlement routers. They initialize and seed pools, execute exact-input/output swaps in both currency orders, collect LP fees and test whole-transaction rollback. No permission checks are disabled.

The same integration suite can run against the actual Robinhood PoolManager and IMD code on a local fork. Only RPC reads leave the test runner; all transactions and test funding stay in the local EVM:

```sh
IMDIRECTOR_CANONICAL_FORK=true forge test \
  --fork-url https://rpc.mainnet.chain.robinhood.com \
  --match-contract IMDPhysicalHookIntegrationTest -vv
```

## Deployment and activation

Use `launch.json` through IMD Protocol with `onchain: "univ4_hook"`, `chainId: 4663`, `pairWith: "imd"` and explicit `owner`. The hook constructor takes `(IPoolManager poolManager_, address initialOwner, address initialFactory)`, resolved as `$poolManager`, `$owner` and `$factory`; it does not read chain state (the PoolManager is stored, not called, so the constructor also runs on an empty chain in the launch checks). On Robinhood Chain `$poolManager` resolves to the canonical PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951` (verified as `LaunchFactory.poolManager()` on chain 4663). Protocol and device constants compiled into the hook:

- IMD: `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`
- deviceId: `0x696d642d706879736963616c2d726f6f6d2d3100000000000000000000000000`
- relay: 4; command TTL: 120 seconds.

The factory must mine a CREATE2 salt for the exact permission bits and actual constructor data. The nominal manifest price is replaced by the factory's policy-derived opening price, with the actual currency ordering. Initialize and seed the pool while the hook is unbound and disabled. After verifying the real deployment:

1. Owner calls `bindPool` once with the exact initialized PoolKey for this launch's Director/IMD pool. The hook refuses a key the PoolManager has not initialized (`PoolNotInitialized`), so a mistyped key does not consume the one-shot bind; only a pool the factory actually opened on this hook can be bound.
2. Operator configures the external gateway with the verified hook address and poolId and confirms event polling and board readiness.
3. Owner calls `setEnabled(true)`.

Do not perform these owner actions automatically, bind the first public swap or modify the event ABI. Any further compatibility change must be justified with a concrete finding. The original afterSwap-only version was blocked before deployment: its permissions allowed counterfactual initialization and did not satisfy the IMD admission floor. The factory-gated initialization callback and two regression tests address that reproduced issue explicitly. Server-side review, attestation and admission remain necessary.

## Review boundaries

`SPEC.md` and the gateway event ABI are behavioral requirements. Preserve the test cases and assertions during adaptation; add regression tests for legitimate audit findings. Resolve a real incompatibility explicitly rather than weakening assertions. Owner is supplied explicitly and ownership transfer is two-step. One-step `renounceOwnership` is disabled and reverts, so there is always an owner able to call `setEnabled(false)`; the owner key is therefore a trust assumption for stopping commands on chain, and the external gateway remains the physical off switch. Changes made for this launch and the audit findings behind them are listed in `ADAPTATION.md`.

The onchain contract only emits commands. A local, independently operated gateway reads logs, rejects expired/duplicate commands and controls physical relay 4. Relays 1–3 are outside this hook: they toggle on exact ordinary IMD transfers to the installation treasury. The hook never calls hardware, takes funds, verifies physical delivery or identifies a trader from router `sender`.

Command TTL is a delivery deadline, not an automatic switch-off timer. Disabling the hook stops new commands while trading continues; physical stop/off belongs to the operator. L2 inclusion does not guarantee Ethereum finality. A physical action cannot be reverted by an onchain reorg.

The two project contracts and tests are MIT licensed. Vendored Uniswap and other upstream files retain their own SPDX identifiers and licenses, including BUSL-1.1 where applicable.
