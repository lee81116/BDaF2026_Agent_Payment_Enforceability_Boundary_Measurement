// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MockProvider — Section F (honest reporter)
/// @notice Models the OFF-CHAIN truth: how much usage the provider claims.
///         An honest provider reports the real usage it served. This value
///         never reaches the escrow's settlement calldata — it lives off-chain.
contract MockProvider {
    uint256 public reportedUsage;

    function setReportedUsage(uint256 u) external {
        reportedUsage = u;
    }

    function reportUsage(bytes32) external view returns (uint256) {
        return reportedUsage;
    }
}
