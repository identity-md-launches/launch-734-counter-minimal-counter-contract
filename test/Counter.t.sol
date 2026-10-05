// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {Counter} from "../src/Counter.sol";

/// @dev Calls back into the counter from inside one outer call, to show nesting is harmless.
contract NestedCaller {
    function incrementTwice(Counter counter) external {
        counter.increment();
        counter.increment();
    }
}

contract CounterTest is Test {
    event Incremented(address indexed caller, uint256 newCount);

    Counter internal counter;

    /// @dev `count` is the only state variable, so it lives in storage slot 0.
    bytes32 internal constant COUNT_SLOT = bytes32(0);

    function setUp() public {
        counter = new Counter();
    }

    // ---------------------------------------------------------------- initial state

    function test_countStartsAtZero() public view {
        assertEq(counter.count(), 0);
    }

    function test_countIsStoredInSlotZero() public {
        counter.increment();
        assertEq(uint256(vm.load(address(counter), COUNT_SLOT)), 1);
    }

    function test_holdsNoFundsAfterDeployment() public view {
        assertEq(address(counter).balance, 0);
    }

    // ---------------------------------------------------------------- increment

    function test_incrementAddsOne() public {
        counter.increment();
        assertEq(counter.count(), 1);
    }

    function test_incrementTwiceAddsTwo() public {
        counter.increment();
        counter.increment();
        assertEq(counter.count(), 2);
    }

    function test_incrementReturnsNoData() public {
        (bool ok, bytes memory ret) = address(counter).call(abi.encodeCall(Counter.increment, ()));
        assertTrue(ok);
        assertEq(ret.length, 0);
    }

    function test_countIsAViewAndDoesNotChangeState() public {
        counter.increment();
        vm.record();
        counter.count();
        (, bytes32[] memory writes) = vm.accesses(address(counter));
        assertEq(writes.length, 0);
        assertEq(counter.count(), 1);
    }

    function test_incrementWritesOnlyTheCountSlot() public {
        vm.record();
        counter.increment();
        (, bytes32[] memory writes) = vm.accesses(address(counter));
        assertEq(writes.length, 1);
        assertEq(writes[0], COUNT_SLOT);
    }

    function testFuzz_incrementFromAnyStartingValue(uint256 start) public {
        start = bound(start, 0, type(uint256).max - 1);
        vm.store(address(counter), COUNT_SLOT, bytes32(start));

        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(address(this), start + 1);
        counter.increment();

        assertEq(counter.count(), start + 1);
    }

    function testFuzz_countEqualsNumberOfCalls(uint8 calls) public {
        for (uint256 i; i < calls; ++i) {
            counter.increment();
        }
        assertEq(counter.count(), calls);
    }

    function test_canReachMaxValue() public {
        vm.store(address(counter), COUNT_SLOT, bytes32(type(uint256).max - 1));
        counter.increment();
        assertEq(counter.count(), type(uint256).max);
    }

    // ---------------------------------------------------------------- event

    function test_incrementEmitsEventWithCallerAndNewCount() public {
        address caller = makeAddr("caller");

        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(caller, 1);
        vm.prank(caller);
        counter.increment();

        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(caller, 2);
        vm.prank(caller);
        counter.increment();
    }

    function test_incrementEmitsExactlyOneLogWithExpectedLayout() public {
        address caller = makeAddr("caller");

        vm.recordLogs();
        vm.prank(caller);
        counter.increment();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(counter));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], keccak256("Incremented(address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(caller))));
        assertEq(logs[0].data, abi.encode(uint256(1)));
    }

    function test_eventCallerIsMsgSenderNotTxOrigin() public {
        NestedCaller nested = new NestedCaller();
        address origin = makeAddr("origin");

        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(address(nested), 1);
        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(address(nested), 2);

        vm.prank(origin, origin);
        nested.incrementTwice(counter);

        assertEq(counter.count(), 2);
    }

    // ---------------------------------------------------------------- many callers

    function test_manyCallersShareOneCount() public {
        uint256 callers = 100;
        for (uint256 i = 1; i <= callers; ++i) {
            address caller = address(uint160(0x1000 + i));

            vm.expectEmit(true, true, true, true, address(counter));
            emit Incremented(caller, i);
            vm.prank(caller);
            counter.increment();

            assertEq(counter.count(), i);
        }
        assertEq(counter.count(), callers);
    }

    function test_interleavedCallersEachAdvanceTheSharedCount() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(alice);
        counter.increment();
        vm.prank(bob);
        counter.increment();

        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(alice, 3);
        vm.prank(alice);
        counter.increment();

        assertEq(counter.count(), 3);
    }

    function testFuzz_anyAddressMayIncrement(address caller) public {
        vm.expectEmit(true, true, true, true, address(counter));
        emit Incremented(caller, 1);
        vm.prank(caller);
        counter.increment();
        assertEq(counter.count(), 1);
    }

    function testFuzz_sequenceOfArbitraryCallers(address[] calldata callers) public {
        for (uint256 i; i < callers.length; ++i) {
            vm.expectEmit(true, true, true, true, address(counter));
            emit Incremented(callers[i], i + 1);
            vm.prank(callers[i]);
            counter.increment();
        }
        assertEq(counter.count(), callers.length);
    }

    function test_separateDeploymentsAreIndependent() public {
        Counter other = new Counter();
        counter.increment();
        assertEq(counter.count(), 1);
        assertEq(other.count(), 0);
    }

    // ---------------------------------------------------------------- failure paths

    function test_incrementRevertsOnOverflowAndLeavesCountUnchanged() public {
        vm.store(address(counter), COUNT_SLOT, bytes32(type(uint256).max));

        vm.expectRevert(stdError.arithmeticError);
        counter.increment();

        assertEq(counter.count(), type(uint256).max);
    }

    function test_incrementRejectsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(counter).call{value: 1 wei}(abi.encodeCall(Counter.increment, ()));
        assertFalse(ok);
        assertEq(counter.count(), 0);
        assertEq(address(counter).balance, 0);
    }

    function test_countRejectsEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(counter).call{value: 1 wei}(abi.encodeWithSignature("count()"));
        assertFalse(ok);
        assertEq(address(counter).balance, 0);
    }

    function test_plainEthTransferReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(counter).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(address(counter).balance, 0);
    }

    function test_emptyCalldataReverts() public {
        (bool ok,) = address(counter).call("");
        assertFalse(ok);
        assertEq(counter.count(), 0);
    }

    function testFuzz_unknownSelectorRevertsAndChangesNothing(bytes4 selector, bytes calldata args) public {
        vm.assume(selector != Counter.increment.selector && selector != counter.count.selector);
        vm.recordLogs();
        (bool ok,) = address(counter).call(abi.encodePacked(selector, args));
        assertFalse(ok);
        assertEq(counter.count(), 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_noAdminStyleFunctionsExist() public {
        counter.increment();
        string[9] memory signatures = [
            "owner()",
            "decrement()",
            "reset()",
            "setCount(uint256)",
            "setNumber(uint256)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "withdraw()",
            "pause()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(counter).call(abi.encodePacked(bytes4(keccak256(bytes(signatures[i]))), uint256(0)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(counter.count(), 1);
    }

    function test_constructorIsNonPayable() public {
        vm.deal(address(this), 1 ether);
        bytes memory initCode = type(Counter).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(initCode, 32), mload(initCode))
        }
        assertEq(deployed, address(0));
    }

    // ---------------------------------------------------------------- deployment shape

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory code = address(counter).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function test_create2DeploymentWithNoConstructorArgsStartsAtZero() public {
        bytes memory initCode = type(Counter).creationCode;
        bytes32 salt = keccak256("counter");
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        assertEq(deployed, vm.computeCreate2Address(salt, keccak256(initCode), address(this)));
        assertEq(Counter(deployed).count(), 0);
        Counter(deployed).increment();
        assertEq(Counter(deployed).count(), 1);
    }
}
