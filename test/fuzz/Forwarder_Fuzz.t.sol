// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

import {MockReceiver} from "src/mocks/MockReceiver.sol";
import {ForwarderErrors} from "src/libraries/Errors.sol";
import "src/structs/UserOp.sol";

/// @title Forwarder_Fuzz
/// @notice Includes:
/// Increments the nonce and rejects the mismatched nonce before execution.
/// Validation of the deadline before execution.
contract Forwarder_Fuzz is Test {
    ProtocolGovernor admin;
    Forwarder fwd;
    Vault vault;
    VaultFactory factory;
    MockERC20 usdt;
    MockReceiver rc;
    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address alice;
    uint256 alicePK;

    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");
        admin = new ProtocolGovernor(owner1, owner2);
        fwd = new Forwarder("Forwarder", "1");
        vault = new Vault();
        factory = new VaultFactory(address(vault), address(admin), address(fwd));
        usdt = new MockERC20("MOCK USDT", "vUSDT");
        (alice, alicePK) = makeAddrAndKey("ALICE");
        rc = new MockReceiver();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    // Builds a 'UserOp' struct.
    function _op(address to, uint256 nonce, uint256 deadline, bytes memory data)
        internal
        view
        returns (UserOp memory)
    {
        return UserOp({sender: alice, to: to, gasLimit: 2_000_000, nonce: nonce, deadline: deadline, data: data});
    }

    // Generates a signature of 'alice'.
    function _sig(UserOp memory op) internal view returns (bytes memory) {
        bytes32 dig_ = fwd.digest(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, dig_);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ 1
     Verification: executes only if the random nonce equals the incremented nonce.
    //////////////////////////////////////////////////////////////*/
    function testFuzz_nonce_matched(uint96 seed) public {
        // build data
        bytes memory data = abi.encodeCall(MockReceiver.increaseSum, ());

        // assigning before the loop
        uint256 deadline = block.timestamp + 1;

        // assigning in the loop
        uint256 current;
        uint256 r;
        uint256 nonce;
        UserOp memory op;
        bytes memory sig;

        // loop
        for (uint256 i; i < 20; i++) {
            // current nonce.
            current = fwd.nonces(alice);

            // random number by keccak256(seed+i)
            r = uint256(keccak256(abi.encode(seed, i)));

            // 50% right nonce, 50% bad nonce.
            nonce = (r & 1 == 0) ? current : current + 1;

            // build 'UserOp'
            op = _op(address(rc), nonce, deadline, data);

            // build signature
            sig = _sig(op);

            // execute
            if (nonce != current) {
                vm.expectRevert(ForwarderErrors.BadNonce.selector);
                fwd.execute(op, sig);
            } else {
                (bool ok,) = fwd.execute(op, sig);
                assertTrue(ok);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ 2
        Verification: executes only if the deadline is valid.
    //////////////////////////////////////////////////////////////*/
    function testFuzz_deadline_valid(uint96 seed) public {
        // build data
        bytes memory data = abi.encodeCall(MockReceiver.increaseSum, ());

        // assigning in the loop
        uint256 timestamp;
        uint256 nonce;
        uint256 r;
        uint256 deadline;
        UserOp memory op;
        bytes memory sig;

        // loop
        for (uint256 i; i < 20; i++) {
            skip(2);

            // current timestamp
            timestamp = block.timestamp;

            // current nonce.
            nonce = fwd.nonces(alice);

            // random number by keccak256(seed+i)
            r = uint256(keccak256(abi.encode(seed, i)));

            // 50% valid, 50% expired.
            deadline = (r & 1 == 0) ? timestamp : timestamp - 1;

            // build 'UserOp'
            op = _op(address(rc), nonce, deadline, data);

            // build signature
            sig = _sig(op);

            // execute
            if (deadline < timestamp) {
                vm.expectRevert(ForwarderErrors.ExpiredRequest.selector);
                fwd.execute(op, sig);
            } else {
                (bool ok,) = fwd.execute(op, sig);
                assertTrue(ok);
            }
        }
    }
}
