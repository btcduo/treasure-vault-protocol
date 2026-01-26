// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";

import "src/structs/UserOp.sol";

/* ==================== interfaces ==================== */

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IVaultLike {
    function approve(address spender, uint256 value) external returns (bool);

    function deposit(address to, uint256 assets) external returns (uint256 shares);
    function withdraw(address to, uint256 assets) external returns (uint256 shareSpent);
    function redeem(address to, uint256 shares) external returns (uint256 assetsOut);

    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalUnderlying() external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);
}

interface IStakingLike {
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claimReward() external;

    function balances(address) external view returns (uint256);
    function rewards(address) external view returns (uint256);
    function totalStaked() external view returns (uint256);
}

interface IForwarderLike {
    function nonce(address) external view returns (uint256);
    function digest(UserOp calldata op) external view returns (bytes32);

    function execute(UserOp calldata op, bytes calldata sig) external returns (bool success, bytes memory ret);
}

/* ==================== Handler ==================== */

contract Protocol_Handler is Test {
    IVaultLike public vault;
    IERC20Like public asset;
    IStakingLike public staking;
    IForwarderLike public forwarder;

    address[] public actors;
    uint256[] internal pks;

    uint256 internal constant MAX_ASSETS = 100 ether;

    // Incrementing per user's nonce before transaction is forwarded.
    mapping(address => uint256) public nonces;

    // Accumulating claimed tokens by users.
    uint256 public settled;

    // Accumulating skipped timestamp.
    uint256 public skipped;

    /// @dev requires: actors.length == pks.length
    constructor(
        address _vault,
        address _asset,
        address _staking,
        address _forwarder,
        address[] memory _actors,
        uint256[] memory _pks
    ) {
        require(_actors.length == _pks.length, "len mismatch");
        vault = IVaultLike(_vault);
        asset = IERC20Like(_asset);
        staking = IStakingLike(_staking);
        forwarder = IForwarderLike(_forwarder);

        actors = _actors;
        pks = _pks;

        deal(_asset, _staking, 1_000_000_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    // Assigns a random actor.
    // 'seed' should be equivalent with '_pk(seed)'
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // Assigns a random private key.
    // 'seed' should be equivalent with'_actor(seed)'
    function _pk(uint256 seed) internal view returns (uint256) {
        return pks[seed % pks.length];
    }

    // Deals 'amount' of 'asset' to 'user' and approves 'amount' to 'vault'.
    function _topUpAndApprove(address user, uint256 amount) internal {
        uint256 cur = asset.balanceOf(user);
        deal(address(asset), user, cur + amount);

        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vm.stopPrank();
    }

    // Helper of _execute()
    function _op(address user_, address token_, bytes memory data_) internal view returns (UserOp memory) {
        uint256 nonce_ = forwarder.nonce(user_);
        uint256 deadline_ = block.timestamp + 1;

        return UserOp({sender: user_, to: token_, gasLimit: 2_000_000, nonce: nonce_, deadline: deadline_, data: data_});
    }

    // Helper of _execute()
    function _sig(uint256 seed, UserOp memory op) internal view returns (bytes memory) {
        uint256 pk = _pk(seed);
        address user = _actor(seed);
        bytes32 digest = forwarder.digest(op);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        address recovered = ecrecover(digest, v, r, s);
        require(recovered == user, "signer mismatch");
        return abi.encodePacked(r, s, v);
    }

    // the execute logic of the forwarder contract.
    function _execute(uint256 seed, address user, address to, bytes memory data) internal {
        UserOp memory op = _op(user, to, data);
        bytes memory sig = _sig(seed, op);

        vm.prank(user);
        forwarder.execute(op, sig);
    }

    /*//////////////////////////////////////////////////////////////
                            ACTION SET
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits in 'vault' by 'user'
    function act_deposit_direct(uint256 actorSeed, uint256 assetsRaw) external {
        address user = _actor(actorSeed);

        uint256 assets = bound(assetsRaw, 1, MAX_ASSETS);

        _topUpAndApprove(user, assets);

        vm.prank(user);
        vault.deposit(user, assets);
    }

    /// @notice Withdraws in 'vault' by 'user'
    function act_withdraw_direct(uint256 actorSeed, uint256 assetsRaw) external {
        address user = _actor(actorSeed);

        uint256 shares = vault.balanceOf(user);
        if (shares == 0) {
            return;
        }

        uint256 maxAssets = vault.previewRedeem(shares);
        uint256 assets = bound(assetsRaw, 1, maxAssets);

        vm.prank(user);
        vault.withdraw(user, assets);
    }

    /// @notice Redeems in 'vault' by 'user'
    function act_redeem_direct(uint256 actorSeed, uint256 sharesRaw) external {
        address user = _actor(actorSeed);
        uint256 userShares = vault.balanceOf(user);
        if (userShares == 0) {
            return;
        }

        uint256 shares = bound(sharesRaw, 1, userShares);

        vm.prank(user);
        vault.redeem(user, shares);
    }

    /// @notice Stakes in 'staking' by 'user'
    function act_stake_direct(uint256 actorSeed, uint256 amountRaw) external {
        address user = _actor(actorSeed);
        uint256 userShares = vault.balanceOf(user);
        if (userShares == 0) {
            return;
        }

        uint256 amount = bound(amountRaw, 1, userShares);

        vm.startPrank(user);
        vault.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// @notice Unstakes in 'staking' by 'user'
    function act_unstake_direct(uint256 actorSeed, uint256 amountRaw) external {
        address user = _actor(actorSeed);
        uint256 userStaked = staking.balances(user);
        if (userStaked == 0) {
            return;
        }

        uint256 amount = bound(amountRaw, 1, userStaked);

        vm.prank(user);
        staking.unstake(amount);
    }

    /// @notice Claims in 'staking' by 'user'
    /// @dev Cumulates 'settled' before claiming.
    function act_claim_direct(uint256 actorSeed) external {
        address user = _actor(actorSeed);
        uint256 pending = staking.rewards(user);
        if (pending == 0) {
            return;
        }

        settled += staking.rewards(user);

        vm.prank(user);
        staking.claimReward();
    }

    /// @notice Deposits in 'vault' by 'user' via 'forwarder'
    /// @dev Approves to 'vault' and Increments 'nonces[user]' before execution.
    function act_deposit_forwarded(uint256 actorSeed, uint256 assetsRaw) external {
        address user = _actor(actorSeed);
        uint256 userAssets = asset.balanceOf(user);
        if (userAssets == 0) {
            return;
        }

        uint256 assets = bound(assetsRaw, 1, userAssets);

        bytes memory data = abi.encodeCall(IVaultLike.deposit, (user, assets));

        asset.approve(address(vault), assets);

        nonces[user]++;

        _execute(actorSeed, user, address(vault), data);
    }

    /// @notice Withdraws in 'vault' by 'user' via 'forwarder'
    /// @dev Increments 'nonces[user]' before execution.
    function act_withdraw_forwarded(uint256 actorSeed, uint256 assetsRaw) external {
        address user = _actor(actorSeed);
        uint256 userShares = vault.balanceOf(user);
        uint256 maxAssets = vault.previewRedeem(userShares);
        if (maxAssets == 0) {
            return;
        }

        uint256 assets = bound(assetsRaw, 1, maxAssets);

        bytes memory data = abi.encodeCall(IVaultLike.withdraw, (user, assets));

        nonces[user]++;

        _execute(actorSeed, user, address(vault), data);
    }

    /// @notice Redeems in 'vault' by 'user' via 'forwarder'
    /// @dev Increments 'nonces[user]' before execution.
    function act_redeem_forwarded(uint256 actorSeed, uint256 sharesRaw) external {
        address user = _actor(actorSeed);
        uint256 userShares = vault.balanceOf(user);
        if (userShares == 0) {
            return;
        }

        uint256 shares = bound(sharesRaw, 1, userShares);

        bytes memory data = abi.encodeCall(IVaultLike.redeem, (user, shares));

        nonces[user]++;

        _execute(actorSeed, user, address(vault), data);
    }

    /// @notice Stakes in 'staking' by 'user' via 'forwarder'
    /// @dev Approves to 'staking' and Increments 'nonces[user]' before execution.
    function act_stake_forwarded(uint256 actorSeed, uint256 amountRaw) external {
        address user = _actor(actorSeed);
        uint256 userShares = vault.balanceOf(user);
        if (userShares == 0) {
            return;
        }

        uint256 amount = bound(amountRaw, 1, vault.balanceOf(user));

        bytes memory data = abi.encodeCall(IStakingLike.stake, (amount));

        vault.approve(address(staking), amount);

        nonces[user]++;

        _execute(actorSeed, user, address(staking), data);
    }

    /// @notice Unstakes in 'staking' by 'user' via 'forwarder'
    /// @dev Increments 'nonces[user]' before execution.
    function act_unstake_forwarded(uint256 actorSeed, uint256 amountRaw) external {
        address user = _actor(actorSeed);
        uint256 userBal = staking.balances(user);
        if (userBal == 0) {
            return;
        }

        uint256 amount = bound(amountRaw, 1, userBal);

        bytes memory data = abi.encodeCall(IStakingLike.unstake, (amount));

        nonces[user]++;

        _execute(actorSeed, user, address(staking), data);
    }

    /// @notice Unstakes in 'staking' by 'user' via 'forwarder'
    /// @dev Cumulates 'settled' and increments 'nonces[user]' before execution.
    function act_claim_forwarded(uint256 actorSeed) external {
        address user = _actor(actorSeed);
        uint256 pending = staking.rewards(user);
        if (pending == 0) {
            return;
        }

        bytes memory data = abi.encodeCall(IStakingLike.claimReward, ());

        settled += pending;
        nonces[user]++;

        _execute(actorSeed, user, address(staking), data);
    }

    /// @notice Skips timestamp.
    /// @dev Cumulates 'skipped'
    function act_skip(uint256 secondsRaw) external {
        uint256 dt = bound(secondsRaw, 1, 30 days);

        skipped += dt;

        skip(dt);
    }
}
