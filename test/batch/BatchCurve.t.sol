// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "../policies/GasMeasure.sol";
import {PlainBatchTransfer} from "../../src/baselines/PlainBatchTransfer.sol";

/// @notice Section E batch-curve measurement.
///
/// Three baselines × N ∈ {1, 2, 5, 10, 20, 50}. Each measurement uses a fresh
/// harness instance and a disjoint recipient address block so warm/cold state
/// from one N does not contaminate another. Recipients are pre-dealt 1 wei so
/// they are "existing" — this isolates the 25k G_newaccount surcharge out of
/// the per-recipient cost, leaving just the cold-account (2600) + value-
/// transfer (9000) per recipient. That makes the per-request floor predictable
/// and the amortization curve readable.
///
/// Output: each measurement emits a single grep-friendly CSV-style line:
///   CSV,<baseline_id>,<N>,<gas>
/// so `forge test --match-path test/batch/BatchCurve.t.sol -vv | grep '^CSV,'`
/// produces the rows that go into docs/batch-curve.csv.
contract BatchCurveTest is GasMeasure {
    uint256 internal constant AMOUNT = 0.01 ether;

    function _sizes() internal pure returns (uint256[6] memory s) {
        s = [uint256(1), 2, 5, 10, 20, 50];
    }

    /// @dev Build a disjoint recipient block per (baseline, N_index). 256-wide
    ///      blocks are plenty for max N = 50. baseline_id selects the high byte
    ///      so different baselines also use disjoint addresses (not strictly
    ///      necessary because each test_* is its own tx, but harmless).
    function _buildRecipients(uint256 baselineId, uint256 jIdx, uint256 n)
        internal
        returns (address payable[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address payable[](n);
        amounts = new uint256[](n);
        uint160 base = uint160(0xBEEF_0000) + uint160(baselineId << 16) + uint160(jIdx << 8);
        for (uint256 i = 0; i < n; ++i) {
            recipients[i] = payable(address(base + uint160(i)));
            vm.deal(recipients[i], 1); // existing account, no 25k surcharge
            amounts[i] = AMOUNT;
        }
    }

    // ---------- Baseline 0: PlainBatchTransfer (no policy) -------------------

    function test_Baseline0_NoPolicy() public {
        uint256[6] memory sizes = _sizes();
        for (uint256 j = 0; j < sizes.length; ++j) {
            uint256 N = sizes[j];

            PlainBatchTransfer box = new PlainBatchTransfer();
            (bool ok,) = address(box).call{value: 100 ether}("");
            require(ok, "fund box");

            (address payable[] memory recipients, uint256[] memory amounts) =
                _buildRecipients(0, j, N);

            uint256 g = _measure(
                address(box),
                abi.encodeCall(PlainBatchTransfer.transferLoop, (recipients, amounts)),
                true
            );
            emit log(string.concat("CSV,0,", vm.toString(N), ",", vm.toString(g)));
        }
    }
}
