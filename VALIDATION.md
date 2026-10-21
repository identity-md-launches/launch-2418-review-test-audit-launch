# Validation before IMD admission

2026-10-21. No real transaction has been broadcast.

- Foundry v1.8.3 (`cae51ad458f6abb64852b7709eb784352429825d`), official macOS arm64 binary archive SHA-256 `562f9c2f9094e512f1efc1e005c79de7642c27ffc1e7e9dcf8e31baa54577d6e` matched the GitHub release digest.
- Solidity 0.8.26 official macOS compiler SHA-256 `0ff016aef2396b12d1fc65429d8ea6cf53c2ee4b041bb8925644615ee1c30ab9` matched ethereum/solc-bin metadata. Solidity compilation succeeded.
- Full local suite: **28 passed, 0 failed, 0 skipped**, including 512 fuzz runs over actual amount, buy/sell and IMD currency ordering.
- Canonical Robinhood fork: **8 passed, 0 failed, 0 skipped**, starting at block 94505041. Actual deployed PoolManager and IMD bytecode remain intact in this mode. Test balances, test coins, hooks and pools exist only in the local fork. No RPC writes or real funds were used.
- Exact-input and exact-output buy/sell work with IMD as either currency. Unbound/disabled, threshold and cooldown swaps continue successfully without commands. Foreign initialization and swaps do not capture binding. Entire-swap rollback clears the command. Zero-liquidity LP fee collection succeeds.
- Owner restrictions, two-step transfer, one-time binding, int128 minimum, timestamp-zero first reaction and exact event ABI are covered.
- Measured `afterSwap` external-call gas in the local gas report: maximum **80,253** in the exercised cases. This is a measurement, not a guarantee for arbitrary execution environments.
- Hook runtime: 4,455 bytes; creation code: 5,132 bytes before the 32-byte owner argument. Correct address flags are validated in the production constructor and exercised by real CREATE2 deployments in tests.

The test suite does not call the live LaunchFactory's authorized deployment entry point. IMD must still review its manifest, attest the supplied source, mine its deployment salt and execute its normal protected admission tests. Report a real factory incompatibility; do not silently alter SPEC.md or physical gateway behavior.

The local Foundry preprocessor emits a Solar warning about the indirect `Ownable` constructor; the pinned Solidity compiler successfully compiles the standard `Ownable2Step`/`Ownable(initialOwner)` form, and all execution tests pass. This warning did not replace or suppress compiler errors.
