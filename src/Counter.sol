// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Counter
/// @notice A permissionless counter. Anyone may increment it by one; nobody can decrease, reset or set it.
/// @dev No owner, no admin functions, no fees and no constructor arguments. The contract has no payable
/// function, no receive and no fallback, so plain ETH transfers and unknown selectors revert.
contract Counter {
    /// @notice Emitted on every successful increment.
    /// @param caller The account that called `increment` (`msg.sender`).
    /// @param newCount The value of `count` after the increment.
    event Incremented(address indexed caller, uint256 newCount);

    /// @notice Number of successful `increment` calls since deployment. Starts at zero.
    uint256 public count;

    /// @notice Adds one to `count` and emits `Incremented`.
    /// @dev Checked arithmetic: reverts with Panic(0x11) at `type(uint256).max` instead of wrapping.
    function increment() external {
        uint256 newCount = count + 1;
        count = newCount;
        emit Incremented(msg.sender, newCount);
    }
}
