//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Protocol_Invariant_Base} from "./basis/Protocol_Invariant_Base.t.sol";

contract Invariant_Forwarded_Vault is Protocol_Invariant_Base {
    // Setup
    function _setUpChild() internal override {
        bytes4[] memory forwarded_vault_selectors = _forwardedVaultSels();

        targetSelector(FuzzSelector({addr: address(handler), selectors: forwarded_vault_selectors}));
    }

    /// @notice The totalSupply of the vault equals the cumulated balances of the actors.
    function invariant_totalStaked_equals_sumBalances_tracked() public view {
        uint256 sum;

        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }

        assertEq(vault.totalSupply(), sum);
    }

    /// @notice The nonce of the actor is corretly incremented.
    function invariant_nonce_monotonic() public view {
        for (uint256 i; i < actors.length; i++) {
            assertEq(fwd.nonces(actors[i]), handler.nonces(actors[i]));
        }
    }

    /// @notice The totalUndelying of the vault equals the vault's balance in the asset.
    function invariant_totalUnderlying_equals_balanceOfVault() public view {
        assertEq(vault.totalUnderlying(), asset.balanceOf(address(vault)));
    }
}
