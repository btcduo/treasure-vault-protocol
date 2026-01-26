// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {MockReceiver} from "src/mocks/MockReceiver.sol";

/// @title Governor happy-path tests
/// @notice Validates the expected successful flow:
/// Calls target: submit -> approve -> call;
/// Calls core: proposal-based entry point -> approve -> call;
/// Validates signature: returns expected magic value;
contract Governor_happy is Test {
    ProtocolGovernor admin;
    MockReceiver rc;
    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address owner3;

    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");
        admin = new ProtocolGovernor(owner1, owner2);
        rc = new MockReceiver();
        owner3 = makeAddr("OWNER3");
    }

    event Approved(address indexed approver, uint256 txId, uint256 approvedCount, uint256 needCount);

    /*///////////////////////////////////////////
                        Helpers
    ///////////////////////////////////////////*/
    function _increaseSumData() internal pure returns (bytes memory) {
        return abi.encodeCall(MockReceiver.increaseSum, ());
    }

    function _addOwnerBySelf(address addr) internal {
        vm.prank(address(admin));
        admin.addOwner(addr);
    }

    function _approve(address owner, uint256 id) internal {
        vm.prank(owner);
        admin.approve(id);
    }

    function _call(address owner, uint256 id) internal {
        vm.prank(owner);
        admin.call(id);
    }

    function _sig(address addr, bytes32 hash_) internal view returns (bytes memory) {
        uint8 v;
        bytes32 r;
        bytes32 s;
        if (addr == owner1) {
            (v, r, s) = vm.sign(pk1, hash_);
            return abi.encodePacked(r, s, v);
        }
        if (addr == owner2) {
            (v, r, s) = vm.sign(pk2, hash_);
            return abi.encodePacked(r, s, v);
        }
        return bytes("badSignature");
    }

    /*///////////////////////////////////////////
                        Tests
    ///////////////////////////////////////////*/

    /// @notice Submits the request completed by the owner.
    function test_submit_OK() public {
        vm.startPrank(owner1);
        bytes memory data = _increaseSumData();
        admin.submit(address(rc), data);
        vm.stopPrank();
    }

    /// @notice Approves the txId's transaction completed by the owner.
    /// @dev Governor's nonce should be increment after submitting.
    function test_approve_OK() public {
        bytes memory data = _increaseSumData();
        uint256 oldNonce = admin.nonce();
        vm.prank(owner1);
        uint256 txId = admin.submit(address(rc), data);
        assertEq(admin.nonce(), oldNonce + 1);
        vm.prank(owner1);
        admin.approve(txId);
        vm.prank(owner2);
        admin.approve(txId);
    }

    /// @notice Executes the txId's transaction completed by the owner.
    /// @dev Executing after the approved count touches the threshold.
    /// @dev Target's storage being updated after execution.
    function test_call_OK() public {
        uint256 oldSum = rc.sum();
        bytes memory data = _increaseSumData();
        vm.prank(owner1);
        uint256 txId = admin.submit(address(rc), data);
        _approve(owner1, txId);
        vm.startPrank(owner2);
        vm.expectEmit(true, false, false, true, address(admin));
        emit Approved(owner2, txId, 2, 2);
        admin.approve(txId);
        vm.stopPrank();
        _call(owner1, txId);
        assertEq(rc.sum(), oldSum + 1);
    }

    /// @notice Adds a new address by onlySelf into the ownerList.
    /// @dev the ownerList.length being updated after execution.
    function test_addOwner_OK() public {
        vm.prank(owner1);
        uint256 txId = admin.proposalAddOwner(owner3);
        _approve(owner1, txId);
        _approve(owner2, txId);
        uint256 ownerCount = admin.ownerCount();
        _call(owner1, txId);
        assertEq(admin.ownerCount(), ownerCount + 1);
    }

    /// @notice Removes the existed owner in the ownerList by onlySelf.
    function test_removeOwner_OK() public {
        _addOwnerBySelf(owner3);
        vm.prank(owner2);
        uint256 txId = admin.proposalRemoveOwner(owner2);
        _approve(owner3, txId);
        _approve(owner2, txId);
        _call(owner2, txId);
        assertEq(admin.ownerIndex(owner2), 0);
        assertEq(admin.owners(owner2), false);
    }

    /// @notice Modifies the threshold by onlySelf.
    function test_modifyThreshold_OK() public {
        uint256 oldThresh = admin.threshold();
        _addOwnerBySelf(owner3);
        vm.prank(owner3);
        uint256 txId = admin.proposalModifyThreshold(3);
        _approve(owner1, txId);
        _approve(owner2, txId);
        _call(owner3, txId);
        assertEq(admin.threshold(), oldThresh + 1);
    }

    /// @notice Returns the standard magic value.
    function test_1271_validation_OK() public view {
        bytes32 hash_ = keccak256(bytes("signature"));
        bytes memory sig1 = _sig(owner1, hash_);
        bytes memory sig2 = _sig(owner2, hash_);
        bytes memory sigs;
        if (owner2 > owner1) {
            sigs = abi.encodePacked(sig1, sig2);
        } else {
            sigs = abi.encodePacked(sig2, sig1);
        }
        bytes4 magic = admin.isValidSignature(hash_, sigs);
        assertEq(magic, bytes4(0x1626ba7e));
    }
}
