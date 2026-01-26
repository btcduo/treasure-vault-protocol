// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {LinearStaking} from "src/LinearStaking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/// @title LinearStaking happy-path tests
/// @notice Safe summary:
/// Updates the core states: rewardPerTokenStored / lastUpdateAt / rewards(user) / userRewardPerTokenPaid(user).
/// The updating must be performed before executing the functions: stake / unstake / claimReward / setRewardRate
contract Staking_happy is Test {
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
    }

    /*///////////////////////////////////////////
                        Helpers
    ///////////////////////////////////////////*/
    /// @dev Mints the specified amount of tokens to the given address.
    function _mintTo(MockERC20 token, address to, uint256 amt) internal {
        token.mint(to, amt);
    }

    /// @dev Deploys and initializes the clone via the given token.
    function _createClone(MockERC20 token) internal returns (Vault clone) {
        address c = factory.create(address(token));
        clone = Vault(c);
    }

    /// @dev Deposits the user's ERC20 tokens into the clone.
    function _dpstTo(Vault clone, MockERC20 token, address to, uint256 amount, uint256 deadline)
        internal
        returns (uint256)
    {
        vm.startPrank(alice);
        return clone.depositWithPermit(to, amount, amount, deadline, _sig(clone, token, amount, deadline));
    }

    /// @dev Deploys LinearStaking instance with params(stakingToken, rewardToken, admin).
    function _deployStaking(address token) internal returns (LinearStaking s) {
        s = new LinearStaking(address(token), address(usdt), address(admin), address(fwd));
    }

    /// @dev Provides Alice's signature to complete an off-chain approval via OpenZeppelin's ERC20Permit.permit(...).
    function _sig(Vault c, MockERC20 token, uint256 value, uint256 deadline) internal view returns (bytes memory) {
        uint256 nonce_ = token.nonce(alice);
        bytes32 hash_ = keccak256(abi.encode(PERMIT_TYPEHASH, alice, address(c), value, nonce_, deadline));
        bytes32 digest_ = token.digest(hash_);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest_);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Invokes the function via admin: submit( 1 user ) -> approve( 2 user ) -> call( 1 user )
    function _adminInvokes(address to, bytes memory data) internal {
        vm.startPrank(owner1);
        uint256 txId = admin.submit(to, data);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        admin.call(txId);
        vm.stopPrank();
    }

    /*///////////////////////////////////////////
                        Tests
    ///////////////////////////////////////////*/
    /// @notice Stakes the clone's tokens into the LinearStaking.
    /// @dev Flow: mint -> deploy+init clone -> deposit in clone -> deploy staking -> stake clone token in staking -> assert balances.
    function test_stake_OK() public {
        uint256 amount = 200;
        uint256 deadline = block.timestamp + 2;
        _mintTo(usdt, alice, amount);
        Vault clone = _createClone(usdt);
        uint256 shares = _dpstTo(clone, usdt, alice, amount, deadline);
        LinearStaking staking = _deployStaking(address(clone));
        vm.startPrank(alice);
        clone.approve(address(staking), shares);
        staking.stake(shares);
        assertEq(staking.balances(alice), staking.totalStaked());
        assertEq(staking.balances(alice), amount);
        assertEq(staking.rewardRate(), 0);
        vm.stopPrank();
    }

    /// @notice Unstakes the clone's tokens from the LinearStaking.
    /// @dev Flow: deploy stakeToken -> mint -> deploy staking -> stake -> unstake -> assert balances.
    function test_unstake_OK() public {
        uint256 amount = 200;
        MockERC20 stakeToken = new MockERC20("MOCK TOKEN", "vTOKEN");
        _mintTo(stakeToken, alice, amount);
        LinearStaking staking = _deployStaking(address(stakeToken));
        vm.startPrank(alice);
        stakeToken.approve(address(staking), amount);
        staking.stake(amount);
        assertEq(staking.balances(alice), amount);
        staking.unstake(amount);
        assertEq(staking.balances(alice), amount - 200);
    }

    /// @notice Sets the rewardRate by the admin.
    /// @dev Flow: deploy stakeToken -> deploy staking -> setRewardRate -> assert state updated.
    function test_setRewardRate_OK() public {
        MockERC20 stakeToken = new MockERC20("MOCK TOKEN", "vTOKEN");
        LinearStaking staking = _deployStaking(address(stakeToken));
        vm.startPrank(address(admin));
        uint256 beforeSet = staking.rewardRate();
        staking.setRewardRate(5);
        assertEq(staking.rewardRate(), beforeSet + 5);
    }

    /// @notice Claims the rewards from the linearStaking.
    /// @dev Flow: mint -> deploy stakeToken -> deploy staking -> stake -> time skip -> unstake -> assert rewards updated.
    function test_claimReward_OK() public {
        uint256 amount = 200;
        MockERC20 stakeToken = new MockERC20("MOCK TOKEN", "vTOKEN");
        _mintTo(stakeToken, alice, amount);
        LinearStaking staking = _deployStaking(address(stakeToken));
        vm.startPrank(address(admin));
        staking.setRewardRate(5);
        vm.startPrank(alice);
        stakeToken.approve(address(staking), amount);
        staking.stake(amount);
        skip(10);
        staking.unstake(amount);
        assertEq(staking.rewards(alice), 50);
    }
}
