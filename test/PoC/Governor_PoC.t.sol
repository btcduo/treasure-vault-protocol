// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {MockReceiver} from "src/mocks/MockReceiver.sol";
import {GovernErrors} from "src/libraries/Errors.sol";

/// @title Governor PoC-path tests
/// @notice Includes the common vulnerable points:
/// Owner list or the threshold can be modified by the owners(even an EOA) without `proposal`.
/// Invariant interrupted: 2 <= threshold <= owner count.
contract Governor_PoC is Test {
    ProtocolGovernor admin;
    MockReceiver rc;
    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address owner3;
    address attacker;

    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");
        admin = new ProtocolGovernor(owner1, owner2);
        rc = new MockReceiver();
        owner3 = makeAddr("OWNER3");
        attacker = makeAddr("ATTACKER");
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Proof: `onlySelf` functions cannot be invoked by an EOA or an owner.
    /// @dev Workflow: owner or EOA call -> reverts `NotSelf`.
    function test_PoC_calls_onlySelf_revert() public {
        address bob = address(0xb0b);
        vm.startPrank(owner1);
        vm.expectRevert(GovernErrors.NotSelf.selector);
        admin.addOwner(bob);
        vm.startPrank(attacker);
        vm.expectRevert(GovernErrors.NotSelf.selector);
        admin.addOwner(bob);
    }

    /**
     * @notice Proof: the owner address cannot be duplicated.
     * @dev Workflow:
     * 1 owner call `proposalAddOwner(owner2)` ->
     * 2 owner call `approve` ->
     * 1 owner call `call` ->
     * revert `ExistedOwnerAddr`.
     */
    function test_PoC_duplicate_existed_owner_setting_revert() public {
        vm.startPrank(owner1);
        uint256 txId = admin.proposalAddOwner(owner2);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        vm.expectRevert(GovernErrors.ExistedOwnerAddr.selector);
        admin.call(txId);
    }

    /**
     * @notice Proof: the owner count cannot below the threshold.
     * @dev Workflow:
     * assert ownerCount == threshold ->
     * 1 owner call `proposalRemoveOwner(owner2)` ->
     * 2 owner call `approve` ->
     * 1 owner call `call` ->
     * revert `UnsafeParams`.
     */
    function test_PoC_remove_owner_below_threshold_revert() public {
        uint256 ownerCount = admin.ownerCount();
        uint256 threshold = admin.threshold();
        assertEq(ownerCount, threshold);
        vm.startPrank(owner1);
        uint256 txId = admin.proposalRemoveOwner(owner2);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        vm.expectRevert(GovernErrors.UnsafeParams.selector);
        admin.call(txId);
    }

    /**
     * @notice Proof: the threshold cannot above the owner count.
     * @dev Workflow:
     * assert ownerCount == threshold ->
     *  one owner call `proposalModifythreshold(threshold + 1)` ->
     *   two owner call `approve` ->
     *    one owner call `call` ->
     *     revert `UnsafeParams`.
     */
    function test_PoC_modify_threshold_above_owner_count_revert() public {
        uint256 ownerCount = admin.ownerCount();
        uint256 threshold = admin.threshold();
        assertEq(ownerCount, threshold);
        vm.startPrank(owner1);
        uint256 txId = admin.proposalModifyThreshold(threshold + 1);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        vm.expectRevert(GovernErrors.UnsafeParams.selector);
        admin.call(txId);
    }
}
