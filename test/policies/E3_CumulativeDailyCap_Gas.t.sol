// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "./GasMeasure.sol";
import {E3_CumulativeDailyCap_Harness} from "../../src/policies/E3_CumulativeDailyCap.sol";

/// @notice D-5 — E3_CumulativeDailyCap per-check gas (the most stateful check).
///
/// We measure FIVE distinct paths because the SSTORE class dominates the cost
/// and depends on what was already in the slot at tx start:
///
///   read-only (cold)           — 1 cold SLOAD, no SSTORE
///   R+W ① cold zero→nonzero    — fresh slot; cold SLOAD + SSTORE_SET (20000)
///   R+W ② cold nonzero→nonzero — slot pre-populated cross-tx (setUp SSTORE);
///                                cold SLOAD + SSTORE_RESET (2900, post-3529)
///   R+W ③ same-tx dirty        — second call in the same tx: warm SLOAD (100) +
///                                dirty SSTORE (100). *NOT* a representative
///                                per-tx cost; plan D.1's two-call example
///                                lands here and the docs note this.
///   revert (cap exceeded)      — cold SLOAD + arithmetic + revert; no SSTORE
///
/// Cold/warm reasoning: per EIP-2929 the access list resets at tx entry, but
/// stored values persist across txs. setUp's SSTORE warms setUp's tx; the
/// test_* tx starts with the value intact and the slot cold. For scenario ②
/// the slot value is non-zero at tx start, so the SSTORE in the test_* tx
/// pays SSTORE_RESET (clean modify) rather than SSTORE_SET (zero→nonzero).
contract E3_CumulativeDailyCap_GasTest is GasMeasure {
    // Three harness instances so each scenario starts from a clean slot state.
    E3_CumulativeDailyCap_Harness internal freshH; // ①: slot empty
    E3_CumulativeDailyCap_Harness internal preWrittenH; // ② and ③: slot pre-populated
    E3_CumulativeDailyCap_Harness internal capPinnedH; // revert: spent == cap

    uint256 internal constant CAP = 1 ether;
    uint256 internal constant AMOUNT = 0.01 ether;
    uint128 internal constant PRE_SPENT = uint128(0.1 ether);

    // Predictions (callee-frame, pinned toolchain).
    //
    // Decomposition relative to the read-only cold baseline (2954):
    //   - 2100   cold SLOAD of the packed (dayStart, spent) slot
    //   -  854   arithmetic: ABI-decode 2 uint256 args, unpack two uint128
    //            fields, block.timestamp / 1 days, today-vs-dayStart compare,
    //            overflow-checked add (Solidity 0.8.x), cap comparison.
    //
    // From the baseline:
    //   RW cold SET    = RO + 20000 (SSTORE_SET)        + 46 SSTORE prep = 23000
    //   RW cold RESET  = RO +  2900 (SSTORE_RESET 3529) + 46             =  5900
    //   RW dirty       = (RO - 2000 SLOAD)              + 100 dirty SSTORE
    //                                                   + 46             =  1100
    //   revert cold    = 2100 SLOAD + 685 partial arith + revert glue    =  2785
    //                  (the revert exits inside `advance` before the += and
    //                   the harness's SSTORE prep, so it pays less arith
    //                   than a full pass.)
    uint256 internal constant PRED_RO_COLD = 2954;
    uint256 internal constant PRED_RW_COLD_SET = 23000;
    uint256 internal constant PRED_RW_COLD_RESET = 5900;
    uint256 internal constant PRED_RW_DIRTY = 1100;
    uint256 internal constant PRED_REVERT_COLD = 2785;
    uint256 internal constant TOL = 2;

    function setUp() public override {
        super.setUp();
        freshH = new E3_CumulativeDailyCap_Harness();
        preWrittenH = new E3_CumulativeDailyCap_Harness();
        capPinnedH = new E3_CumulativeDailyCap_Harness();

        // Default block.timestamp = 1, so today = 0.
        uint128 today = uint128(block.timestamp / 1 days);
        // Pre-populate scenarios ② and ③ with a non-zero spent so the slot
        // holds a non-zero packed word at the start of every test tx.
        preWrittenH.setState(today, PRE_SPENT);
        // Pin scenario "revert" at exactly CAP so any positive amount fails.
        capPinnedH.setState(today, uint128(CAP));
    }

    // ---------- read-only (cold) ---------------------------------------------

    function test_gas_E3_DailyCap_readOnly_cold() public {
        uint256 g = _measure(
            address(freshH),
            abi.encodeCall(E3_CumulativeDailyCap_Harness.checkReadOnly, (AMOUNT, CAP)),
            true
        );
        emit log_named_uint("E3_DailyCap RO cold", g);
        assertApproxEqAbs(g, PRED_RO_COLD, TOL, "E3 RO cold off prediction");
    }

    // ---------- R+W ① cold, zero → nonzero (SSTORE_SET) ----------------------

    function test_gas_E3_DailyCap_readWrite_cold_set() public {
        uint256 g = _measure(
            address(freshH),
            abi.encodeCall(E3_CumulativeDailyCap_Harness.checkReadWrite, (AMOUNT, CAP)),
            true
        );
        emit log_named_uint("E3_DailyCap RW cold SET (zero->nonzero)", g);
        assertApproxEqAbs(g, PRED_RW_COLD_SET, TOL, "E3 RW cold SET off prediction");
    }

    // ---------- R+W ② cold, nonzero → nonzero (SSTORE_RESET) -----------------

    function test_gas_E3_DailyCap_readWrite_cold_reset() public {
        uint256 g = _measure(
            address(preWrittenH),
            abi.encodeCall(E3_CumulativeDailyCap_Harness.checkReadWrite, (AMOUNT, CAP)),
            true
        );
        emit log_named_uint("E3_DailyCap RW cold RESET (nonzero->nonzero)", g);
        assertApproxEqAbs(g, PRED_RW_COLD_RESET, TOL, "E3 RW cold RESET off prediction");
    }

    // ---------- R+W ③ same-tx dirty (second call in same tx) -----------------

    function test_gas_E3_DailyCap_readWrite_sameTxDirty() public {
        // First call warms the slot AND makes it dirty (writes a new value).
        // We measure the SECOND call's gas.
        E3_CumulativeDailyCap_Harness h = preWrittenH;
        bytes memory data =
            abi.encodeCall(E3_CumulativeDailyCap_Harness.checkReadWrite, (AMOUNT, CAP));
        _measure(address(h), data, true); // priming call, gas discarded
        uint256 g = _measure(address(h), data, true);
        emit log_named_uint("E3_DailyCap RW same-tx dirty", g);
        assertApproxEqAbs(g, PRED_RW_DIRTY, TOL, "E3 RW dirty off prediction");
    }

    // ---------- revert: over cap ---------------------------------------------

    function test_gas_E3_DailyCap_revert_cold() public {
        uint256 g = _measure(
            address(capPinnedH),
            abi.encodeCall(E3_CumulativeDailyCap_Harness.checkReadWrite, (1, CAP)),
            false
        );
        emit log_named_uint("E3_DailyCap revert cold (over cap)", g);
        assertApproxEqAbs(g, PRED_REVERT_COLD, TOL, "E3 revert cold off prediction");
    }
}
