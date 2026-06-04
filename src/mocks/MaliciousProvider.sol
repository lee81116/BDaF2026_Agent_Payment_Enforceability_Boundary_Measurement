// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MaliciousProvider — Section F (dishonest reporter)
/// @notice Same interface as MockProvider, but lies: it reports a wildly
///         inflated usage. The dishonesty is OFF-CHAIN. When the agent settles
///         the *same on-chain amount* a honest provider would have settled, the
///         escrow has no field that exposes the lie — that is the r_conf gap.
contract MaliciousProvider {
    function reportUsage(bytes32) external pure returns (uint256) {
        return type(uint256).max / 2; // fabricated, unbounded usage
    }
}
