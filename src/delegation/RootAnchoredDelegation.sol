// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RootAnchoredDelegation — Section G′ (the cross-hop closure)
/// @notice Same single-pool grant/execute shape as `TwoHopDelegation`, but it
///         CLOSES the Section G escape by walking the parent chain to the root
///         on every spend and debiting a per-permission, root-anchored counter
///         at every ancestor. This is methodology.md option (b) — the host-side
///         analog of MetaMask's chain walk + hash-keyed counter (H5).
/// @dev The contrast with `TwoHopDelegation` is exactly one thing: that contract
///      checks only the immediate permission's own `spent` slot; this one debits
///      EVERY ancestor's counter, so a sub-delegate's spend is charged against
///      the budget its parent originally received. A's 1.5 + B's 2.0 therefore
///      hits the 2-ETH root cap and reverts — the escape is priced, not free.
///      Closing it costs O(depth) root-anchored state per spend; the `_Gas` test
///      measures the per-hop increment (callee-frame, comparable to the host E3
///      RESET row — unlike MetaMask's caller-side 63k).
contract RootAnchoredDelegation {
    struct Permission {
        bytes32 parentId; // 0 for a root grant
        uint256 depth; // 1 for a root grant; parent.depth + 1 otherwise
        address subject; // who holds and may exercise it
        uint256 perCallCap;
        uint256 cumulativeCap; // this permission's own cap
        bool active;
    }

    mapping(bytes32 => Permission) public permissions;
    mapping(bytes32 => uint256) public spentOf; // per-permission cumulative spend
    uint256 public nonce;

    /// @notice The single funding pool (see `TwoHopDelegation`): one source of
    ///         money, so a global overspend is unambiguous.
    receive() external payable {}

    /// @notice Grant `subject` a permission derived from `parentId`. Root grant
    ///         passes `parentId == bytes32(0)` (depth 1); otherwise the caller
    ///         must hold `parentId` and the new depth is one deeper.
    function grant(bytes32 parentId, address subject, uint256 perCallCap, uint256 cumulativeCap)
        external
        returns (bytes32 permId)
    {
        uint256 depth;
        if (parentId == bytes32(0)) {
            depth = 1; // root grant from the user
        } else {
            Permission storage parent = permissions[parentId];
            require(parent.active, "inactive parent");
            require(parent.subject == msg.sender, "not parent holder");
            depth = parent.depth + 1;
        }

        permId = keccak256(abi.encodePacked(msg.sender, subject, nonce++));
        permissions[permId] = Permission({
            parentId: parentId,
            depth: depth,
            subject: subject,
            perCallCap: perCallCap,
            cumulativeCap: cumulativeCap,
            active: true
        });
    }

    /// @notice Spend `amount` to `to` under `permId`, charging the amount against
    ///         EVERY ancestor's root-anchored counter (root-anchored closure).
    /// @dev Checks-effects-interactions: every counter write and cap check is
    ///      committed BEFORE the external transfer. If any ancestor's cap would
    ///      break, the whole call reverts and all the debits roll back together —
    ///      so a blocked spend leaves every counter (including the root) intact.
    function executeComposed(bytes32 permId, address payable to, uint256 amount) external {
        Permission storage p = permissions[permId];
        require(p.subject == msg.sender, "not subject");
        require(p.active, "inactive");
        require(amount <= p.perCallCap, "per-call cap");

        // Walk to the root, debiting and checking every ancestor's own counter.
        bytes32 cur = permId;
        while (cur != bytes32(0)) {
            uint256 spent = spentOf[cur] + amount;
            require(spent <= permissions[cur].cumulativeCap, "cumulative cap");
            spentOf[cur] = spent;
            cur = permissions[cur].parentId;
        }

        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    function depthOf(bytes32 permId) external view returns (uint256) {
        return permissions[permId].depth;
    }
}
