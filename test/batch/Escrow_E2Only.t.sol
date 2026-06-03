// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {Escrow_E2Only} from "../../src/baselines/Escrow_E2Only.sol";
import {E2_ValueCap} from "../../src/policies/E2_ValueCap.sol";

/// @notice E-2 behavior tests for the E2-only escrow (Section E baseline 1).
///         Pins correctness of deposit/setPolicy/batchDeduct so the gas curve
///         in BatchCurve.t.sol is measuring a real, functioning batch path.
contract Escrow_E2OnlyTest is BaseTest {
    Escrow_E2Only internal box;
    uint256 internal constant CAP = 0.05 ether;

    function setUp() public override {
        super.setUp();
        box = new Escrow_E2Only(); // user = address(this)
        box.setPolicy(AGENT, Escrow_E2Only.AgentPolicy({maxPerRequest: CAP}));
        box.deposit{value: 100 ether}(AGENT);
    }

    function _recip(uint160 i) internal pure returns (address payable) {
        return payable(address(uint160(0xCAFE0000) + i));
    }

    function test_batchDeduct_single_within_cap() public {
        address payable[] memory r = new address payable[](1);
        uint256[] memory a = new uint256[](1);
        r[0] = _recip(1);
        a[0] = 0.01 ether;
        box.batchDeduct(AGENT, r, a);
        assertEq(r[0].balance, 0.01 ether);
        assertEq(box.balances(AGENT), 100 ether - 0.01 ether);
    }

    function test_batchDeduct_multiple_within_cap() public {
        uint256 n = 5;
        address payable[] memory r = new address payable[](n);
        uint256[] memory a = new uint256[](n);
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            r[i] = _recip(uint160(i + 1));
            a[i] = (i + 1) * 0.005 ether; // 0.005 .. 0.025, all ≤ CAP
            total += a[i];
        }
        box.batchDeduct(AGENT, r, a);
        for (uint256 i = 0; i < n; ++i) {
            assertEq(r[i].balance, a[i]);
        }
        assertEq(box.balances(AGENT), 100 ether - total);
    }

    function test_batchDeduct_oneAmountOverCap_reverts() public {
        address payable[] memory r = new address payable[](2);
        uint256[] memory a = new uint256[](2);
        r[0] = _recip(1);
        r[1] = _recip(2);
        a[0] = CAP; // exactly at cap, OK
        a[1] = CAP + 1; // over cap
        vm.expectRevert(E2_ValueCap.ExceedsValueCap.selector);
        box.batchDeduct(AGENT, r, a);
    }

    function test_batchDeduct_totalOverBalance_reverts() public {
        // Make balance small.
        Escrow_E2Only smallBox = new Escrow_E2Only();
        smallBox.setPolicy(AGENT, Escrow_E2Only.AgentPolicy({maxPerRequest: CAP}));
        smallBox.deposit{value: 0.02 ether}(AGENT);

        address payable[] memory r = new address payable[](3);
        uint256[] memory a = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            r[i] = _recip(uint160(i + 1));
            a[i] = 0.01 ether;
        }
        vm.expectRevert(Escrow_E2Only.InsufficientBalance.selector);
        smallBox.batchDeduct(AGENT, r, a);
    }

    function test_batchDeduct_lengthMismatch_reverts() public {
        address payable[] memory r = new address payable[](2);
        uint256[] memory a = new uint256[](3);
        vm.expectRevert(bytes("length mismatch"));
        box.batchDeduct(AGENT, r, a);
    }

    function test_setPolicy_notUser_reverts() public {
        vm.prank(AGENT);
        vm.expectRevert(Escrow_E2Only.NotUser.selector);
        box.setPolicy(AGENT, Escrow_E2Only.AgentPolicy({maxPerRequest: CAP}));
    }
}
