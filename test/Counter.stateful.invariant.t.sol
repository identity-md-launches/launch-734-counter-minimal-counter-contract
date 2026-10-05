// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

/// @dev A contract caller: batches increments, and can fail after incrementing.
contract RelayActor {
    error RolledBack();

    function incrementMany(Counter counter, uint256 times) external {
        for (uint256 i; i < times; ++i) {
            counter.increment();
        }
    }

    function incrementThenRevert(Counter counter) external {
        counter.increment();
        revert RolledBack();
    }

    function tryStatic(address target, bytes calldata data) external view returns (bool ok) {
        (ok,) = target.staticcall{gas: 200_000}(data);
    }
}

/// @dev Borrows the counter's code against its own storage.
contract BorrowedCodeActor {
    uint256 public slotZero;

    function run(address code, bytes calldata data) external returns (bool ok) {
        (ok,) = code.delegatecall(data);
    }
}

/// @dev Pushes its whole balance into `beneficiary` without calling it.
contract ForcedEthSender {
    constructor(address payable beneficiary) payable {
        selfdestruct(beneficiary);
    }
}

/// @dev Drives one counter with several actors through every way of reaching it, valid or not, and keeps
/// an independent ledger of what should have happened. Per-call properties are asserted here; the global
/// ones are the invariants below. No action may revert (`fail_on_revert` is on).
contract CounterActorHandler is Test {
    Counter public immutable counter;
    /// @dev A second deployment that must be unaffected by, and must not affect, the first.
    Counter public immutable other;
    RelayActor public immutable relay;
    BorrowedCodeActor public immutable borrower;

    bytes32 internal constant INCREMENTED_TOPIC = keccak256("Incremented(address,uint256)");

    address[] internal actors;

    // ---- ledger
    uint256 public ghost_increments;
    uint256 public ghost_otherIncrements;
    uint256 public ghost_events;
    uint256 public ghost_lastEventCount;
    address public ghost_lastEventCaller;
    uint256 public ghost_forcedEth;
    uint256 public ghost_rejectedCalls;
    uint256 public ghost_decreases;
    mapping(address => uint256) public ghost_incrementsBy;
    address[] internal ghost_callers;
    mapping(address => bool) internal ghost_seen;

    constructor(Counter counter_, Counter other_) {
        counter = counter_;
        other = other_;
        relay = new RelayActor();
        borrower = new BorrowedCodeActor();
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(address(0));
    }

    /// @dev The count may only ever go up across one action.
    modifier step() {
        uint256 pre = counter.count();
        _;
        if (counter.count() < pre) ++ghost_decreases;
    }

    function callersLength() external view returns (uint256) {
        return ghost_callers.length;
    }

    function callerAt(uint256 i) external view returns (address) {
        return ghost_callers[i];
    }

    // ---------------------------------------------------------------- internals

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _startRecording() internal {
        vm.recordLogs();
        vm.getRecordedLogs();
    }

    function _credit(address caller, uint256 newCount) internal {
        ++ghost_increments;
        ++ghost_events;
        ghost_lastEventCount = newCount;
        ghost_lastEventCaller = caller;
        ++ghost_incrementsBy[caller];
        if (!ghost_seen[caller]) {
            ghost_seen[caller] = true;
            ghost_callers.push(caller);
        }
    }

    /// @dev Checks the logs of `times` successful increments by `caller` starting after `pre`.
    function _settle(Vm.Log[] memory logs, address caller, uint256 pre, uint256 times) internal {
        assertEq(logs.length, times, "one log per increment, nothing else");
        for (uint256 i; i < times; ++i) {
            assertEq(logs[i].emitter, address(counter), "emitter");
            assertEq(logs[i].topics.length, 2, "topic count");
            assertEq(logs[i].topics[0], INCREMENTED_TOPIC, "event signature");
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(caller))), "indexed caller");
            assertEq(logs[i].data, abi.encode(pre + i + 1), "newCount");
            _credit(caller, pre + i + 1);
        }
        assertEq(counter.count(), pre + times, "count after increments");
    }

    function _incrementAs(address caller) internal {
        uint256 pre = counter.count();
        _startRecording();
        vm.prank(caller);
        counter.increment();
        _settle(vm.getRecordedLogs(), caller, pre, 1);
    }

    function _expectUnchanged(uint256 pre) internal {
        assertEq(counter.count(), pre, "rejected call moved the count");
        ++ghost_rejectedCalls;
    }

    // ---------------------------------------------------------------- valid paths

    function increment(uint256 actorSeed) external step {
        _incrementAs(_actor(actorSeed));
    }

    function incrementAsAnyone(address caller) external step {
        _incrementAs(caller);
    }

    function incrementBurst(uint256 actorSeed, uint256 times) external step {
        address caller = _actor(actorSeed);
        times = bound(times, 2, 12);
        for (uint256 i; i < times; ++i) {
            _incrementAs(caller);
        }
    }

    function incrementThroughRelay(uint256 actorSeed, uint256 times) external step {
        times = bound(times, 0, 12);
        uint256 pre = counter.count();
        _startRecording();
        vm.prank(_actor(actorSeed));
        relay.incrementMany(counter, times);
        // The relay is msg.sender for the counter, whoever asked the relay.
        _settle(vm.getRecordedLogs(), address(relay), pre, times);
    }

    /// @dev Forwards an arbitrary amount of gas: the call either fully happens or fully does not.
    function incrementWithLimitedGas(uint256 gasLimit) external step {
        gasLimit = bound(gasLimit, 0, 40_000);
        uint256 pre = counter.count();
        _startRecording();
        (bool ok,) = address(counter).call{gas: gasLimit}(abi.encodeCall(Counter.increment, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (ok) _settle(logs, address(this), pre, 1);
        else _expectUnchanged(pre);
    }

    // ---------------------------------------------------------------- rejected paths

    function incrementThenRevert(uint256 actorSeed) external step {
        uint256 pre = counter.count();
        vm.prank(_actor(actorSeed));
        try relay.incrementThenRevert(counter) {
            assertTrue(false, "relay did not revert");
        } catch {}
        _expectUnchanged(pre);
    }

    function incrementInStaticContext() external step {
        uint256 pre = counter.count();
        assertFalse(relay.tryStatic(address(counter), abi.encodeCall(Counter.increment, ())), "static increment");
        _expectUnchanged(pre);
    }

    /// @dev A foreign contract running the counter's code moves its own slot 0, never the counter's.
    function incrementBorrowedCode(uint256 times) external step {
        times = bound(times, 1, 4);
        uint256 pre = counter.count();
        uint256 foreignPre = borrower.slotZero();
        for (uint256 i; i < times; ++i) {
            assertTrue(borrower.run(address(counter), abi.encodeCall(Counter.increment, ())), "delegatecall");
        }
        assertEq(borrower.slotZero(), foreignPre + times, "borrower storage");
        _expectUnchanged(pre);
    }

    function sendValue(uint256 actorSeed, uint256 amount, uint256 shape, bytes calldata extra) external step {
        address sender = _actor(actorSeed);
        amount = bound(amount, 1, type(uint96).max);
        shape = bound(shape, 0, 3);
        bytes memory payload;
        if (shape == 1) payload = abi.encodeCall(Counter.increment, ());
        if (shape == 2) payload = abi.encodeWithSelector(counter.count.selector);
        if (shape == 3) payload = extra;

        uint256 pre = counter.count();
        uint256 held = address(counter).balance;
        vm.deal(sender, amount);
        vm.prank(sender);
        (bool ok,) = address(counter).call{value: amount}(payload);

        assertFalse(ok, "call carrying value accepted");
        assertEq(sender.balance, amount, "sender lost ETH on a rejected call");
        assertEq(address(counter).balance, held, "counter balance moved by a call");
        _expectUnchanged(pre);
    }

    function callUnknown(uint256 actorSeed, bytes calldata data) external step {
        bytes memory payload = data;
        if (payload.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            // Turn the two real selectors into near misses instead of discarding the run.
            if (selector == Counter.increment.selector || selector == counter.count.selector) {
                payload[3] = payload[3] ^ 0x01;
            }
        }
        uint256 pre = counter.count();
        vm.prank(_actor(actorSeed));
        (bool ok,) = address(counter).call(payload);
        assertFalse(ok, "unknown calldata accepted");
        _expectUnchanged(pre);
    }

    // ---------------------------------------------------------------- environment

    /// @dev ETH arriving without a call (SELFDESTRUCT beneficiary). Allowed to land, not allowed to matter.
    function forceEth(uint256 amount) external step {
        amount = bound(amount, 1, 100 ether);
        uint256 pre = counter.count();
        vm.deal(address(this), amount);
        new ForcedEthSender{value: amount}(payable(address(counter)));
        ghost_forcedEth += amount;
        assertEq(counter.count(), pre, "forced ETH moved the count");
    }

    function incrementOther(uint256 actorSeed) external step {
        uint256 pre = counter.count();
        vm.prank(_actor(actorSeed));
        other.increment();
        ++ghost_otherIncrements;
        assertEq(counter.count(), pre, "another deployment moved the count");
    }

    function passTime(uint256 secondsForward, uint256 blocksForward) external step {
        uint256 pre = counter.count();
        vm.warp(block.timestamp + bound(secondsForward, 1, 365 days));
        vm.roll(block.number + bound(blocksForward, 1, 1_000_000));
        assertEq(counter.count(), pre, "time moved the count");
    }
}

/// @notice Invariants over random call sequences by several actors, mixing valid and rejected calls.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract CounterStatefulInvariantTest is Test {
    Counter internal counter;
    Counter internal other;
    CounterActorHandler internal handler;
    bytes32 internal runtimeHash;

    function setUp() public {
        counter = new Counter();
        other = new Counter();
        handler = new CounterActorHandler(counter, other);
        runtimeHash = address(counter).codehash;
        targetContract(address(handler));
    }

    /// @dev Nothing but a successful increment moves the count, and each moves it by exactly one.
    function invariant_countEqualsSuccessfulIncrements() public view {
        assertEq(counter.count(), handler.ghost_increments());
    }

    /// @dev Conservation across callers: the shared count is the sum of what each caller's events account
    /// for. No increment is lost, double counted or attributed to nobody.
    function invariant_countEqualsSumOfPerCallerIncrements() public view {
        uint256 sum;
        uint256 length = handler.callersLength();
        for (uint256 i; i < length; ++i) {
            sum += handler.ghost_incrementsBy(handler.callerAt(i));
        }
        assertEq(sum, counter.count());
    }

    /// @dev One event per unit of count, and the latest event always carries the current count.
    function invariant_eventsTrackTheCount() public view {
        assertEq(handler.ghost_events(), counter.count());
        assertEq(handler.ghost_lastEventCount(), counter.count());
    }

    function invariant_countNeverDecreases() public view {
        assertEq(handler.ghost_decreases(), 0);
    }

    /// @dev The only ETH the contract can ever hold is ETH forced into it; no call adds to or removes it.
    function invariant_balanceIsExactlyForcedEth() public view {
        assertEq(address(counter).balance, handler.ghost_forcedEth());
    }

    /// @dev The count lives in slot 0 and nothing else is ever written.
    function invariant_onlySlotZeroIsUsed() public view {
        assertEq(uint256(vm.load(address(counter), bytes32(0))), counter.count());
        assertEq(vm.load(address(counter), bytes32(uint256(1))), bytes32(0));
        assertEq(vm.load(address(counter), bytes32(uint256(2))), bytes32(0));
        assertEq(vm.load(address(counter), keccak256(abi.encode(uint256(0)))), bytes32(0));
        assertEq(vm.load(address(counter), bytes32(type(uint256).max)), bytes32(0));
    }

    /// @dev No sequence destroys or replaces the code.
    function invariant_codeIsImmutable() public view {
        assertEq(address(counter).codehash, runtimeHash);
    }

    function invariant_deploymentsAreIndependent() public view {
        assertEq(other.count(), handler.ghost_otherIncrements());
        assertEq(address(other).balance, 0);
    }

    /// @dev Liveness: whatever happened during the sequence, a fresh caller can still increment and read.
    function afterInvariant() public {
        uint256 pre = counter.count();
        vm.prank(makeAddr("latecomer"));
        counter.increment();
        assertEq(counter.count(), pre + 1);
    }
}

