# IMDPhysicalHook behavioral contract

These requirements bind the supplied source, tests, launch adaptation and external gateway. The production contract has no upgrade path or alternate execution module.

1. Only the canonical Robinhood PoolManager may call the active `afterSwap` callback. Hook address bits and `getHookPermissions()` agree on only `afterSwap`, mask `0x0040`. Return the callback selector and zero delta; take no funds and do not alter LP fees or swap accounting.
2. Initially `enabled=false`, `poolBound=false`, `lastCommandId=0`, `lastTriggerAt=0`. Only the explicit owner can bind once. Binding requires this hook, sorted distinct nonzero currencies and exactly one IMD side. Save the complete key and its canonical poolId. Public initialization or swaps cannot choose the bound pool.
3. Enabling requires binding. Disabled, unbound and foreign-pool swaps succeed without relay events. Disabled callbacks have no permission bits. No pause modifier may revert an ordinary swap merely because physical reactions are disabled.
4. Read actual IMD and opposite-currency deltas, independent of currency ordering, `amountSpecified`, router sender and hookData. IMD negative / other positive is a buy; IMD positive / other negative is a sell. Zero and same-sign pairs are ignored. Negate an int128 only after widening to int256, including int128.min.
5. Initial rule: fixed relay 4, buyState=true, sellState=false, minimum IMD amount=50000000000000000, cooldown=10 seconds. Owner may update only buy/sell states, positive threshold and uint32 cooldown; zero cooldown disables rate limiting. Rule updates and enable/disable do not reset the last emission timestamp.
6. Inclusive threshold and cooldown boundary. First eligible swap emits immediately, including timestamp zero. Cooldown is global to the bound pool. Skips never advance timestamp or command ID. Accepted commands have consecutive IDs starting at 1, relay 4, actual absolute IMD delta, correct buy/sell and desired state, and expiresAt=block.timestamp+120. Entire-transaction reverts roll back state and events.
7. This exact event, including types, field order and indexed positions, is the gateway ABI:

```solidity
event RelayTriggered(uint256 indexed commandId, bytes32 indexed deviceId, bytes32 indexed poolId, uint8 relay, bool desiredState, uint256 imdAmount, bool isBuy, uint256 expiresAt);
```

8. Required gateway getters are `imdToken() returns (address)`, `deviceId() returns (bytes32)`, `poolId() returns (bytes32)`. Owner/pendingOwner, complete pool key, enabled state, rule, last ID, last emission time and TTL are public. Device ID and relay cannot be changed by the owner. `RuleUpdated`, `EnabledUpdated` and complete `PoolBound` data are emitted.
9. Ownership is explicit, never inferred from the deploying factory, and transfer requires the pending owner's acceptance. No external mint, transfer tax, funds withdrawal, arbitrary call, signer, oracle, proxy or gateway/network/hardware call is part of this hook.
10. Acceptance requires real PoolManager integration with liquidity and successful swaps, not only mock callback invocations. Test exact input/output and either IMD ordering, safe skips, LP fee collection, foreign-pool behavior and revert rollback. The local fork mode keeps canonical deployed PoolManager and IMD bytecode intact.
