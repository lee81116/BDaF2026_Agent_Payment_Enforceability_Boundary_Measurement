// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PlainBatchTransfer — Section E baseline 0
/// @notice The no-policy floor for the batch-curve measurement. A funded box
///         loops over (recipients, amounts) and forwards value. No allowlist,
///         no caps, no expiry, no revocation, no cumulative state. The only
///         non-policy check is the length match — that is a function-correctness
///         guard, not a policy, because without it the indexing would mis-pair
///         arrays or trip an array-bounds revert mid-loop.
/// @dev Used by test/batch/BatchCurve.t.sol to capture the floor against which
///      baseline 1 (E2-only) and baseline 2 (full E3) are compared.
contract PlainBatchTransfer {
    error LengthMismatch();

    receive() external payable {}

    function transferLoop(address payable[] calldata recipients, uint256[] calldata amounts)
        external
    {
        if (recipients.length != amounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < recipients.length; ++i) {
            (bool ok,) = recipients[i].call{value: amounts[i]}("");
            require(ok, "transfer failed");
        }
    }
}
