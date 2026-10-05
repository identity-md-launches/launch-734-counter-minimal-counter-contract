# Security notes for Counter

**Status: author self-review only. The independent security review the brief requires before deployment has
not been done and remains open.** These notes were written by the same contributor who wrote the contract and
tests, so they carry no independent authority. They are here to give the independent reviewer a starting point
and a list of things to try to break.

Scope: `src/Counter.sol` at solc 0.8.26, optimizer 200 runs, `evm_version = cancun`, `bytecode_hash = none`.

## Attack surface

- One storage slot (`count`, slot 0).
- Two external entry points: `count()` (view) and `increment()` (nonpayable, permissionless).
- No constructor logic or arguments, no `receive`, no `fallback`, no payable function.
- No external calls, no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, no assembly, no inheritance, no libraries.

## Checklist walk-through

| Area | Result |
| --- | --- |
| Access control | Nothing is privileged. `increment()` is open to everyone by design; there is no owner, admin, pause, upgrade, mint, sweep or fee function to protect. |
| Reentrancy | Not applicable: the contract makes no external call, so there is no point at which control leaves it. |
| Value in and out | The contract accepts no ETH through any call and has no token logic, so there is nothing to conserve, round or withdraw. |
| Arithmetic | One checked `count + 1`. It reverts with `Panic(0x11)` at `type(uint256).max` and leaves state unchanged (tested). No `unchecked`, no casts, no division. |
| Loops and gas | No loops, no arrays, no batching. `increment()` cost is constant. |
| Time, ordering, randomness | No use of `block.timestamp`, `block.number`, `blockhash` or `prevrandao`. Ordering only decides which caller receives which `newCount`; see "Accepted properties". |
| Signatures and identity | No signatures, no `ecrecover`, no `tx.origin`. The event records `msg.sender` (tested against a differing `tx.origin`). |
| External dependencies | None: no oracle, no token, no proxy, no upgradeability, no inherited code. |
| Input validation | Neither function takes arguments. Unknown selectors and calls carrying ETH revert (fuzzed). |
| Events | The only state change emits `Incremented` exactly once, with the caller indexed and the post-increment count (tested at topic and data level). |
| Deployment shape | Runtime is roughly 200 bytes with no forbidden opcodes (tested); the constructor is nonpayable (tested). |

No defects were found in this self-review.

## Accepted properties (by design, not defects)

- **Anyone can inflate the count.** There is no rate limit or per-caller cap, which is what the brief asks for.
  The count is therefore not a sybil-resistant or economically meaningful number.
- **`newCount` is ordering dependent.** A block builder or a front-runner can decide who gets a given count.
  This only matters if something off-chain attaches value to a specific count; nothing on-chain does.
- **Forced ETH is stuck.** ETH pushed in without a call (for example as a `SELFDESTRUCT` beneficiary or a fee
  recipient) and tokens sent to the address cannot be recovered. It cannot affect the count.
- **Immutable.** No pause, upgrade or kill switch. A defect found after deployment can only be handled by
  deploying a new contract.

## What ran and what did not

- Ran: `forge build`, `forge test` (unit, fuzz at 256 runs, invariant at 64 runs x depth 64), `forge fmt --check`.
- Not run: Slither, Mythril or any other static analyser or symbolic tool (none was provided for this task),
  and no long fuzz campaign.

## Open items before deployment

1. Independent security review of `src/Counter.sol`, the tests and the launch manifest by a contributor other
   than the author.
2. The manifest (`launch.json`) is written by a separate step. It should contain a single `Counter` entry with
   empty `constructorArgs` and no `$owner`.
3. After deployment, the deployer should confirm the deployed runtime matches this build and verify the source
   on a block explorer.

## Edges the tests do not cover

- Forced-ETH delivery (`SELFDESTRUCT` beneficiary, fee recipient) is described above but not simulated.
- Behaviour on chains or forks other than the configured `cancun` EVM target is not tested.
- The protected deployment rehearsal (CREATE2 through the project factory with its real salt and address
  prediction) runs outside this repository; the local suite only rehearses a generic CREATE2 deployment.
