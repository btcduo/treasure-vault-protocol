// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseCloneFactory} from "./BaseCloneFactory.sol";
import {ILogic} from "../interfaces/ILogic.sol";

/// @title VaultFactory
/// @notice Deploys and tracks per-asset vault clones
/// @dev Design goals:
/// - Invariant: vault
/// - Deterministic vault addressses via CREATE2
/// - One vault per (asset, vault) pair
/// - Stateless clone logic
contract VaultFactory is BaseCloneFactory {
    mapping(address asset_ => address clone_) public assetOf;
    address public governor;
    address public forwarder;

    error ZeroAddrs();
    error InvalidAddrs();
    error UnsafeAddrs();
    error ZeroAsset();
    error InvalidAsset();

    event Clone(address indexed user, address indexed clone, bytes32 salt, bytes32 initDataHash);

    constructor(address vault_, address governor_, address fwd_) BaseCloneFactory(vault_) {
        if (vault_ == address(0) || governor_ == address(0) || fwd_ == address(0)) {
            revert ZeroAddrs();
        }
        if (vault_.code.length == 0 || governor_.code.length == 0 || fwd_.code.length == 0) {
            revert InvalidAddrs();
        }
        if (vault_ == governor_ || vault_ == fwd_ || governor_ == fwd_) {
            revert UnsafeAddrs();
        }
        governor = governor_;
        forwarder = fwd_;
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/
    /// @notice Deploy a new vault clone for the caller
    /// @dev Flow:
    /// - Derive CREARE2 salt from (asset, vault)
    /// - Build initialization calldata
    /// - Deploy clone via BaseCloneFactory
    /// - Track clone in assetOf[asset]
    function create(address asset_) external returns (address clone) {
        if (asset_ == address(0)) {
            revert ZeroAsset();
        }
        if (asset_.code.length == 0) {
            revert InvalidAsset();
        }
        if (assetOf[asset_] != address(0)) {
            revert AlreadyDeployed();
        }

        bytes32 salt = _salt(asset_, vault);
        bytes memory initData = _initData(asset_, governor, forwarder);
        clone = _deployClone(salt, initData);
        assetOf[asset_] = clone;

        emit Clone(msg.sender, clone, salt, keccak256(initData));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    /// @dev Derives deterministic salt
    /// Security: uses abi.enocde to avoid collision
    function _salt(address asset_, address vault_) private pure returns (bytes32) {
        return keccak256(abi.encode(asset_, vault_));
    }

    /// @dev Builds initialization calldata for vault clone
    /// Security: initialize() MUST be protected against re-initialization
    function _initData(address asset_, address governor_, address fwd_) private pure returns (bytes memory) {
        return abi.encodeCall(ILogic.initialize, (asset_, governor_, fwd_));
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/
    function predictVaultAddr(address asset_, address vault_) external view returns (address predicted) {
        bytes32 salt = _salt(asset_, vault_);
        predicted = _predict(salt);
    }
}
