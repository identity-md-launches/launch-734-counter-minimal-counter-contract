// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

/// @dev Forwards a call in a static context, where any state change or log must fail.
contract StaticContextCaller {
    function tryStatic(address target, bytes calldata data) external view returns (bool ok, bytes memory ret) {
        (ok, ret) = target.staticcall{gas: 200_000}(data);
    }
}

/// @dev Runs foreign code against its own storage. Its slot 0 lines up with `Counter.count`.
contract ForeignStorage {
    uint256 public slotZero;

    function run(address code, bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = code.delegatecall(data);
    }
}

/// @dev Increments and then fails, so the increment has to be rolled back with the rest of the call.
contract RollbackCaller {
    error RolledBack();

    function incrementThenRevert(Counter counter) external {
        counter.increment();
        revert RolledBack();
    }

    function incrementAroundFailedInner(Counter counter) external {
        counter.increment();
        try this.incrementThenRevert(counter) {} catch {}
        counter.increment();
    }

    function incrementMany(Counter counter, uint256 times) external {
        for (uint256 i; i < times; ++i) {
            counter.increment();
        }
    }
}

/// @dev Pushes its whole balance into `beneficiary` without calling it.
contract EthForcer {
    constructor(address payable beneficiary) payable {
        selfdestruct(beneficiary);
    }
}

/// @dev Stand-in for the project factory: CREATE2 with the factory as `msg.sender`, zero ETH.
/// Returns the zero address on failure instead of reverting so the caller can assert on it.
contract FactoryRehearsal {
    function deploy(bytes memory code, bytes32 salt, uint256 value) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(value, add(code, 32), mload(code), salt)
        }
    }
}

