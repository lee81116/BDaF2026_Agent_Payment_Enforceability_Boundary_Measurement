// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {Escrow} from "../../src/Escrow.sol";
import {MockProvider} from "../../src/mocks/MockProvider.sol";
import {MaliciousProvider} from "../../src/mocks/MaliciousProvider.sol";

/// @notice Section F — the r_conf (semantic-honesty) non-enforceability demo.
///
/// CLAIM: the escrow treats two settlements identically whenever their
/// on-chain-observable fields (agent, to, amount) match — even when the
/// off-chain truth behind them differs. The escrow enforces the *amount*
/// (the R(P) ceiling) but cannot enforce that the amount is *honest*.
///
/// The demonstration is bit-level: honest and malicious settlements that bill
/// the same amount produce byte-identical calldata. If the contract cannot even
/// see a difference in its input, no on-chain rule can act on one.
contract CalldataIdenticalTest is BaseTest {
    Escrow internal escrow;
    MockProvider internal honest;
    MaliciousProvider internal malicious;

    uint256 internal constant T0 = 1_700_000_000;
    uint256 internal constant AMOUNT = 0.5 ether;

    function setUp() public override {
        super.setUp();
        vm.warp(T0);

        vm.prank(USER);
        escrow = new Escrow();
        vm.prank(USER);
        escrow.deposit{value: 10 ether}(AGENT);
        vm.prank(USER);
        escrow.setPolicy(
            AGENT,
            Escrow.AgentPolicy({
                maxPerRequest: 1 ether, maxPerDay: 2 ether, validUntil: T0 + 30 days, active: true
            })
        );

        honest = new MockProvider();
        honest.setReportedUsage(100); // real, modest usage
        malicious = new MaliciousProvider(); // reports type(uint256).max/2
    }

    /// THE claim: divergent off-chain truth, bit-identical settlement calldata,
    /// both accepted by the escrow.
    function test_HonestAndMalicious_AreIndistinguishableToEscrow() public {
        // (1) Off-chain truth differs — wildly.
        uint256 truthHonest = honest.reportUsage(bytes32(0));
        uint256 truthMalicious = malicious.reportUsage(bytes32(0));
        assertTrue(truthHonest != truthMalicious, "off-chain truth must differ");
        emit log_named_uint("reportedUsage (honest)", truthHonest);
        emit log_named_uint("reportedUsage (malicious)", truthMalicious);

        // (2) Both paths bill the SAME on-chain amount. The dishonest provider
        //     inflated its usage off-chain, but the settlement the agent submits
        //     carries only (agent, to, amount) — and that amount is the same.
        bytes memory honestCalldata =
            abi.encodeWithSelector(Escrow.settle.selector, AGENT, payable(PROVIDER), AMOUNT);
        bytes memory maliciousCalldata =
            abi.encodeWithSelector(Escrow.settle.selector, AGENT, payable(PROVIDER), AMOUNT);

        emit log_named_bytes("honest    calldata", honestCalldata);
        emit log_named_bytes("malicious calldata", maliciousCalldata);

        // (3) THE assertion: the calldata is bit-identical. The contract's input
        //     is the same down to the byte — it cannot distinguish them.
        assertEq(honestCalldata, maliciousCalldata, "calldata is bit-identical");
        assertEq(keccak256(honestCalldata), keccak256(maliciousCalldata), "hash identical");

        // (4) Both calls succeed against the escrow, on equal footing.
        (bool okHonest,) = address(escrow).call(honestCalldata);
        (bool okMalicious,) = address(escrow).call(maliciousCalldata);
        assertTrue(okHonest, "escrow accepts honest settlement");
        assertTrue(okMalicious, "escrow accepts malicious settlement");

        // The provider was paid 1.0 ether across the two; the escrow never had a
        // field that could have told the honest 0.5 from the dishonest 0.5.
        assertEq(PROVIDER.balance, 2 * AMOUNT, "both settlements paid out");
    }

    /// The NEGATION: enumerate the settle surface and show no field could carry
    /// the off-chain truth. settle's calldata is exactly:
    ///   4-byte selector + 3 × 32-byte words (agent, to, amount) = 100 bytes.
    /// There is no usage/attestation/receipt parameter — by construction the
    /// escrow has nowhere to receive the information that would distinguish
    /// honest from malicious. This is a documentation test of that surface.
    function test_NoPolicyPrimitiveCanDistinguish() public {
        bytes memory cd = abi.encodeWithSelector(
            Escrow.settle.selector, address(0), payable(address(0)), uint256(0)
        );
        // selector(4) + agent(32) + to(32) + amount(32) = 100 bytes. Nothing else.
        assertEq(cd.length, 100, "settle surface is exactly (agent,to,amount) - no truth field");
    }
}