/// @dev Drives a counter that starts a few steps below the maximum, so sequences run into the overflow
/// guard. Every call is predicted from the pre-state: it must succeed while there is room and must revert
/// with Panic(0x11), changing nothing, once there is none.
contract CounterCeilingHandler is Test {
    Counter public immutable counter;
    RelayActor public immutable relay;
    uint256 public immutable start;

    uint256 public ghost_successes;
    uint256 public ghost_panics;
    uint256 public ghost_atomicBatchFailures;
    bool public ghost_reachedMax;
    bool public ghost_leftMax;

    constructor(Counter counter_, uint256 start_) {
        counter = counter_;
        start = start_;
        relay = new RelayActor();
    }

    modifier step() {
        _;
        uint256 current = counter.count();
        if (ghost_reachedMax && current != type(uint256).max) ghost_leftMax = true;
        if (current == type(uint256).max) ghost_reachedMax = true;
    }

    function tryIncrement(address caller) external step {
        uint256 pre = counter.count();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(counter).call(abi.encodeCall(Counter.increment, ()));
        if (pre < type(uint256).max) {
            assertTrue(ok, "increment failed with room left");
            assertEq(counter.count(), pre + 1);
            ++ghost_successes;
        } else {
            assertFalse(ok, "increment succeeded at the maximum");
            assertEq(ret, abi.encodeWithSignature("Panic(uint256)", uint256(0x11)), "revert reason");
            assertEq(counter.count(), type(uint256).max, "count moved at the maximum");
            ++ghost_panics;
        }
    }

    /// @dev A batch through a contract: all of it or none of it, even when only the last step overflows.
    function tryBatch(uint256 times) external step {
        times = bound(times, 1, 6);
        uint256 pre = counter.count();
        uint256 room = type(uint256).max - pre;
        (bool ok,) = address(relay).call{gas: 1_000_000}(abi.encodeCall(RelayActor.incrementMany, (counter, times)));
        if (times <= room) {
            assertTrue(ok, "batch failed with room left");
            assertEq(counter.count(), pre + times);
            ghost_successes += times;
        } else {
            assertFalse(ok, "batch crossed the maximum");
            assertEq(counter.count(), pre, "partial batch survived a revert");
            ++ghost_atomicBatchFailures;
        }
    }

    function readCount() external step {
        // The read must stay available in every state, including the saturated one.
        (bool ok, bytes memory ret) = address(counter).staticcall(abi.encodeWithSelector(counter.count.selector));
        assertTrue(ok, "count() reverted");
        assertEq(ret.length, 32);
    }
}

