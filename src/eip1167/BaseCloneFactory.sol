// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

abstract contract BaseCloneFactory {
    address public immutable vault; // EIP-1167 template.

    error ZeroVault();
    error InvalidVault();
    error AlreadyDeployed();
    error InitFailed();

    constructor(address vault_) {
        if (vault_ == address(0)) {
            revert ZeroVault();
        }
        if (vault_.code.length == 0) {
            revert InvalidVault();
        }
        vault = vault_;
    }

    /// @notice Deploys a determinisitic clone and initializes it via a low-level-call.
    function _deployClone(bytes32 salt, bytes memory initData) internal returns (address clone) {
        clone = _predict(salt);
        if (_exists(clone)) {
            revert AlreadyDeployed();
        }
        clone = Clones.cloneDeterministic(vault, salt);

        (bool ok,) = clone.call(initData);
        if (!ok) {
            revert InitFailed();
        }
    }

    function _predict(bytes32 salt) internal view returns (address predicted) {
        predicted = Clones.predictDeterministicAddress(vault, salt, address(this));
    }

    function _exists(address clone) private view returns (bool) {
        return clone.code.length > 0;
    }
}
