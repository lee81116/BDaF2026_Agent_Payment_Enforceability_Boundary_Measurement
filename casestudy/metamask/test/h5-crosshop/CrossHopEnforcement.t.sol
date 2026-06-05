// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { Test, console2 } from "forge-std/Test.sol";
import { ExecutionLib } from "@erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "@erc7579/lib/ModeLib.sol";

import { DelegationManager } from "../../src/DelegationManager.sol";
import { NativeTokenTransferAmountEnforcer } from "../../src/enforcers/NativeTokenTransferAmountEnforcer.sol";
import { Delegation, Caveat, ModeCode } from "../../src/utils/Types.sol";
import { EncoderLib } from "../../src/libraries/EncoderLib.sol";

import { MockDelegator } from "./MockDelegator.sol";

/// @title CrossHopEnforcement — H5 behavioural test
///
/// @notice Single research question: when a delegation is **re-delegated**
///         (ERC-7710 redelegation), does `DelegationManager.redeemDelegations`
///         enforce *parent* caveats along the chain, or only the leaf?
///
/// @dev    Companion source walk lives in docs/case-study-metamask.md H5.1:
///         `redeemDelegations` invokes every caveat on every delegation in
///         the chain — beforeAllHook at DelegationManager.sol:208–227,
///         beforeHook at 234–249, afterHook at 256–271, afterAllHook at
///         279–294. The remaining empirical question is whether each
///         enforcer's *state* shares one counter across all redemption
///         paths that include a given parent delegation, or splits into
///         per-hop counters (the latter would re-introduce our Section G
///         escape).
///
///         `NativeTokenTransferAmountEnforcer.spentMap` is keyed by
///         `(msg.sender, delegationHash)`; since only the DelegationManager
///         calls `beforeHook`, the effective key is `delegationHash`. That
///         hash is identical whether A directly redeems `[User→A]` or B
///         redeems `[A→B, User→A]` — both paths must therefore share one
///         running total against the User→A allowance.
///
///         The two tests below exercise both halves of that prediction:
///         (1) cross-hop overspend reverts; (2) the counter is genuinely
///         shared across redemption paths and the cap is exactly enforced.
contract CrossHopEnforcementTest is Test {
    DelegationManager internal dm;
    NativeTokenTransferAmountEnforcer internal capEnforcer;
    MockDelegator internal userAcct; // root delegator (the User)
    MockDelegator internal aAcct;    // intermediate delegator (Agent A)

    address internal agentB = address(0xB02);   // leaf delegate (Agent B, EOA)
    address payable internal provider = payable(address(0xD057)); // recipient

    uint256 internal constant ROOT_CAP = 2 ether; // User→A allowance

    bytes32 internal hashUserToA;
    bytes32 internal hashAToB;

    function setUp() public {
        dm = new DelegationManager(address(this));
        capEnforcer = new NativeTokenTransferAmountEnforcer();
        userAcct = new MockDelegator(address(dm));
        aAcct = new MockDelegator(address(dm));
        vm.label(address(dm), "DelegationManager");
        vm.label(address(capEnforcer), "NativeTokenTransferAmountEnforcer");
        vm.label(address(userAcct), "UserAccount");
        vm.label(address(aAcct), "AgentA");
        vm.label(agentB, "AgentB(EOA)");
        vm.label(provider, "Provider");

        // Fund the *root* delegator. Per DelegationManager.sol:252 the
        // execution runs against the root delegator's account, so this is
        // the single funding pool both A and B will draw from.
        vm.deal(address(userAcct), 10 ether);

        // Pre-compute hashes (signature is excluded from the hash per
        // Types.sol Delegation comment — we can build the structs without
        // signatures and reuse the hashes).
        hashUserToA = EncoderLib._getDelegationHash(_buildUserToA());
        hashAToB = EncoderLib._getDelegationHash(_buildAToB(hashUserToA));
    }

    // -------------------------------------------------------------------
    // Test 1 — parent caveat REVERTS B's cross-hop overspend
    //
    // (1) A directly redeems 1.5 ether through [User→A]: User→A counter = 1.5.
    // (2) B redeems 1.0 ether through [A→B, User→A]: parent caveat fires,
    //     bumps the SAME spentMap[DM][hashUserToA] from 1.5 to 2.5 > 2.0
    //     allowance, and reverts.
    //
    // If the framework split state per-hop, B's redemption would hit a
    // virgin per-hop counter, succeed, and the pool would lose 2.5 ether
    // total — that is precisely the Section G escape in
    // test/delegation/CrossHopEscape.t.sol. The fact that this test
    // *expects a revert* is the empirical answer that the escape is closed.
    function test_crossHop_parentCaveat_blocksOverspend() public {
        Delegation memory delUserToA = _buildUserToA();
        Delegation memory delAToB = _buildAToB(hashUserToA);

        // (1) A's direct spend.
        uint256 firstSpend = 1.5 ether;
        _redeem(address(aAcct), _chain1(delUserToA), provider, firstSpend);
        assertEq(
            capEnforcer.spentMap(address(dm), hashUserToA),
            firstSpend,
            "User->A counter after A's direct spend"
        );
        assertEq(provider.balance, firstSpend, "provider got A's spend");

        // (2) B tries to overspend through the chain. Total would be
        // 2.5 ether against a 2.0 cap — must revert.
        vm.expectRevert("NativeTokenTransferAmountEnforcer:allowance-exceeded");
        _redeem(agentB, _chain2(delAToB, delUserToA), provider, 1 ether);

        // State unchanged after revert.
        assertEq(
            capEnforcer.spentMap(address(dm), hashUserToA),
            firstSpend,
            "counter unchanged after revert"
        );
        assertEq(provider.balance, firstSpend, "no extra ETH leaked");
    }

    // -------------------------------------------------------------------
    // Test 2 — A and B share ONE counter against the User→A allowance
    //
    // A spends 1.5 ether; B then spends 0.5 ether through the chain. Both
    // succeed (1.5 + 0.5 == ROOT_CAP). One more wei from either path
    // reverts. This confirms the counter is global to the parent
    // delegation, not split per redemption path.
    //
    // Also measures B's redemption gas (caller-side via gasleft — forge-std
    // pinned by MetaMask predates `vm.lastCallGas`). This is the
    // "cross-hop enforcement cost" number for the cross-hop column of the
    // gradient table.
    function test_crossHop_sharedCounter_andCost() public {
        Delegation memory delUserToA = _buildUserToA();
        Delegation memory delAToB = _buildAToB(hashUserToA);

        // A direct: 1.5 ether.
        _redeem(address(aAcct), _chain1(delUserToA), provider, 1.5 ether);
        assertEq(capEnforcer.spentMap(address(dm), hashUserToA), 1.5 ether);

        // B through chain: 0.5 ether — should succeed, bringing the
        // shared counter to exactly 2 ether. Measure caller-side gas.
        bytes memory cd = abi.encodeCall(
            DelegationManager.redeemDelegations,
            (
                _wrapPermissionContexts(_chain2(delAToB, delUserToA)),
                _wrapModes(),
                _wrapExecCalldatas(provider, 0.5 ether)
            )
        );
        vm.prank(agentB);
        uint256 g0 = gasleft();
        (bool ok,) = address(dm).call(cd);
        uint256 bRedeemGas = g0 - gasleft();
        require(ok, "B's cross-hop redeem reverted unexpectedly");
        console2.log("[H5] B cross-hop redeem (2 layers) caller-side gas:", bRedeemGas);

        assertEq(
            capEnforcer.spentMap(address(dm), hashUserToA),
            2 ether,
            "shared counter at cap"
        );
        assertEq(provider.balance, 2 ether, "provider got A's 1.5 + B's 0.5");

        // One more wei from B reverts — the global counter is enforced.
        vm.expectRevert("NativeTokenTransferAmountEnforcer:allowance-exceeded");
        _redeem(agentB, _chain2(delAToB, delUserToA), provider, 1);

        // Likewise from A directly.
        vm.expectRevert("NativeTokenTransferAmountEnforcer:allowance-exceeded");
        _redeem(address(aAcct), _chain1(delUserToA), provider, 1);
    }

    // -------------------------------------------------------------------
    // Helpers

    function _buildUserToA() internal view returns (Delegation memory) {
        Caveat[] memory cvs = new Caveat[](1);
        cvs[0] = Caveat({
            enforcer: address(capEnforcer),
            terms: abi.encode(ROOT_CAP),
            args: ""
        });
        return Delegation({
            delegate: address(aAcct),
            delegator: address(userAcct),
            authority: dm.ROOT_AUTHORITY(),
            caveats: cvs,
            salt: 0,
            signature: ""
        });
    }

    function _buildAToB(bytes32 parentHash) internal view returns (Delegation memory) {
        return Delegation({
            delegate: agentB,
            delegator: address(aAcct),
            authority: parentHash,
            caveats: new Caveat[](0),
            salt: 0,
            signature: ""
        });
    }

    function _redeem(
        address caller,
        Delegation[] memory chain,
        address payable target,
        uint256 value
    ) internal {
        vm.prank(caller);
        dm.redeemDelegations(
            _wrapPermissionContexts(chain),
            _wrapModes(),
            _wrapExecCalldatas(target, value)
        );
    }

    function _chain1(Delegation memory d0) internal pure returns (Delegation[] memory chain) {
        chain = new Delegation[](1);
        chain[0] = d0;
    }

    function _chain2(
        Delegation memory leaf,
        Delegation memory root
    ) internal pure returns (Delegation[] memory chain) {
        chain = new Delegation[](2);
        chain[0] = leaf;
        chain[1] = root;
    }

    function _wrapPermissionContexts(Delegation[] memory chain) internal pure returns (bytes[] memory pcs) {
        pcs = new bytes[](1);
        pcs[0] = abi.encode(chain);
    }

    function _wrapModes() internal pure returns (ModeCode[] memory modes) {
        modes = new ModeCode[](1);
        modes[0] = ModeLib.encodeSimpleSingle();
    }

    function _wrapExecCalldatas(address target, uint256 value) internal pure returns (bytes[] memory cds) {
        cds = new bytes[](1);
        cds[0] = ExecutionLib.encodeSingle(target, value, hex"");
    }
}
