// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockPaidEndpoint — Section F
/// @notice A paid service endpoint. It only records that it was paid; it has no
///         way to attest *why* the amount is what it is. This is the on-chain
///         counterpart to "the provider got paid X" — the chain sees the value,
///         never the work behind it.
contract MockPaidEndpoint {
    event PaidCall(address indexed caller, uint256 value, bytes32 indexed reqId);

    function pay(bytes32 reqId) external payable {
        emit PaidCall(msg.sender, msg.value, reqId);
    }
}
