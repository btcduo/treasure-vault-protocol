//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Protocol_Invariant_Base} from "./basis/Protocol_Invariant_Base.t.sol";

contract Invariant_Direct_Vault is Protocol_Invariant_Base {
    // Setup
    function _setUpChild() internal override {
        bytes4[] memory vault_direct_selects = _directVaultSels();

        targetSelector(FuzzSelector({addr: address(handler), selectors: vault_direct_selects}));
    }

    /// @notice The totalSupply of the vault equals the cumulated balances of the actors.
    function invariant_totalSupply_equals_sumBalances_tracked() public view {
        uint256 sum;

        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }

        assertEq(vault.totalSupply(), sum);
    }

    /// @notice The totalUndelying of the vault equals the vault's balance in the asset.
    function invariant_totalUnderlying_matches_assetBalance() public view {
        assertEq(vault.totalUnderlying(), asset.balanceOf(address(vault)));
    }
}
