// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SplitSig} from "./libraries/SplitSig.sol";

import {StakingErrors} from "./libraries/Errors.sol";

/// @title LinearStaking
/// @notice ERC20 staking contract that accrues rewards linearly over time at `rewardRate`.
/**
 * @dev Safe summaries:
 * No funding mechanism is included, ensure reward tokens are pre-funded before setting a non-zero `rewardRate`.
 * ERC20-only, fee-on-transfer / rebasing tokens unsupported.
 * A global accumulator(`rewardPerTokenStored`) scaled by `PRECISION` to track rewards.
 * Updates global and optionally per-user reward accounting at every external entry point.
 * All token-moving paths are protected via `nonReentrant`.
 * @dev Fee-on-transfer tokens are partially handled on _stake(credits `received`), not recommanded though.
 * @dev ERC2771Context for meta-txs via a trusted forwarder.
 * @dev ERC20Permit for allowance via signature, rather than relying on a prior approve() call.
 * @dev Uses SafeERC20 for compatibility with non-standard ERC20s (e.g.: USDT does not return boolean values).
 */
contract LinearStaking is ERC2771Context, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                STORAGES
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;

    IERC20 public immutable rewardToken;

    /// @notice MultiSig governor used to update privileged params (e.g., reward rate)
    address public immutable governor;

    /// @notice Reward emission rate in `rewardToken` units per second.
    uint256 public rewardRate;

    /// @notice Last updated timestamp of global reward accounting.
    uint256 public lastUpdateAt;

    /// @notice Cached global reward-per-token-value, scaled by `PRECISION`
    uint256 public rewardPerTokenStored;

    uint256 public totalStaked;

    /// @notice The amount of `stakingToken` as staked per user.
    mapping(address => uint256) public balances;

    /// @notice Reward-per-token value last accounted for the user.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending rewards for a user.
    mapping(address => uint256) public rewards;

    uint256 private constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev Reverts when:
     * Any init address is zero.
     * Any address not contract.
     * Any two addreses are the same.
     */
    constructor(address _staking, address _reward, address _governor, address _fwd) ERC2771Context(_fwd) {
        if (_staking == address(0) || _reward == address(0) || _governor == address(0) || _fwd == address(0)) {
            revert StakingErrors.ZeroInitAddr();
        }
        if (
            _staking.code.length == 0 || _reward.code.length == 0 || _governor.code.length == 0 || _fwd.code.length == 0
        ) {
            revert StakingErrors.InvalidInitAddr();
        }
        if (
            _staking == _reward || _staking == _governor || _staking == _fwd || _reward == _governor || _reward == _fwd
                || _fwd == _governor
        ) {
            revert StakingErrors.RepeatedInitAddr();
        }
        stakingToken = IERC20(_staking);
        rewardToken = IERC20(_reward);
        governor = _governor;
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIER
    //////////////////////////////////////////////////////////////*/
    modifier onlyGovernor() {
        if (msg.sender != governor) {
            revert StakingErrors.NotGovernor();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Stake(address indexed who, uint256 amount);
    event UnStake(address indexed who, uint256 amount);
    event Claim(address indexed who, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    /// @notice Current global reward-per-staked-token value, scaled by `PRECISION`.
    /// @dev Returns cached value if `totalStaked == 0` or no time elapsed.
    function rewardPerToken() public view returns (uint256) {
        uint256 rpts = rewardPerTokenStored;
        if (totalStaked == 0) {
            return rpts;
        }

        uint256 elapsed = block.timestamp - lastUpdateAt;
        if (elapsed == 0) {
            return rpts;
        }
        uint256 rewardInTime = rewardRate * elapsed;

        return rpts + (rewardInTime * PRECISION) / totalStaked;
    }

    /// @notice Returns total claimable rewards for `aacount` at the current timestamp.
    /// @dev Includes already-accounted `rewards[account]` plus newly accrued amount.
    function earned(address account) public view returns (uint256) {
        uint256 rpts = rewardPerToken();
        uint256 paid = userRewardPerTokenPaid[account];
        uint256 bal = balances[account];
        uint256 pending = rewards[account];

        return pending + bal * (rpts - paid) / PRECISION;
    }

    /// @notice Updates global reward-per-token-value with the current timestamp.
    /// @dev Updates `rewards[account]` and `userRewardPerTokenPaid[account]` if `account != address(0)`
    /// @dev Safe summary:
    /// any user-faced function without calling this helper will cause `reward mis-accounting` and `unfair contribution`.
    function _updateReward(address account) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateAt = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/
    /// @param amount The amount of the stakingToken
    // Amount must above zero.
    // Updates `realSender(caller)` rewards before changing balance.
    // Updates `balances[realSender]` using actual received amount.
    function _stake(uint256 amount) internal nonReentrant {
        if (amount == 0) {
            revert StakingErrors.ZeroAmount();
        }

        address realSender = _msgSender();
        _updateReward(realSender);

        uint256 balBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(realSender, address(this), amount);
        uint256 balAfter = stakingToken.balanceOf(address(this));
        uint256 received = balAfter - balBefore;
        if (received == 0) {
            revert StakingErrors.ZeroReceived();
        }

        balances[realSender] += received;
        totalStaked += received;

        emit Stake(realSender, received);
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNALS
    //////////////////////////////////////////////////////////////*/
    /// @notice Updates the reward emission rate, only callable by `governor`.
    function setRewardRate(uint256 newRate) external onlyGovernor {
        _updateReward(address(0));
        rewardRate = newRate;
    }

    /// @notice Stake `amount` of staking tokens.
    /// @dev Credits the actual received amount(supports fee-on-transfer only on stake accounting).
    /// @dev Updates caller rewards before changing balance.
    function stake(uint256 amount) external {
        _stake(amount);
    }

    /// @notice Stakes `amount` using EIP-2612 permit signature for allowance.
    /// @dev EOA-only guard: rejects contracts as the signer to avoid ambiguous auth flows.
    /// @dev Updates caller rewards before changing balance.
    function stakeWithPermit(uint256 amount, uint256 deadline, bytes calldata sig) external {
        if (amount == 0) {
            revert StakingErrors.ZeroAmount();
        }

        address realSender = _msgSender();
        if (realSender.code.length > 0) {
            revert StakingErrors.PermitEOAOnly();
        }

        (uint8 v, bytes32 r, bytes32 s) = SplitSig.split(sig);

        IERC20Permit(address(stakingToken)).permit(realSender, address(this), amount, deadline, v, r, s);

        _stake(amount);
    }

    /// @notice Unstakes `amount` of previously staked tokens.
    /// @dev Updates caller rewards before changing balance.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) {
            revert StakingErrors.ZeroAmount();
        }

        address realSender = _msgSender();
        _updateReward(realSender);

        if (amount > balances[realSender]) {
            revert StakingErrors.InsufficientBalance();
        }

        balances[realSender] -= amount;
        totalStaked -= amount;

        stakingToken.safeTransfer(realSender, amount);

        emit UnStake(realSender, amount);
    }

    /// @notice Claims all pending reward tokens for the caller.
    /// @dev Updates reward accounting before transfer.
    /// @dev Reverts if nothing to claim.
    function claimReward() external nonReentrant {
        address realSender = _msgSender();
        _updateReward(realSender);

        uint256 claim = rewards[realSender];
        if (claim == 0) {
            revert StakingErrors.InsufficientReward();
        }

        rewards[realSender] -= claim;

        rewardToken.safeTransfer(realSender, claim);

        emit Claim(realSender, claim);
    }
}
