//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Protocol_Invariant_Base} from "./basis/Protocol_Invariant_Base.t.sol";

contract Invariant_Direct_Staking is Protocol_Invariant_Base {
    // Setup
    function _setUpChild() internal override {
        // Sets the reward rate before skipping the timestamp so reward accounting will be work.
        _setRewardRate(10);

        bytes4[] memory direct_staking_selects = _directStakingSels();

        targetSelector(FuzzSelector({addr: address(handler), selectors: direct_staking_selects}));
    }

    /// @notice the total staked token equals the cumulated balances of the actors.
    function invariant_totalStaked_equals_sumBalances_tracked() public view {
        uint256 sum;

        for (uint256 i = 0; i < actors.length; i++) {
            sum += staking.balances(actors[i]);
        }

        assertEq(staking.totalStaked(), sum);
    }

    /// @notice The claimed and pending rewards must not above the accumulated rewards.
    function invariant_reward_accounting_correctly() public view {
        uint256 rate = staking.rewardRate();
        uint256 skipped = handler.skipped();
        uint256 accumulating = rate * skipped;

        uint256 pending;
        for (uint256 i; i < actors.length; i++) {
            pending += staking.rewards(actors[i]);
        }

        uint256 total = pending + handler.settled();

        assertTrue(total <= accumulating);
    }
}
