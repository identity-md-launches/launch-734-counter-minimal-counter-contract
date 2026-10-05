// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

/// @dev Drives the counter from arbitrary callers and keeps its own tally of successful calls.
contract CounterHandler is Test {
    Counter public immutable counter;
    uint256 public calls;

    constructor(Counter counter_) {
        counter = counter_;
    }

    function increment(address caller) external {
        uint256 before = counter.count();
        vm.prank(caller);
        counter.increment();
        assertEq(counter.count(), before + 1);
        ++calls;
    }

    function sendEth(address caller, uint96 amount) external {
        // Dealing to the counter itself would fund it by cheatcode rather than through a call.
        if (caller == address(counter)) return;
        vm.deal(caller, amount);
        vm.prank(caller);
        (bool ok,) = address(counter).call{value: amount}("");
        assertFalse(ok);
    }

    function callGarbage(address caller, bytes calldata data) external {
        if (data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (selector == Counter.increment.selector || selector == counter.count.selector) return;
        }
        vm.prank(caller);
        (bool ok,) = address(counter).call(data);
        assertFalse(ok);
    }
}

contract CounterInvariantTest is Test {
    Counter internal counter;
    CounterHandler internal handler;

    function setUp() public {
        counter = new Counter();
        handler = new CounterHandler(counter);
        targetContract(address(handler));
    }

    /// @dev The count is exactly the number of successful increments: nothing else can move it.
    function invariant_countEqualsSuccessfulIncrements() public view {
        assertEq(counter.count(), handler.calls());
    }

    /// @dev The contract never holds ETH through any call path.
    function invariant_holdsNoEth() public view {
        assertEq(address(counter).balance, 0);
    }
}
