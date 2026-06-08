// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GasMeasure} from "../policies/GasMeasure.sol";
import {RootAnchoredDelegation} from "../../src/delegation/RootAnchoredDelegation.sol";

/// @notice Measure — the per-hop cost of cross-hop closure (Section G′),
///         callee-frame via vm.lastCallGas(), predict-then-assert ±2.
///
/// The headline number is the PER-HOP CLOSURE INCREMENT: cost(depth=d+1) −
/// cost(depth=d) for `executeComposed`. Each extra ancestor the walk visits adds
/// one root-anchored counter R+W plus that ancestor's permission SLOADs — and
/// because the value-transfer CALL and the leaf's own checks are identical across
/// depths, they cancel in the increment, leaving a clean host-callee-frame number
/// directly comparable to the E3 RESET row (unlike MetaMask's caller-side 63,396
/// from H5).
///
/// Batch hygiene (Section D/E method): every chain is primed with a tx0 spend so
/// the measured `spentOf` write is a RESET (nonzero→nonzero), not a SET; each
/// depth uses its OWN recipient, pre-dealt 1 wei, so the transfer pays no
/// G_newaccount AND a depth's recipient is never warmed by another depth's spend
/// (the contamination that first corrupted the in-one-tx increment); setUp runs
/// in a separate tx so the measured SLOADs are genuinely cold.
///
/// Opcode account for the increment (one extra ancestor iteration of the walk):
///   spentOf[cur]                    cold SLOAD 2,100 + SSTORE_RESET 2,900 = 5,000
///   permissions[cur].cumulativeCap  cold SLOAD                           = 2,100
///   permissions[cur].parentId       cold SLOAD                           = 2,100
///   mapping-slot keccaks + ADD/GT/loop                                   ≈   425
///   ----------------------------------------------------------------------------
///   measured increment = 9,625 (paper model first predicted ~9,440; corrected —
///   see gas-results.md. The miss was the keccak/arith term: ~240 predicted vs
///   ~425 measured, because under the legacy optimizer the mapping-slot hashes
///   are recomputed per storage access, not cached. Model fixed, TOL not widened.)
contract RootAnchoredClosure_GasTest is GasMeasure {
    RootAnchoredDelegation internal delD1;
    RootAnchoredDelegation internal delD2;
    RootAnchoredDelegation internal delD3;

    bytes32 internal leafD1;
    bytes32 internal leafD2;
    bytes32 internal leafD3;

    // One recipient per depth, so no depth's transfer warms another's account.
    address payable internal constant RCPT1 = payable(address(0xCA01));
    address payable internal constant RCPT2 = payable(address(0xCA02));
    address payable internal constant RCPT3 = payable(address(0xCA03));

    uint256 internal constant CAP = 1000 ether; // generous: caps never bind here
    uint256 internal constant PRIME = 0.01 ether; // tx0 priming spend → spentOf nonzero
    uint256 internal constant AMT = 0.01 ether; // measured spend

    // Reconciled callee-frame gas (opcode account above + gas-results.md).
    uint256 internal constant PRED_D1 = 26001; // dispatch + leaf checks + 1 walk hop + transfer
    uint256 internal constant PRED_D2 = 35626; // PRED_D1 + 1 closure hop
    uint256 internal constant PRED_D3 = 45251; // PRED_D2 + 1 closure hop
    uint256 internal constant PRED_INC = 9625; // per-hop closure increment (the headline)
    uint256 internal constant TOL = 2;

    bytes32 internal _leaf; // leaf of the most recently built chain

    function setUp() public override {
        super.setUp();
        vm.deal(RCPT1, 1);
        vm.deal(RCPT2, 1);
        vm.deal(RCPT3, 1);

        delD1 = _buildChain(1, RCPT1);
        leafD1 = _leaf;
        delD2 = _buildChain(2, RCPT2);
        leafD2 = _leaf;
        delD3 = _buildChain(3, RCPT3);
        leafD3 = _leaf;
    }

    /// Build a root→…→leaf chain of length `depth`, subject == this contract at
    /// every level (so this test is the granter and the executor), then prime the
    /// whole chain with one spend so every `spentOf` slot is non-zero.
    function _buildChain(uint256 depth, address payable rcpt)
        internal
        returns (RootAnchoredDelegation del)
    {
        del = new RootAnchoredDelegation();
        (bool ok,) = address(del).call{value: 100 ether}("");
        require(ok, "fund");

        bytes32 leaf = del.grant(bytes32(0), address(this), CAP, CAP); // depth 1 (root)
        for (uint256 i = 2; i <= depth; i++) {
            leaf = del.grant(leaf, address(this), CAP, CAP);
        }
        del.executeComposed(leaf, rcpt, PRIME); // prime spentOf along the chain
        _leaf = leaf;
    }

    function _spend(RootAnchoredDelegation del, bytes32 leaf, address payable rcpt)
        internal
        returns (uint256)
    {
        return _measure(
            address(del),
            abi.encodeCall(RootAnchoredDelegation.executeComposed, (leaf, rcpt, AMT)),
            true
        );
    }

    function test_gas_closure_depth1() public {
        uint256 g = _spend(delD1, leafD1, RCPT1);
        emit log_named_uint("executeComposed depth 1 (root spends directly)", g);
        assertApproxEqAbs(g, PRED_D1, TOL, "depth1 off prediction");
    }

    function test_gas_closure_depth2() public {
        uint256 g = _spend(delD2, leafD2, RCPT2);
        emit log_named_uint("executeComposed depth 2 (leaf through one parent)", g);
        assertApproxEqAbs(g, PRED_D2, TOL, "depth2 off prediction");
    }

    function test_gas_closure_depth3() public {
        uint256 g = _spend(delD3, leafD3, RCPT3);
        emit log_named_uint("executeComposed depth 3", g);
        assertApproxEqAbs(g, PRED_D3, TOL, "depth3 off prediction");
    }

    /// The headline: the per-hop closure increment, and that it is CONSTANT (the
    /// O(depth) law). The three chains live in SEPARATE contracts with disjoint
    /// storage AND use separate recipients, so even measured in one tx each is
    /// cold on first touch (EIP-2929 is keyed on (address, slot)); the increment
    /// is g2−g1 and the law is (g3−g2) == (g2−g1).
    function test_gas_closure_perHopIncrement() public {
        uint256 g1 = _spend(delD1, leafD1, RCPT1);
        uint256 g2 = _spend(delD2, leafD2, RCPT2);
        uint256 g3 = _spend(delD3, leafD3, RCPT3);
        emit log_named_uint("increment d2-d1", g2 - g1);
        emit log_named_uint("increment d3-d2", g3 - g2);
        assertApproxEqAbs(g2 - g1, PRED_INC, TOL, "per-hop increment off prediction");
        assertApproxEqAbs(g3 - g2, g2 - g1, TOL, "per-hop increment not constant (O(depth) law)");
    }
}
