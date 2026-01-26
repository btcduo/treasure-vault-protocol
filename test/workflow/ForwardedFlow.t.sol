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

import {ForwarderErrors} from "src/libraries/Errors.sol";

import "src/structs/UserOp.sol";

interface IToken {
    function approve(address spender, uint256 value) external returns (bool);
}

/// @title DirectFlow tests.
/// @notice Includes two different path:
/// The user approves the transaction before depositing or staking.
/// The user deposits / stakes using a permit signature.
contract ForwardedFlow is Test {
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
                        ERC-2612 HELPERS
    //////////////////////////////////////////////////////////////*/
    // Builds struct hash in order to generate digest.
    function _structHash(address spender, uint256 amt, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(PERMIT_TYPEHASH, alice, spender, amt, nonce, deadline));
    }

    // Builds digest in order to generate signature of alice.
    function _digest(bytes32 separator, bytes32 structHash) internal pure returns (bytes32 digest) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, hex"1901")
            mstore(add(ptr, 0x02), separator)
            mstore(add(ptr, 0x22), structHash)
            digest := keccak256(ptr, 0x42)
        }
    }

    // Builds signature of alice for clone's permit verification.
    function _sigForClone(address asset, address clone, uint256 amt, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = IERC20Permit(asset).nonces(alice);
        bytes32 sep = IERC20Permit(asset).DOMAIN_SEPARATOR();
        bytes32 structHash = _structHash(clone, amt, nonce, deadline);
        bytes32 digest = _digest(sep, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        return abi.encodePacked(r, s, v);
    }

    // Builds signature of alice for staking's permit verification.
    function _sigForStaking(address clone, address staking, uint256 amt, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = IERC20Permit(clone).nonces(alice);
        bytes32 sep = IERC20Permit(clone).DOMAIN_SEPARATOR();
        bytes32 structHash = _structHash(staking, amt, nonce, deadline);
        bytes32 digest = _digest(sep, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                        FORWARDER HELPERS
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
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    // Calls via Multisig governance.
    function _governorCall(address to, bytes memory data) internal {
        vm.startPrank(owner1);
        uint256 txId = admin.submit(to, data);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        admin.call(txId);
        vm.stopPrank();
    }

    // Deploys and initializes a clone instance.
    function _deployClone(address token) internal returns (Vault clone) {
        address c = factory.create(token);
        clone = Vault(c);
    }

    // Deploys a LinearStaking instance with a clone token and a reward token.
    function _deployStaking(address clone, address reward) internal returns (LinearStaking s) {
        s = new LinearStaking(clone, reward, address(admin), address(fwd));
    }

    // Sets reward rate in 'staking' by the multisig governor(the admin)
    function _setRate(address staking, uint256 rate) internal {
        bytes memory data = abi.encodeCall(LinearStaking.setRewardRate, (rate));
        _governorCall(staking, data);
    }

    // Prank 'alice' -> approve to 'clone'
    // Prank 'relayer', executing 'clone.deposit()' via forwarder.
    function _deposit(address token, address clone, uint256 amt, uint256 nonce) internal {
        bytes memory data = abi.encodeCall(Vault.deposit, (alice, amt));
        uint256 deadline = block.timestamp + 1;
        UserOp memory op = _op(clone, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(alice);
        IToken(token).approve(clone, amt);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    // Prank 'relayer', executing 'depositWithPermit()' via forwarder.
    function _depositWithPermit(address asset, address clone, uint256 amt, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1;
        bytes memory cloneSig = _sigForClone(asset, clone, amt, deadline);
        bytes memory data = abi.encodeCall(Vault.depositWithPermit, (alice, amt, amt, deadline, cloneSig));
        UserOp memory op = _op(clone, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    // Prank 'relayer', executing 'staking.stakeWitPermit()' via forwarder.
    function _stakeWithPermit(address clone, address staking, uint256 amt, uint256 nonce) internal {
        uint256 deadline = block.timestamp + 1;
        bytes memory stakingSig = _sigForStaking(clone, staking, amt, deadline);
        bytes memory data = abi.encodeCall(LinearStaking.stakeWithPermit, (amt, deadline, stakingSig));
        UserOp memory op = _op(staking, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    // Prank 'alice' -> approve to 'staking'
    // Prank 'relayer' executing 'staking.stake()' via forwarder.
    function _stake(address clone, address staking, uint256 amt, uint256 nonce) internal {
        bytes memory data = abi.encodeCall(LinearStaking.stake, (amt));
        uint256 deadline = block.timestamp + 1;
        UserOp memory op = _op(staking, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(alice);
        IToken(clone).approve(staking, amt);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    // Prank 'relayer' executing 'staking.unstake()' via forwarder.
    function _unstake(address staking, uint256 amt, uint256 nonce) internal {
        bytes memory data = abi.encodeCall(LinearStaking.unstake, (amt));
        uint256 deadline = block.timestamp + 1;
        UserOp memory op = _op(staking, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    // Prank 'relayer' executing 'clone.withdraw()' via forwarder.
    function _withdraw(address clone, uint256 amt, uint256 nonce) internal {
        bytes memory data = abi.encodeCall(Vault.withdraw, (alice, amt));
        uint256 deadline = block.timestamp + 1;
        UserOp memory op = _op(clone, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    // Prank 'relayer' executing 'clone.redeem()' via forwarder.
    function _redeem(address clone, uint256 shares, uint256 nonce) internal {
        bytes memory data = abi.encodeCall(Vault.redeem, (alice, shares));
        uint256 deadline = block.timestamp + 1;
        UserOp memory op = _op(clone, nonce, deadline, data);
        bytes memory sig = _sig(op);
        vm.prank(relayer);
        fwd.execute{gas: op.gasLimit}(op, sig);
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Alice must approves the transactions before depositing in the Clone or staking in the LinearStaking
    /// @dev flow:
    /// deposit in clone -> stake in staking -> time elapse -> unstake in staking -> withdraw in clone -> redeem in clone -> claim reward in staking.
    function test_forwarder_execute_deposit_stake_after_approve() public {
        // deploy (clone, staking)
        Vault clone = _deployClone(address(usdt));
        LinearStaking staking = _deployStaking(address(clone), address(usdt));

        // pre-fund (staking: 200, alice: 100)
        usdt.mint(address(staking), 200);
        usdt.mint(alice, 100);

        // record usdt balances
        uint256 stakeBal_usdt_start = usdt.balanceOf(address(staking));
        uint256 aliceBal_usdt_start = usdt.balanceOf(alice);

        // set reward rate by multisig governor
        _setRate(address(staking), 1);

        // deposit in clone.
        // amount: 100, nonce: 0
        _deposit(address(usdt), address(clone), 100, 0);

        // stake in staking.
        // amount: 100, nonce: 1
        _stake(address(clone), address(staking), 100, 1);

        // skip 10 seconds.
        skip(10);

        // unstake in staking.
        _unstake(address(staking), 100, 2);

        // withdraw in clone.
        _withdraw(address(clone), 90, 3);

        // redeem in clone.
        _redeem(address(clone), 10, 4);

        // claim reward in staking
        vm.prank(alice);
        staking.claimReward();

        // assert:
        // due to: alice staked for 10 seconds, rewards in usdt: rate(1) * sec(10) = usdt tokens(10)
        // staking's usdt balances -= 10
        // alice's usdt balances += 10
        assertEq(usdt.balanceOf(address(staking)), stakeBal_usdt_start - 10);
        assertEq(usdt.balanceOf(alice), aliceBal_usdt_start + 10);
    }

    /// @notice Deposits / stakes via ERC-2612 permit ( signature-based approval ).
    /// @dev flow:
    /// deposit(permit) in clone -> stake(permit) in staking -> time elapse -> unstake in staking -> withdraw in clone -> redeem in clone -> claim reward in staking.
    function test_forwarder_execute_deposit_stake_with_permit() public {
        // deploy (clone, staking)
        Vault clone = _deployClone(address(usdt));
        LinearStaking staking = _deployStaking(address(clone), address(usdt));

        // pre-fund (staking: 200, alice: 100)
        usdt.mint(address(staking), 200);
        usdt.mint(alice, 100);

        // record usdt balances
        uint256 stakeBal_usdt_start = usdt.balanceOf(address(staking));
        uint256 aliceBal_usdt_start = usdt.balanceOf(alice);

        // set reward rate by multisig governor
        _setRate(address(staking), 1);

        // deposit with permit in clone.
        // amount: 100, nonce: 0
        _depositWithPermit(address(usdt), address(clone), 100, 0);

        // stake with permit in staking.
        // amount: 100, nonce: 1
        _stakeWithPermit(address(clone), address(staking), 100, 1);

        // skip 10 seconds.
        skip(10);

        // unstake in staking.
        _unstake(address(staking), 100, 2);

        // withdraw in clone.
        _withdraw(address(clone), 90, 3);

        // redeem in clone.
        _redeem(address(clone), 10, 4);

        // claim reward in staking
        vm.prank(alice);
        staking.claimReward();

        // assert:
        // due to: alice staked for 10 seconds, rewards in usdt: rate(1) * sec(10) = usdt tokens(10)
        // staking's usdt balances -= 10
        // alice's usdt balances += 10
        assertEq(usdt.balanceOf(address(staking)), stakeBal_usdt_start - 10);
        assertEq(usdt.balanceOf(alice), aliceBal_usdt_start + 10);
    }
}
