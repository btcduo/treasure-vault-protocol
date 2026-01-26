// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {LinearStaking} from "src/LinearStaking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {MockReenteringToken} from "src/mocks/MockReenteringToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IToken {
    function mint(address to, uint256 value) external;

    function approve(address spender, uint256 value) external returns (bool);
}

/// @title LinearStaking PoC-path tests.
/// @notice Includes the common vulnerable points:
/// Any user-facing function that skips 'reward-per-token-value update' will cause incorrect reward accounting and unfair contribution.
/// Reentrancy attacks.
contract Staking_PoC is Test {
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

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    // Deploys and initializes a clone instance.
    function _deployClone(address token) internal returns (Vault clone) {
        address c = factory.create(token);
        clone = Vault(c);
    }

    // Deploys a LinearStaking instance with a clone token and a reward token.
    function _deployStaking(address clone, address reward) internal returns (LinearStaking s) {
        s = new LinearStaking(clone, reward, address(admin), address(fwd));
    }

    // Prank 'who' -> mint to 'who' -> approve to 'clone' -> deposit in 'clone'
    function _deposit(address token, address clone, address who, uint256 amt) internal {
        vm.startPrank(who);
        IToken(token).mint(who, amt);
        IToken(token).approve(clone, amt);
        Vault(clone).deposit(who, amt);
        vm.stopPrank();
    }

    // Prank 'who' -> approve to 'staking' -> stake in 'staking'
    function _stake(address clone, address staking, address who, uint256 amt) internal {
        vm.startPrank(who);
        IToken(clone).approve(staking, amt);
        LinearStaking(staking).stake(amt);
        vm.stopPrank();
    }

    // Prank 'who' -> unstake in 'staking'
    function _unstake(LinearStaking staking, address who, uint256 amt) internal {
        vm.prank(who);
        staking.unstake(amt);
    }

    // Prank 'owners' -> submit(by 1 owner) -> approve(by 2 owner) -> call with 'data' to 'target'(by 1 owner)
    function _governorCall(address target, bytes memory data) internal {
        vm.startPrank(owner1);
        uint256 txId = admin.submit(target, data);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        admin.call(txId);
        vm.stopPrank();
    }

    // Sets reward rate in 'token' by the multisig governor(the admin)
    function _setRate(address token, uint256 rate) internal {
        bytes memory data = abi.encodeCall(LinearStaking.setRewardRate, (rate));
        _governorCall(token, data);
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Proof: reward-per-token-value is corretly updated in user-facing functions(e.g.: stake / unstake)
     * @dev Workflow:
     * prank (user1, user2, user3) ->
     *  deploys (clone(and initialize), staking) ->
     *   set rate ->
     *    deposit (user1, user2, user3) ->
     *     stake (user1) ->
     *      skip (10) ->
     *       stake (user2), unstake (user1), assert balances (user1) ->
     *        skip(10) ->
     *         stake (user3), unstake (user1, user2), assert balances (user1, user2) ->
     *          skip(10) ->
     *           unstake (user1, user2, user3), assert balances (user1, user2, user3)
     */
    function test_PoC_reward_mis_accounting_NotExist() public {
        // makes addresses
        address user1 = address(0x1111);
        address user2 = address(0x2222);
        address user3 = address(0x3333);
        // deploys clone + staking
        Vault clone = _deployClone(address(usdt));
        LinearStaking staking = _deployStaking(address(clone), address(usdt));
        // sets rate in staking
        _setRate(address(staking), 5);
        // deposits in clone
        _deposit(address(usdt), address(clone), user1, 300);
        _deposit(address(usdt), address(clone), user2, 200);
        _deposit(address(usdt), address(clone), user3, 800);
        // simulates:
        _stake(address(clone), address(staking), user1, 300);
        skip(10);
        _stake(address(clone), address(staking), user2, 200);
        _unstake(staking, user1, 100);
        // total reward: 10(sec) * 5(rate-per-sec), total staked: 300(`user1`)
        // per-token-value: 50(sec * rate-per-sec) * 1e18 / 300 ≈ 166_666_666_666_666_666
        // `user1` get rewards: 0(pending) + 300 * per-token-value / 1e18 ≈ 49.999(interger math, rounding down, result: 49)
        assertEq(staking.rewards(user1), 49);
        skip(10);
        _stake(address(clone), address(staking), user3, 800);
        _unstake(staking, user1, 100);
        _unstake(staking, user2, 100);
        // total reward: 10(sec) * 5(rate-per-sec), total staked: 400(200 of `user1`, 200 of `user2`)
        // per-token-value: 50(sec * rate-per-sec) * 1e18 / 400 = 0.125 * 1e18 = 1.25e17
        // `user1` get rewards: 49(pending) + 200(user1 staked) * per-token-value / 1e18 = 74
        // `user2` get rewards: 25
        assertEq(staking.rewards(user1), 74);
        assertEq(staking.rewards(user2), 25);
        skip(10);
        _unstake(staking, user1, 100);
        _unstake(staking, user2, 100);
        _unstake(staking, user3, 800);
        // per-token-value: 5e16
        // `user1` get rewards: 74 + 100 * per-token-value / 1e18 = 79
        // `user2` get rewards: 25 + 100 * per-token-value / 1e18 = 30
        // `user3` get rewards: 800 * per-token-value / 1e18 = 40
        assertEq(staking.rewards(user1), 79);
        assertEq(staking.rewards(user2), 30);
        assertEq(staking.rewards(user3), 40);
    }

    /**
     * @notice Proof: Reentrancy attacks is prevented by 'nonReentrant'
     * @dev Workflow:
     * deploy (clone, badReward, staking) ->
     *  prepair funds (mint badReward token for staking) ->
     *   set rate, deposit, stake ->
     *    skip (10) ->
     *     unstake, assert balances ->
     *      prank 'alice' and call 'staking.claimReward()' ->
     *       revert with 'ReentrancyGuardReentrantCall'
     */
    function test_PoC_badReward_reentrant_revert() public {
        Vault clone = _deployClone(address(usdt));
        MockReenteringToken badReward = new MockReenteringToken("BAD", "vBAD");
        LinearStaking staking = _deployStaking(address(clone), address(badReward));
        badReward.mint(address(staking), 5000);
        _setRate(address(staking), 5);
        _deposit(address(usdt), address(clone), alice, 200);
        _stake(address(clone), address(staking), alice, 200);
        skip(10);
        _unstake(staking, alice, 200);
        uint256 pending = staking.rewards(alice);
        assertTrue(pending > 0);
        vm.startPrank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        staking.claimReward();
        vm.stopPrank();
    }
}
