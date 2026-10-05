# Counter

A minimal, permissionless counter for Ethereum mainnet. Contracts only: no token, no distributor, no pool.

## Behaviour

`src/Counter.sol` is the whole application.

| Member | Kind | Behaviour |
| --- | --- | --- |
| `count()` | view | Returns the current count. Starts at `0`. |
| `increment()` | nonpayable | Adds exactly one to the count and emits `Incremented(msg.sender, newCount)`. |
| `Incremented(address indexed caller, uint256 newCount)` | event | One per successful `increment()`. `newCount` is the value after the increment. |

There is nothing else: no owner, no admin or privileged function, no fee, no decrement, reset or setter, no
`receive`, no `fallback`, no payable function, no external calls, no upgrade path, and no constructor arguments.

Failure cases:

- Sending ETH with any call (including `increment()`, `count()`, or empty calldata) reverts.
- Any unknown selector reverts.
- `increment()` at `type(uint256).max` reverts with `Panic(0x11)` rather than wrapping. This is unreachable in
  practice (2^256 transactions).

## Assumptions

- `caller` in the event is `msg.sender`, the immediate caller. When a contract, a smart account or a relayer
  calls `increment()`, the event records that contract, not the externally owned account that signed.
- The count is global and shared by everyone. It says how many times `increment()` succeeded and nothing about
  who called, how many distinct callers there were, or whether callers are distinct people. Anyone can raise it
  by any amount at the cost of gas, so it must not be used as a vote, a measure of demand, a uniqueness or
  sybil signal, or a source of randomness.
- The `newCount` a particular transaction receives depends on transaction ordering within a block, which the
  block builder controls. Nothing of value should depend on obtaining a specific count.
- The contract holds no funds and has no way to move funds. ETH can still be forced into any address without
  calling it (for example as a `SELFDESTRUCT` beneficiary or a block fee recipient). ETH forced in that way, and
  any token sent to the address, is permanently unrecoverable because there is no withdrawal function. This has
  no effect on the count.
- The count can never decrease and the contract cannot be paused, upgraded or destroyed. A mistake cannot be
  corrected after deployment; a fix means deploying a new contract at a new address.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Network | Ethereum mainnet (chain id 1) |
| Launch kind | `evm_contracts` |
| Contracts | `Counter` (one) |
| Constructor arguments | none |
| ETH sent at deployment | 0 (constructor is nonpayable) |
| Owner / admin | none; no `$owner` argument is needed or used |
| Compiler | solc `0.8.26` (pinned in `foundry.toml`, exact pragma in source) |
| EVM version | `cancun` |
| Optimizer | enabled, 200 runs |
| Metadata | `bytecode_hash = "none"` |
| Dependencies at runtime | none (forge-std is used by tests only) |

Expected manifest entry, to be written by the separate manifest step (this repository does not write
`launch.json`):

```json
{ "contract": "Counter", "constructorArgs": [] }
```

The runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` and is far below the EIP-170
size limit; `test/Counter.t.sol` checks this.

There is no deploy script. Deployment goes through the project factory, and nothing here reads keys,
broadcasts or sends transactions.

## Operational responsibilities

There is no operator role on chain, so the responsibilities are all around the deployment:

- **Deployer / launch service:** deploy the bytecode built from this commit with the settings above, confirm
  the deployed runtime matches the build, and verify the source on a block explorer with the same compiler
  settings. Publish the confirmed address; nobody should derive or invent one.
- **Integrators and front ends:** read `count()` and index `Incremented` from the confirmed address only, and
  respect the assumptions above (in particular `caller` is `msg.sender`, and the count is not a uniqueness
  signal).
- **Nobody** needs to hold keys, monitor, pause, or maintain the contract after deployment, and nobody can.

## Security review status

`SECURITY.md` records the author's self-review against the security checklist supplied with the task. It is
not the independent review. The brief requires an independent security review before deployment, which must be
done by someone other than the author and is still open.

## Development

```sh
forge build
forge test
forge fmt --check
```

Tests need no environment variables, no network and no `ffi`, and are independent of order.

- `test/Counter.t.sol` covers the initial state, increment, the event (topics, data, emitter, exactly one log),
  many and arbitrary callers, and the failure paths (ETH rejected on every entry point, unknown selectors,
  absent admin functions, overflow, nonpayable constructor), plus the deployed-bytecode shape.
- `test/Counter.invariant.t.sol` checks under random call sequences that the count always equals the number of
  successful increments and that no call path leaves ETH in the contract.

`lib/forge-std-1.9.7/` is forge-std v1.9.7 (`src/` and licences only), vendored as ordinary files so the
project builds offline. It is mapped to `forge-std/` in `remappings.txt`.
