// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {LinearStaking} from "src/LinearStaking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import "src/structs/UserOp.sol";

/// @title Forwarder happy-path tests
/// @notice Safe summary:
/// Before execution:
/// EOA-only signature verification via ECDSA, using an EIP-712 standard digest.
/// Verifies that the target(`op.to`) trusts this forwarder.
/// Increments the user's nonce by 1.
/// After execution:
/// Validates sufficient gas remains (EIP-150).
contract Forwarder_happy is Test {
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

    /// @notice Source: OpenZeppelin's ERC20Permit.sol, used to calculate Alice's signature(see: _sig()).
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice Used to compute the user's signature for verification by the forwarder.
    bytes32 public constant TYPE_HASH =
        keccak256("UserOp(address sender,address to,uint256 gasLimit,uint256 nonce,uint256 deadline,bytes data)");

    bytes32 public constant FWD_DOMAIN_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice deploy (governor(`admin`) + forwarder(`fwd`) + vault-template(`vault`) + factory + mock-token(`usdt`))
    /// @notice prank ( owner1 + owner2 + alice + relayer)
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
    /// @notice Deploys and initializes a clone contract via `factory.create()`
    function _deployClone(MockERC20 a) internal returns (Vault clone) {
        address c = factory.create(address(a));
        clone = Vault(c);
    }

    /// @notice Deploys a staking contract.
    function _deployStaking(Vault c) internal returns (LinearStaking staking) {
        staking = new LinearStaking(address(c), address(usdt), address(admin), address(fwd));
    }

    function _approveForVault(Vault clone, address user, uint256 amt) internal {
        vm.prank(user);
        usdt.approve(address(clone), amt);
    }

    function _approveForStake(Vault clone, LinearStaking staking, address user, uint256 amt) internal {
        vm.prank(user);
        clone.approve(address(staking), amt);
    }

    /// @notice Builds a `UserOp`.
    /// @param to the target(`op.to`).
    /// @param gasLimit gasLimit chosen by the signer(`Alice`).
    /// @param data the calldata forwarded to `to`(selector + encoded arguments).
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

    /// @notice Returns Alice's signature.
    /// @dev Signs `fwd.digest` with `alicePK` and returns the 65-byte signature.
    function _sigOfAlice(UserOp memory op) internal view returns (bytes memory) {
        bytes32 dig_ = fwd.digest(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, dig_);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Returns Alice's EIP-2612 permit signature for `token`.
    /// @dev Computes the EIP-712 digest with the current nonce of `alice`.
    function _permitSig(address token, address spender, uint256 amt, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = IERC20Permit(token).nonces(alice);
        bytes32 structHash_ = keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, amt, nonce, deadline));
        bytes32 sep_ = IERC20Permit(token).DOMAIN_SEPARATOR();
        bytes32 digest_ = keccak256(abi.encodePacked("\x19\x01", sep_, structHash_));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest_);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Flow: mint asset to user -> approve quota to Vault(clone) -> deposit in Vault
    function _deposit(Vault c, address user, uint256 amt) internal {
        usdt.mint(user, amt);
        _approveForVault(c, user, amt);
        vm.prank(user);
        c.deposit(user, amt);
    }

    /// @dev Ensures the forwarder's domain separator is valid.
    function test_domainSeparator_consistancy_OK() public view {
        bytes32 fwdSep = fwd.domainSeparator();
        string memory n = "Forwarder";
        string memory v = "1";
        uint256 cId = block.chainid;
        address f = address(fwd);
        bytes32 castSep = keccak256(abi.encode(FWD_DOMAIN_HASH, keccak256(bytes(n)), keccak256(bytes(v)), cId, f));
        assertEq(fwdSep, castSep);
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Deposit in clone for `alice` via forwarder
    /// @dev Workflow:
    /// Deploy+init clone
    ///  -> mint asset to alice
    ///   -> approve quota to spender(clone)
    ///    -> build `data`, `op struct`, `alice's signature`
    ///     -> relayer(gas sponsor) call `forwarder.execute()`
    ///      -> assert balances.
    function test_execute_deposit_OK() public {
        uint256 amt = 200;
        uint256 gasLimit = 20_000_000;
        bytes memory data = abi.encodeCall(Vault.deposit, (alice, amt));
        Vault clone = _deployClone(usdt);
        usdt.mint(alice, amt);
        uint256 tokenValueBefore = usdt.balanceOf(alice);
        uint256 cloneValueBefore = clone.balanceOf(alice);
        _approveForVault(clone, alice, amt);
        UserOp memory op = _op(address(clone), gasLimit, data);
        bytes memory sig = _sigOfAlice(op);
        vm.prank(relayer);
        fwd.execute{gas: gasLimit + 10_000}(op, sig);
        assertEq(usdt.balanceOf(alice), tokenValueBefore - 200);
        assertEq(clone.balanceOf(alice), cloneValueBefore + 200);
    }

    /// @notice DepositWithPermit in clone for `alice` via forwarder
    /// @dev Workflow:
    /// Deploy+init clone
    ///  -> mint asset to alice
    ///   -> approve quota to spender(clone)
    ///    -> build `alice's signature for permit`
    ///     -> build `data(with permit signature)`, `op struct`, `alice's signature for forwarder`
    ///      -> relayer(gas sponsor) call `forwarder.execute()`
    ///       -> assert balances.
    function test_execute_depositWithPermit_OK() public {
        uint256 amt = 200;
        uint256 value = 2000;
        uint256 gasLimit = 20_000_000;
        uint256 deadline = block.timestamp + 2;
        Vault clone = _deployClone(usdt);
        usdt.mint(alice, amt);
        uint256 tokenValueBefore = usdt.balanceOf(alice);
        uint256 cloneValueBefore = clone.balanceOf(alice);
        _approveForVault(clone, alice, value);
        bytes memory permitSig = _permitSig(address(usdt), address(clone), value, deadline);
        bytes memory data = abi.encodeCall(Vault.depositWithPermit, (alice, amt, value, deadline, permitSig));
        UserOp memory op = _op(address(clone), gasLimit, data);
        bytes memory sig = _sigOfAlice(op);
        vm.prank(relayer);
        fwd.execute{gas: gasLimit + 10_000}(op, sig);
        assertEq(usdt.balanceOf(alice), tokenValueBefore - 200);
        assertEq(clone.balanceOf(alice), cloneValueBefore + 200);
    }

    /// @notice Stake in LinearStaking for `alice` via forwarder
    /// @dev Workflow:
    /// Deploy+init clone
    ///  -> deploy LinearStaking(called `staking`)
    ///   -> deposits asset in clone
    ///    -> approve quota to spender(staking)
    ///     -> build `data`, `op struct`, `alice's signature for forwarder`
    ///      -> relayer(gas sponsor) invoke `forwarder.execute()`
    ///       -> asssert balances.
    function test_execute_stake_OK() public {
        uint256 amt = 200;
        uint256 value = 2000;
        uint256 gasLimit = 20_000_000;
        Vault clone = _deployClone(usdt);
        LinearStaking staking = _deployStaking(clone);
        _deposit(clone, alice, amt);
        _approveForStake(clone, staking, alice, value);
        bytes memory data = abi.encodeCall(LinearStaking.stake, (amt));
        UserOp memory op = _op(address(staking), gasLimit, data);
        bytes memory sig = _sigOfAlice(op);
        vm.prank(relayer);
        fwd.execute{gas: gasLimit + 10_000}(op, sig);
        assertEq(clone.balanceOf(alice), 0);
        assertEq(staking.balances(alice), 200);
    }

    /// @notice StakeWithPermit in LinearStaking for `alice` via forwarder
    /// @dev Workflow:
    /// Deploy+init clone
    ///  -> deploy LinearStaking(called `staking`)
    ///   -> deposits asset in clone
    ///    -> build `alice's signature for permit`
    ///     -> build `data(with permit signature)`, `op struct`, `alice's signature for forwarder`
    ///      -> relayer(gas sponsor) call `forwarder.execute()`
    ///       -> assert balances.
    function test_execute_stakeWithPermit_OK() public {
        uint256 amt = 200;
        uint256 gasLimit = 20_000_000;
        uint256 deadline = block.timestamp + 2;
        Vault clone = _deployClone(usdt);
        LinearStaking staking = _deployStaking(clone);
        _deposit(clone, alice, amt);
        bytes memory permitSig = _permitSig(address(clone), address(staking), amt, deadline);
        bytes memory data = abi.encodeCall(LinearStaking.stakeWithPermit, (amt, deadline, permitSig));
        UserOp memory op = _op(address(staking), gasLimit, data);
        bytes memory sig = _sigOfAlice(op);
        vm.prank(relayer);
        fwd.execute{gas: gasLimit + 10_000}(op, sig);
        assertEq(clone.balanceOf(alice), 0);
        assertEq(staking.balances(alice), 200);
    }
}