/// @notice Edges the first suite leaves open: hostile call contexts, gas starvation, malformed calldata,
/// forced ETH, the factory deployment path and the shape of the deployed bytecode.
/// forge-config: default.fuzz.runs = 1000
contract CounterAdversarialTest is Test {
    Counter internal counter;

    bytes32 internal constant COUNT_SLOT = bytes32(0);
    bytes4 internal constant INCREMENT_SELECTOR = 0xd09de08a;
    bytes4 internal constant COUNT_SELECTOR = 0x06661abd;
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;
    bytes32 internal constant INCREMENTED_TOPIC = 0x38ac789ed44572701765277c4d0970f2db1c1a571ed39e84358095ae4eaa5420;

    function setUp() public {
        counter = new Counter();
    }

    // ---------------------------------------------------------------- helpers

    function _assertIncrementedLog(Vm.Log memory log, address emitter, address caller, uint256 newCount) internal pure {
        assertEq(log.emitter, emitter, "emitter");
        assertEq(log.topics.length, 2, "topic count");
        assertEq(log.topics[0], INCREMENTED_TOPIC, "event signature");
        assertEq(log.topics[1], bytes32(uint256(uint160(caller))), "indexed caller");
        assertEq(log.data, abi.encode(newCount), "newCount");
    }

    /// @dev solc ends the runtime with INVALID, the CBOR metadata and the metadata's two-byte length.
    /// Only the bytes before that are executable.
    function _executableLength(bytes memory code) internal pure returns (uint256 length) {
        uint256 cborLength = (uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]);
        length = code.length - cborLength - 2;
        assertEq(uint8(code[length - 1]), 0xfe, "metadata separator");
    }

    function _opcodeCounts(bytes memory code) internal pure returns (uint256[256] memory counts) {
        uint256 end = _executableLength(code);
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            ++counts[op];
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
    }

    // ---------------------------------------------------------------- pinned interface

    function test_selectorsAndEventTopicArePinned() public view {
        assertEq(Counter.increment.selector, INCREMENT_SELECTOR);
        assertEq(counter.count.selector, COUNT_SELECTOR);
        assertEq(Counter.Incremented.selector, INCREMENTED_TOPIC);
        assertEq(INCREMENT_SELECTOR, bytes4(keccak256("increment()")));
        assertEq(COUNT_SELECTOR, bytes4(keccak256("count()")));
        assertEq(INCREMENTED_TOPIC, keccak256("Incremented(address,uint256)"));
    }

    function test_countReturnsExactlyOneWord() public {
        counter.increment();
        (bool ok, bytes memory ret) = address(counter).staticcall(abi.encodeWithSelector(COUNT_SELECTOR));
        assertTrue(ok);
        assertEq(ret, abi.encode(uint256(1)));
    }

    // ---------------------------------------------------------------- deployed bytecode

    function test_deployedRuntimeIsTheCompilerArtifact() public view {
        // No immutables and no constructor logic: what is deployed is exactly the compiled runtime.
        assertEq(address(counter).code, type(Counter).runtimeCode);
    }

    /// @dev Every selector a solc dispatcher compares against is a PUSH4 operand. The only ones in the
    /// runtime are the two documented functions and the Panic selector used by the overflow revert, so
    /// there is no hidden setter, owner hook or withdrawal.
    function test_dispatcherExposesOnlyCountAndIncrement() public view {
        bytes memory code = address(counter).code;
        uint256 end = _executableLength(code);
        uint256 countSeen;
        uint256 incrementSeen;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x63) {
                bytes4 operand = bytes4(
                    (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                        | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]))
                );
                if (operand == COUNT_SELECTOR) ++countSeen;
                else if (operand == INCREMENT_SELECTOR) ++incrementSeen;
                else assertEq(operand, PANIC_SELECTOR, "unexpected selector in runtime");
            }
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(countSeen, 1);
        assertEq(incrementSeen, 1);
    }

    /// @dev The review claims "no external calls, no time or origin dependence, one storage write, one
    /// event". Checked on the executable part of the deployed bytecode rather than taken from the source.
    function test_runtimeCannotCallOutMoveEthOrReadTheEnvironment() public view {
        uint256[256] memory counts = _opcodeCounts(address(counter).code);

        // Nothing that transfers control or value, creates code or destroys the contract.
        uint8[7] memory outward = [0xf0, 0xf1, 0xf2, 0xf4, 0xf5, 0xfa, 0xff];
        for (uint256 i; i < outward.length; ++i) {
            assertEq(counts[outward[i]], 0, "outward opcode present");
        }

        // ORIGIN, GASPRICE, BLOCKHASH..BLOBBASEFEE, BALANCE, EXTCODE*, GAS, TLOAD, TSTORE.
        uint8[19] memory environment = [
            0x32,
            0x3a,
            0x40,
            0x41,
            0x42,
            0x43,
            0x44,
            0x45,
            0x46,
            0x47,
            0x48,
            0x49,
            0x4a,
            0x31,
            0x3b,
            0x3c,
            0x3f,
            0x5a,
            0x5c
        ];
        for (uint256 i; i < environment.length; ++i) {
            assertEq(counts[environment[i]], 0, "environment opcode present");
        }
        assertEq(counts[0x5d], 0, "TSTORE present");

        assertEq(counts[0x55], 1, "exactly one SSTORE");
        assertEq(counts[0xa2], 1, "exactly one LOG2");
        assertEq(counts[0xa0] + counts[0xa1] + counts[0xa3] + counts[0xa4], 0, "no other LOG");
        assertEq(counts[0x33], 1, "CALLER read once, for the event");
    }

    // ---------------------------------------------------------------- deployment through a factory

    function testFuzz_factoryCreate2RehearsalOnMainnetChainId(bytes32 salt) public {
        vm.chainId(1);
        address factory = makeAddr("project factory");
        vm.etch(factory, address(new FactoryRehearsal()).code);

        bytes memory initCode = type(Counter).creationCode;
        assertLe(initCode.length, 49_152, "init code exceeds EIP-3860");

        vm.recordLogs();
        address deployed = FactoryRehearsal(factory).deploy(initCode, salt, 0);
        assertEq(vm.getRecordedLogs().length, 0, "constructor must not log");

        assertEq(deployed, vm.computeCreate2Address(salt, keccak256(initCode), factory));
        assertEq(deployed.code, type(Counter).runtimeCode);
        assertLe(deployed.code.length, 24_576, "runtime exceeds EIP-170");
        assertEq(deployed.balance, 0);
        assertEq(Counter(deployed).count(), 0);
        assertEq(vm.load(deployed, COUNT_SLOT), bytes32(0));

        // The factory was msg.sender in the constructor and gained nothing by it: it is one more caller.
        vm.recordLogs();
        vm.prank(factory);
        Counter(deployed).increment();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertIncrementedLog(logs[0], deployed, factory, 1);

        // The same salt cannot be used to redeploy over, or reset, the live counter.
        assertEq(FactoryRehearsal(factory).deploy{gas: 1_000_000}(initCode, salt, 0), address(0));
        assertEq(Counter(deployed).count(), 1);
    }

    function test_factoryCannotFundTheCounterAtDeployment() public {
        address factory = makeAddr("project factory");
        vm.etch(factory, address(new FactoryRehearsal()).code);
        vm.deal(address(this), 1 ether);

        bytes memory initCode = type(Counter).creationCode;
        address deployed = FactoryRehearsal(factory).deploy{value: 1 wei}(initCode, bytes32(0), 1);

        assertEq(deployed, address(0));
        assertEq(vm.computeCreate2Address(bytes32(0), keccak256(initCode), factory).code.length, 0);
    }

    /// @dev Anyone can compute the CREATE2 address and send ETH there before the launch. That must neither
    /// block the deployment nor change the starting state.
    function testFuzz_prefundedAddressStillDeploysAtZero(bytes32 salt, uint96 prefund) public {
        address factory = makeAddr("project factory");
        vm.etch(factory, address(new FactoryRehearsal()).code);
        bytes memory initCode = type(Counter).creationCode;
        address predicted = vm.computeCreate2Address(salt, keccak256(initCode), factory);

        vm.deal(predicted, prefund);
        address deployed = FactoryRehearsal(factory).deploy(initCode, salt, 0);

        assertEq(deployed, predicted);
        assertEq(Counter(deployed).count(), 0);
        assertEq(deployed.balance, prefund);
        Counter(deployed).increment();
        assertEq(Counter(deployed).count(), 1);
        assertEq(deployed.balance, prefund);
    }

    /// @dev There are no constructor arguments, so bytes appended to the init code must be inert.
    function testFuzz_appendedConstructorDataIsInert(bytes calldata junk, bytes32 slot) public {
        bytes memory initCode = abi.encodePacked(type(Counter).creationCode, junk);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(initCode, 32), mload(initCode))
        }
        assertTrue(deployed != address(0));
        assertEq(deployed.code, type(Counter).runtimeCode);
        assertEq(Counter(deployed).count(), 0);
        assertEq(vm.load(deployed, slot), bytes32(0));
    }

    // ---------------------------------------------------------------- hostile call contexts

    function test_incrementInStaticContextFailsAndChangesNothing() public {
        StaticContextCaller prober = new StaticContextCaller();
        counter.increment();

        vm.recordLogs();
        (bool ok,) = prober.tryStatic(address(counter), abi.encodeCall(Counter.increment, ()));

        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(counter.count(), 1);
    }

    function test_countIsReadableInStaticContext() public {
        StaticContextCaller prober = new StaticContextCaller();
        counter.increment();
        (bool ok, bytes memory ret) = prober.tryStatic(address(counter), abi.encodeWithSelector(COUNT_SELECTOR));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    /// @dev Borrowing the counter's code with DELEGATECALL only moves the borrower's own storage and logs
    /// from the borrower's address. The real counter is out of reach.
    function test_delegatecallFromAnotherContractCannotMoveTheCounter() public {
        ForeignStorage foreign = new ForeignStorage();
        counter.increment();

        vm.recordLogs();
        (bool ok,) = foreign.run(address(counter), abi.encodeCall(Counter.increment, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok);
        assertEq(foreign.slotZero(), 1);
        assertEq(logs.length, 1);
        _assertIncrementedLog(logs[0], address(foreign), address(this), 1);
        assertEq(counter.count(), 1, "counter storage moved by a foreign delegatecall");
    }

    function test_revertingOuterCallRollsBackTheIncrementAndItsEvent() public {
        RollbackCaller rollback = new RollbackCaller();
        counter.increment();

        vm.expectRevert(RollbackCaller.RolledBack.selector);
        rollback.incrementThenRevert(counter);

        assertEq(counter.count(), 1);
        assertEq(uint256(vm.load(address(counter), COUNT_SLOT)), 1);

        // The number the rolled-back call would have taken goes to the next caller instead.
        vm.recordLogs();
        counter.increment();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertIncrementedLog(logs[0], address(counter), address(this), 2);
    }

    /// @dev A rolled-back increment leaves no gap: the next successful call reuses its number.
    /// Forge's log recorder also keeps logs from reverted frames, so only the first and the last entry are
    /// asserted; what lies between them belongs to the frame that was undone.
    function test_failedInnerCallLeavesNoGapInTheSequence() public {
        RollbackCaller rollback = new RollbackCaller();

        vm.recordLogs();
        rollback.incrementAroundFailedInner(counter);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(counter.count(), 2);
        assertGe(logs.length, 2);
        _assertIncrementedLog(logs[0], address(counter), address(rollback), 1);
        _assertIncrementedLog(logs[logs.length - 1], address(counter), address(rollback), 2);
    }

    // ---------------------------------------------------------------- gas

    function test_incrementWithTooLittleGasFailsAndChangesNothing() public {
        (bool ok,) = address(counter).call{gas: 5_000}(abi.encodeCall(Counter.increment, ()));
        assertFalse(ok);
        assertEq(counter.count(), 0);
        assertEq(vm.load(address(counter), COUNT_SLOT), bytes32(0));
    }

    /// @dev Whatever gas a caller forwards, the call is all or nothing: never a stored count without its
    /// event, never an event without the stored count.
    function testFuzz_incrementIsAtomicUnderAnyGasLimit(uint256 gasLimit, uint256 start) public {
        gasLimit = bound(gasLimit, 0, 60_000);
        start = bound(start, 0, type(uint256).max - 1);
        vm.store(address(counter), COUNT_SLOT, bytes32(start));

        vm.recordLogs();
        (bool ok,) = address(counter).call{gas: gasLimit}(abi.encodeCall(Counter.increment, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (ok) {
            assertEq(counter.count(), start + 1);
            assertEq(logs.length, 1);
            _assertIncrementedLog(logs[0], address(counter), address(this), start + 1);
        } else {
            assertEq(counter.count(), start);
        }
    }

    /// @dev No loop and no growing structure: the cost does not depend on how large the count already is.
    function testFuzz_incrementGasIsBoundedForAnyCount(uint256 start) public {
        start = bound(start, 0, type(uint256).max - 1);
        vm.store(address(counter), COUNT_SLOT, bytes32(start));

        uint256 gasBefore = gasleft();
        counter.increment();
        uint256 used = gasBefore - gasleft();

        assertLt(used, 60_000);
        assertEq(counter.count(), start + 1);
    }

    // ---------------------------------------------------------------- calldata

    function testFuzz_calldataShorterThanASelectorReverts(bytes4 data, uint256 length, bool useRealPrefix) public {
        length = bound(length, 0, 3);
        if (useRealPrefix) data = length % 2 == 0 ? INCREMENT_SELECTOR : COUNT_SELECTOR;
        bytes memory payload = abi.encodePacked(data);
        assembly ("memory-safe") {
            mstore(payload, length)
        }

        vm.recordLogs();
        (bool ok, bytes memory ret) = address(counter).call(payload);

        assertFalse(ok);
        assertEq(ret.length, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(counter.count(), 0);
    }

    /// @dev Every selector one bit away from a real one must miss the dispatcher.
    function test_selectorsOneBitFromARealOneRevert() public {
        counter.increment();
        for (uint256 bit; bit < 32; ++bit) {
            bytes4 mask = bytes4(uint32(1) << uint32(bit));
            (bool okIncrement,) = address(counter).call(abi.encodePacked(INCREMENT_SELECTOR ^ mask));
            (bool okCount,) = address(counter).call(abi.encodePacked(COUNT_SELECTOR ^ mask));
            assertFalse(okIncrement);
            assertFalse(okCount);
        }
        assertEq(counter.count(), 1);
    }

    /// @dev Solidity does not reject surplus calldata. Extra bytes after the selector must not buy more
    /// than one increment or leak into the event.
    function testFuzz_trailingCalldataBuysExactlyOneIncrement(bytes calldata junk, address caller) public {
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(counter).call(abi.encodePacked(INCREMENT_SELECTOR, junk));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok);
        assertEq(ret.length, 0);
        assertEq(logs.length, 1);
        _assertIncrementedLog(logs[0], address(counter), caller, 1);
        assertEq(counter.count(), 1);
    }

    function testFuzz_trailingCalldataDoesNotChangeTheRead(bytes calldata junk, uint256 stored) public {
        vm.store(address(counter), COUNT_SLOT, bytes32(stored));
        (bool ok, bytes memory ret) = address(counter).staticcall(abi.encodePacked(COUNT_SELECTOR, junk));
        assertTrue(ok);
        assertEq(ret, abi.encode(stored));
    }

    function testFuzz_anyCallCarryingValueReverts(bytes calldata data, uint256 value, uint8 shape) public {
        value = bound(value, 1, type(uint128).max);
        bytes memory payload = data;
        if (shape % 3 == 1) payload = abi.encodePacked(INCREMENT_SELECTOR, data);
        if (shape % 3 == 2) payload = abi.encodePacked(COUNT_SELECTOR, data);
        address sender = makeAddr("payer");
        vm.deal(sender, value);

        vm.recordLogs();
        vm.prank(sender);
        (bool ok,) = address(counter).call{value: value}(payload);

        assertFalse(ok);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(counter.count(), 0);
        assertEq(address(counter).balance, 0);
        assertEq(sender.balance, value);
    }

    // ---------------------------------------------------------------- callers

    function test_unusualCallersAreOrdinaryCallers() public {
        address[7] memory callers = [
            address(0), address(counter), address(1), address(type(uint160).max), block.coinbase, tx.origin, address(vm)
        ];
        for (uint256 i; i < callers.length; ++i) {
            vm.recordLogs();
            vm.prank(callers[i]);
            counter.increment();
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1);
            _assertIncrementedLog(logs[0], address(counter), callers[i], i + 1);
        }
        assertEq(counter.count(), callers.length);
    }

    /// @dev From any starting value, a run of calls by rotating callers produces a gapless, strictly
    /// increasing event sequence with nothing else logged, and the stored count ends at the last event.
    function testFuzz_eventSequenceIsGaplessFromAnyStart(uint256 start, uint256 calls, address[3] calldata who) public {
        calls = bound(calls, 1, 40);
        start = bound(start, 0, type(uint256).max - calls);
        vm.store(address(counter), COUNT_SLOT, bytes32(start));

        vm.recordLogs();
        for (uint256 i; i < calls; ++i) {
            vm.prank(who[i % 3]);
            counter.increment();
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, calls);
        for (uint256 i; i < calls; ++i) {
            _assertIncrementedLog(logs[i], address(counter), who[i % 3], start + i + 1);
        }
        assertEq(counter.count(), start + calls);
    }

    // ---------------------------------------------------------------- environment

    function testFuzz_blockAndTxEnvironmentDoNotMatter(
        uint64 timestamp,
        uint64 number,
        uint64 chain,
        bytes32 randao,
        address coinbase,
        address origin
    ) public {
        counter.increment();

        vm.warp(timestamp);
        vm.roll(number);
        vm.chainId(bound(chain, 1, type(uint64).max));
        vm.prevrandao(randao);
        vm.coinbase(coinbase);

        assertEq(counter.count(), 1);
        address caller = makeAddr("caller");
        vm.recordLogs();
        vm.prank(caller, origin);
        counter.increment();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        _assertIncrementedLog(logs[0], address(counter), caller, 2);
        assertEq(counter.count(), 2);
    }

    // ---------------------------------------------------------------- forced ETH

    /// @dev ETH can be pushed in without a call. It must not move the count, must not block increments,
    /// and (with no outward opcode in the runtime, see above) stays where it is.
    function testFuzz_forcedEthNeitherMovesNorBlocksTheCount(uint96 amount, uint8 calls) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        vm.deal(address(this), amount);
        counter.increment();

        new EthForcer{value: amount}(payable(address(counter)));

        assertEq(address(counter).balance, amount);
        assertEq(counter.count(), 1);
        for (uint256 i; i < calls; ++i) {
            counter.increment();
        }
        assertEq(counter.count(), uint256(calls) + 1);
        assertEq(address(counter).balance, amount);
    }

    // ---------------------------------------------------------------- storage

    function testFuzz_onlySlotZeroIsEverWritten(bytes32 slot, uint8 calls, address caller) public {
        if (slot == COUNT_SLOT) slot = bytes32(uint256(1));
        for (uint256 i; i < calls; ++i) {
            vm.prank(caller);
            counter.increment();
        }
        assertEq(vm.load(address(counter), slot), bytes32(0));
        assertEq(uint256(vm.load(address(counter), COUNT_SLOT)), calls);
    }

    // ---------------------------------------------------------------- overflow boundary

    function test_lastIncrementSucceedsThenEveryCallerIsRejectedWithPanic() public {
        vm.store(address(counter), COUNT_SLOT, bytes32(type(uint256).max - 1));

        vm.recordLogs();
        counter.increment();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        _assertIncrementedLog(logs[0], address(counter), address(this), type(uint256).max);

        address[3] memory callers = [address(this), makeAddr("late caller"), address(0)];
        for (uint256 i; i < callers.length; ++i) {
            vm.recordLogs();
            vm.prank(callers[i]);
            (bool ok, bytes memory ret) = address(counter).call(abi.encodeCall(Counter.increment, ()));
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(PANIC_SELECTOR, uint256(0x11)));
            assertEq(vm.getRecordedLogs().length, 0);
        }
        assertEq(counter.count(), type(uint256).max);
    }

    /// @dev A batch that would cross the maximum fails as a whole: the increments that fit are undone too.
    function testFuzz_batchCrossingTheMaximumRevertsAtomically(uint256 room, uint256 times) public {
        room = bound(room, 0, 8);
        times = bound(times, room + 1, room + 8);
        uint256 start = type(uint256).max - room;
        vm.store(address(counter), COUNT_SLOT, bytes32(start));
        RollbackCaller batcher = new RollbackCaller();

        (bool ok,) =
            address(batcher).call{gas: 1_000_000}(abi.encodeCall(RollbackCaller.incrementMany, (counter, times)));

        assertFalse(ok);
        assertEq(counter.count(), start);

        // The room that was there is still usable afterwards.
        batcher.incrementMany(counter, room);
        assertEq(counter.count(), type(uint256).max);
    }
}
