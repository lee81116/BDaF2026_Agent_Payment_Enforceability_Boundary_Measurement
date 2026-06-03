// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {E2_ValueCap} from "../policies/E2_ValueCap.sol";

/// @title Escrow_E2Only — Section E baseline 1
/// @notice An escrow with E2 (per-call value cap) ONLY. No expiry, no
///         revocation, no cumulative daily cap. Used in BatchCurve to isolate
///         the cost of the E2 check (per-iteration GT + 1 SLOAD of maxPerRequest)
///         vs the no-policy floor (baseline 0) and the full E3 (baseline 2).
/// @dev Mirrors src/Escrow.sol structurally so the comparison is apples-to-
///      apples: same struct/SLOAD pattern, same two-loop split (check loop
///      then transfer loop), same balance update. The fields that go away are
///      `active`, `validUntil`, `maxPerDay`, and the `dailyState` mapping.
contract Escrow_E2Only {
    struct AgentPolicy {
        uint256 maxPerRequest;
    }

    address public immutable user;
    mapping(address => AgentPolicy) public policies;
    mapping(address => uint256) public balances;

    error ExceedsPerRequest();
    error InsufficientBalance();
    error NotUser();

    modifier onlyUser() {
        if (msg.sender != user) revert NotUser();
        _;
    }

    constructor() {
        user = msg.sender;
    }

    function deposit(address agent) external payable {
        balances[agent] += msg.value;
    }

    function setPolicy(address agent, AgentPolicy calldata p) external onlyUser {
        policies[agent] = p;
    }

    function batchDeduct(
        address agent,
        address payable[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        require(recipients.length == amounts.length, "length mismatch");
        AgentPolicy memory p = policies[agent];

        uint256 totalAmount;
        for (uint256 i = 0; i < amounts.length; ++i) {
            E2_ValueCap.check(amounts[i], p.maxPerRequest);
            totalAmount += amounts[i];
        }

        if (balances[agent] < totalAmount) revert InsufficientBalance();
        balances[agent] -= totalAmount;

        for (uint256 i = 0; i < recipients.length; ++i) {
            (bool ok,) = recipients[i].call{value: amounts[i]}("");
            require(ok, "transfer failed");
        }
    }
}
