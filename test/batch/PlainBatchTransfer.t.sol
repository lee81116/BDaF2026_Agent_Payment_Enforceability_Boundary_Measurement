// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {PlainBatchTransfer} from "../../src/baselines/PlainBatchTransfer.sol";

/// @notice E-1 behavior tests for PlainBatchTransfer (Section E baseline 0).
///         This is the no-policy floor — the contract has only a length check
///         and the loop. No allowlist, no cap, no expiry, no revocation, no
///         cumulative state. The behavior tests pin correctness; gas curves
///         live in BatchCurve.t.sol.
contract PlainBatchTransferTest is BaseTest {
    PlainBatchTransfer internal box;

    function setUp() public override {
        super.setUp();
        box = new PlainBatchTransfer();
        // Fund the box with plenty of ETH for the test transfers.
        (bool ok,) = address(box).call{value: 100 ether}("");
        require(ok, "fund box");
    }

    function _recip(uint160 i) internal pure returns (address payable) {
        return payable(address(uint160(0xCAFE0000) + i));
    }

    function test_transferLoop_singleRecipient_transfersFullAmount() public {
        address payable[] memory recipients = new address payable[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = _recip(1);
        amounts[0] = 1 ether;

        box.transferLoop(recipients, amounts);

        assertEq(recipients[0].balance, 1 ether, "recipient got the value");
        assertEq(address(box).balance, 99 ether, "box debited");
    }

    function test_transferLoop_multipleRecipients_perAmount() public {
        uint256 n = 5;
        address payable[] memory recipients = new address payable[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            recipients[i] = _recip(uint160(i + 1));
            amounts[i] = (i + 1) * 0.1 ether;
            total += amounts[i];
        }

        box.transferLoop(recipients, amounts);

        for (uint256 i = 0; i < n; ++i) {
            assertEq(recipients[i].balance, amounts[i], "recipient i got amounts[i]");
        }
        assertEq(address(box).balance, 100 ether - total, "box debited by sum");
    }

    function test_transferLoop_zeroLength_isNoop() public {
        address payable[] memory recipients = new address payable[](0);
        uint256[] memory amounts = new uint256[](0);
        box.transferLoop(recipients, amounts);
        assertEq(address(box).balance, 100 ether, "no debit on empty batch");
    }

    function test_transferLoop_lengthMismatch_reverts() public {
        address payable[] memory recipients = new address payable[](2);
        uint256[] memory amounts = new uint256[](3);
        recipients[0] = _recip(1);
        recipients[1] = _recip(2);
        amounts[0] = 1;
        amounts[1] = 1;
        amounts[2] = 1;
        vm.expectRevert(PlainBatchTransfer.LengthMismatch.selector);
        box.transferLoop(recipients, amounts);
    }
}