/// @notice Invariants at the overflow boundary: the count never wraps and the saturated state is final.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
contract CounterCeilingInvariantTest is Test {
    uint256 internal constant ROOM = 24;
    uint256 internal constant START = type(uint256).max - ROOM;

    Counter internal counter;
    CounterCeilingHandler internal handler;

    function setUp() public {
        counter = new Counter();
        // Reaching this state through calls would take 2^256 transactions, so it is written directly.
        vm.store(address(counter), bytes32(0), bytes32(START));
        handler = new CounterCeilingHandler(counter, START);
        targetContract(address(handler));
    }

    /// @dev Never wraps: the count is the start plus the successful increments, and those fit in the room.
    function invariant_countNeverWraps() public view {
        assertLe(handler.ghost_successes(), ROOM);
        assertEq(counter.count(), START + handler.ghost_successes());
    }

    /// @dev A panic is only ever seen once the count is at the maximum.
    function invariant_panicsOnlyAtTheMaximum() public view {
        if (handler.ghost_panics() > 0) assertEq(counter.count(), type(uint256).max);
    }

    /// @dev A finished state never reopens.
    function invariant_saturationIsFinal() public view {
        assertFalse(handler.ghost_leftMax());
        if (handler.ghost_reachedMax()) assertEq(counter.count(), type(uint256).max);
    }

    function invariant_holdsNoEthAtTheBoundary() public view {
        assertEq(address(counter).balance, 0);
    }
}
