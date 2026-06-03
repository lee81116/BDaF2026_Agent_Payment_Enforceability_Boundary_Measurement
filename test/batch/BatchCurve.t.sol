// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "../policies/GasMeasure.sol";
import {PlainBatchTransfer} from "../../src/baselines/PlainBatchTransfer.sol";
import {Escrow_E2Only} from "../../src/baselines/Escrow_E2Only.sol";

/// @notice Section E batch-curve measurement.
///
/// Three baselines × N ∈ {1, 2, 5, 10, 20, 50}. Each baseline has its own
/// pre-built escrow per N, prepared in setUp(). This is load-bearing: setUp
/// runs in a different transaction from each test_*, so Foundry resets the
/// EIP-2929 access list between them. The result is that the first SLOAD of
/// policies/balances/dailyState inside batchDeduct is **cold**, which is the
/// real per-batch cost a settlement pays in production — not the artificially
/// cheap warm cost we would see if setPolicy/deposit ran in the same tx as
/// the measurement.
///
/// Disjoint recipient blocks per (baseline, N) avoid cross-contamination of
/// the recipients' access-list state. Recipients are pre-dealt 1 wei in setUp
/// so they are existing accounts (no 25k G_newaccount surcharge per transfer).
///
/// Output: each measurement emits a grep-friendly CSV-style log line:
///   CSV,<baseline_id>,<N>,<gas>
/// so `forge test --match-path test/batch/BatchCurve.t.sol -vv | grep '^CSV,'`
/// produces the rows that assemble into docs/batch-curve.csv.
contract BatchCurveTest is GasMeasure {
    uint256 internal constant AMOUNT = 0.01 ether;
    uint256 internal constant CAP = 1 ether;

    uint256[6] internal sizes;

    // Baseline 0
    PlainBatchTransfer[6] internal box0;
    address payable[][6] internal recipients0;
    uint256[][6] internal amounts0;

    // Baseline 1
    Escrow_E2Only[6] internal box1;
    address payable[][6] internal recipients1;
    uint256[][6] internal amounts1;

    function setUp() public override {
        super.setUp();
        sizes = [uint256(1), 2, 5, 10, 20, 50];

        for (uint256 j = 0; j < 6; ++j) {
            uint256 N = sizes[j];

            // ---- baseline 0 ----
            box0[j] = new PlainBatchTransfer();
            (bool ok0,) = address(box0[j]).call{value: 100 ether}("");
            require(ok0, "fund box0");
            (recipients0[j], amounts0[j]) = _buildRecipients(0, j, N);

            // ---- baseline 1 ----
            box1[j] = new Escrow_E2Only();
            box1[j].setPolicy(AGENT, Escrow_E2Only.AgentPolicy({maxPerRequest: CAP}));
            box1[j].deposit{value: 100 ether}(AGENT);
            (recipients1[j], amounts1[j]) = _buildRecipients(1, j, N);
        }
    }

    /// @dev Disjoint recipient block per (baseline_id, jIdx). Pre-deal 1 wei
    ///      so each recipient is an existing account (no 25k G_newaccount).
    function _buildRecipients(uint256 baselineId, uint256 jIdx, uint256 n)
        internal
        returns (address payable[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address payable[](n);
        amounts = new uint256[](n);
        uint160 base = uint160(0xBEEF_0000) + uint160(baselineId << 16) + uint160(jIdx << 8);
        for (uint256 i = 0; i < n; ++i) {
            recipients[i] = payable(address(base + uint160(i)));
            vm.deal(recipients[i], 1);
            amounts[i] = AMOUNT;
        }
    }

    // ---------- Baseline 0: no policy ----------------------------------------

    function test_Baseline0_NoPolicy() public {
        for (uint256 j = 0; j < 6; ++j) {
            uint256 g = _measure(
                address(box0[j]),
                abi.encodeCall(PlainBatchTransfer.transferLoop, (recipients0[j], amounts0[j])),
                true
            );
            emit log(string.concat("CSV,0,", vm.toString(sizes[j]), ",", vm.toString(g)));
        }
    }

    // ---------- Baseline 1: E2-only ------------------------------------------

    function test_Baseline1_E2Only() public {
        for (uint256 j = 0; j < 6; ++j) {
            uint256 g = _measure(
                address(box1[j]),
                abi.encodeCall(Escrow_E2Only.batchDeduct, (AGENT, recipients1[j], amounts1[j])),
                true
            );
            emit log(string.concat("CSV,1,", vm.toString(sizes[j]), ",", vm.toString(g)));
        }
    }
}
