// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";

import { IDeleGatorCore } from "../../src/interfaces/IDeleGatorCore.sol";
import { ModeCode } from "../../src/utils/Types.sol";

/// @title MockDelegator
///
/// @notice Minimal contract account that satisfies the surface
///         `DelegationManager.redeemDelegations` needs from a *contract*
///         delegator: `IERC1271.isValidSignature` (so the signature path at
///         DelegationManager.sol:176 returns the magic value regardless of
///         signature contents) and `IDeleGatorCore.executeFromExecutor` (so
///         the manager can drive the execution at DelegationManager.sol:252).
///
/// @dev    H5 only — focused on testing cross-hop caveat enforcement.
///         Production DeleGators (HybridDeleGator, MultiSigDeleGator) add
///         owner-keyed signature checks and onlyEntryPointOrSelf gates that
///         are orthogonal to the question this test asks.
contract MockDelegator is IDeleGatorCore {
    using ExecutionLib for bytes;

    address public immutable DELEGATION_MANAGER;

    constructor(address delegationManager_) {
        DELEGATION_MANAGER = delegationManager_;
    }

    /// Always returns the EIP-1271 magic value so the contract-signature
    /// path at DelegationManager.sol:176 succeeds for our test fixtures.
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    /// Decodes a single-mode execution payload and performs the call.
    /// Only callable by the DelegationManager (mirrors production
    /// `onlyExecutorModule` access control without taking on the full
    /// ERC-7579 module surface).
    function executeFromExecutor(
        ModeCode,
        bytes calldata executionCalldata_
    )
        external
        payable
        returns (bytes[] memory)
    {
        require(msg.sender == DELEGATION_MANAGER, "MockDelegator: only DM");
        (address target_, uint256 value_, bytes calldata callData_) = executionCalldata_.decodeSingle();
        (bool ok_,) = target_.call{ value: value_ }(callData_);
        require(ok_, "MockDelegator: exec failed");
        return new bytes[](0);
    }

    receive() external payable { }
}
