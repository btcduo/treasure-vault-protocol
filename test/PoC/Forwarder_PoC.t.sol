// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {LinearStaking} from "src/LinearStaking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {MockReenteringToken} from "src/mocks/MockReenteringToken.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {ForwarderErrors} from "src/libraries/Errors.sol";

import "src/structs/UserOp.sol";

/// @title Forwarder PoC-path tests
/// @notice Includes the common vulnerable points:
/// Supplies insufficient gas(less than op.gasLimit), due to EIP-150, potentially causing failed execution.
/// Gas griefing attacks by the target.
/// Executes the transaction using the same nonce to attempt replay attacks.
/// Executes the transaction over a mismatched signature.
/// Executes the outdated transaction.
contract Forwarder_PoC is Test {
    ProtocolGovernor admin;
    Forwarder fwd;
    Vault vault;
    VaultFactory factory;
    MockERC20 usdt;
    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address alice;
    uint256 alicePK;
    address relayer;

    /// @notice deploy (governor(`admin`) + forwarder(`fwd`) + vault-template(`vault`) + factory + mock-token(`usdt`))
    /// @notice prank (owner1 + owner2 + alice + relayer)
    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");
        admin = new ProtocolGovernor(owner1, owner2);
        fwd = new Forwarder("Forwarder", "1");
        vault = new Vault();
        factory = new VaultFactory(address(vault), address(admin), address(fwd));
        usdt = new MockERC20("MOCK USDT", "vUSDT");
        (alice, alicePK) = makeAddrAndKey("ALICE");
        relayer = makeAddr("RELAYER");
        vm.deal(relayer, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    // Builds a 'UserOp' struct.
    function _op(address to, uint256 gasLimit, bytes memory data) internal view returns (UserOp memory) {
        return UserOp({
            sender: alice,
            to: to,
            gasLimit: gasLimit,
            nonce: fwd.nonces(alice),
            deadline: block.timestamp + 1,
            data: data
        });
    }

    // Generates a signature of 'alice'.
    function _sig(UserOp memory op) internal view returns (bytes memory) {
        bytes32 dig_ = fwd.digest(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, dig_);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Proof: reverts when the relayer provides 2% of the 'op.gasLimit' or even less.
    function test_PoC_less_gas_provided_revert() public {
        MockReenteringToken badToken = new MockReenteringToken("BAD", "vBAD");
        bytes memory data = abi.encodeCall(MockReenteringToken.sum, (5));
        UserOp memory op = _op(address(badToken), 5_000_000, data);
        bytes memory sig = _sig(op);
        vm.startPrank(relayer);
        vm.expectRevert(ForwarderErrors.UnsafeGas.selector);
        fwd.execute{gas: op.gasLimit * 2 / 100}(op, sig);
    }

    /// @notice Proof: the target drains the provided gas, as observed from the event.
    /// @dev Asserts gasleft below 5% of op.gasLimit after execution.
    function test_PoC_gas_griefing_by_target() public {
        MockReenteringToken badToken = new MockReenteringToken("BAD", "vBAD");
        bytes memory data = abi.encodeCall(MockReenteringToken.burnGas, ());
        UserOp memory op = _op(address(badToken), 5_000_000, data);
        bytes memory sig = _sig(op);
        vm.startPrank(relayer);
        vm.recordLogs();
        fwd.execute{gas: op.gasLimit}(op, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 EXE_LOG = keccak256("Executed(address,address,uint256,uint256,uint256,uint256,bytes32)");

        uint256 gasleft_;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == EXE_LOG) {
                (, gasleft_,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bytes32));
            }
        }
        assertTrue(gasleft_ < op.gasLimit * 5 / 100);
    }

    /// @notice Proof: the nonce cannot be reused.
    function test_PoC_nonce_reuse_revert() public {
        MockReenteringToken badToken = new MockReenteringToken("BAD", "vBAD");
        bytes memory data = abi.encodeCall(MockReenteringToken.sum, (5));
        UserOp memory op = _op(address(badToken), 5_000_000, data);
        bytes memory sig = _sig(op);
        vm.startPrank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
        vm.expectRevert(ForwarderErrors.BadNonce.selector);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    /// @notice Proof: reverts when 'signature mismatch' or 'non-standard ERC1271 magic value is returned'
    function test_PoC_badSig_revert() public {
        MockReenteringToken badToken = new MockReenteringToken("BAD", "vBAD");
        bytes memory data = abi.encodeCall(MockReenteringToken.sum, (5));
        UserOp memory op = _op(address(badToken), 5_000_000, data);
        bytes memory sig = _sig(op);
        op.sender = address(0xb0b);
        vm.expectRevert(ForwarderErrors.BadSig.selector);
        fwd.execute(op, sig);
        op.sender = address(admin);
        vm.expectRevert(ForwarderErrors.BadSig.selector);
        fwd.execute(op, sig);
    }

    /// @notice Proof: reverts when 'block.timestamp > deadline'
    function test_PoC_expired_request_revert() public {
        MockReenteringToken badToken = new MockReenteringToken("BAD", "vBAD");
        bytes memory data = abi.encodeCall(MockReenteringToken.sum, (5));
        UserOp memory op = _op(address(badToken), 5_000_000, data);
        bytes memory sig = _sig(op);
        skip(3);
        vm.expectRevert(ForwarderErrors.ExpiredRequest.selector);
        fwd.execute(op, sig);
    }
}
