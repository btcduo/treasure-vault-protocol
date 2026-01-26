// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {GovernorCore} from "./GovernorCore.sol";

/// @title Upgradeable ProtocolGovernor provides external entry points for owners and ERC1271-verification.
/**
 * @notice How the MultiSig work:
 * An owner submits the request(via: submit() / proposalAddOwner() / proposalRemoveOnwer() / proposalModifyThreshold()).
 * Multiplie owners approves the rquest until the approved count reaches the threshold(via: approve()).
 * An owner invokes the call().
 */
contract ProtocolGovernor is GovernorCore {
    bytes4 public constant FAIL_MAGIC = 0xffffffff;
    bytes4 public constant OK_MAGIC = 0x1626ba7e;

    constructor(address _owner1, address _owner2) GovernorCore(_owner1, _owner2) {}

    /*//////////////////////////////////////////////////////////////
                                ONLYOWNER
    //////////////////////////////////////////////////////////////*/
    function submit(address _target, bytes memory _data) external onlyOwner returns (uint256 txId) {
        _notZeroAddr(_target);
        txId = _submit(_target, _data);
    }

    function proposalAddOwner(address addr) external onlyOwner returns (uint256 txId) {
        _notZeroAddr(addr);
        bytes memory data = abi.encodeCall(this.addOwner, (addr));
        txId = _submit(address(this), data);
    }

    function proposalRemoveOwner(address addr) external onlyOwner returns (uint256 txId) {
        _notZeroAddr(addr);
        bytes memory data = abi.encodeCall(this.removeOwner, (addr));
        txId = _submit(address(this), data);
    }

    function proposalModifyThreshold(uint256 newThresh) external onlyOwner returns (uint256 txId) {
        bytes memory data = abi.encodeCall(this.modifyThreshold, (newThresh));
        txId = _submit(address(this), data);
    }

    function approve(uint256 txId) external onlyOwner {
        _validTxId(txId, nonce);
        _approve(txId);
    }

    function call(uint256 txId) external onlyOwner {
        _validTxId(txId, nonce);
        _call(txId);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-1271
    //////////////////////////////////////////////////////////////*/
    function isValidSignature(bytes32 hash, bytes calldata sigs) external view returns (bytes4) {
        uint256 th = threshold;
        bool ok = _preSigCheck(sigs.length, th);
        if (!ok) {
            return FAIL_MAGIC;
        }

        address last;
        uint256 count;
        for (uint256 i; i < sigs.length; i += 65) {
            uint8 v;
            bytes32 r;
            bytes32 s;
            address recovered;
            (v, r, s) = _sigAt(sigs, i);
            if (v < 27) {
                v += 27;
            }
            if (v != 27 && v != 28) {
                return FAIL_MAGIC;
            }
            recovered = ecrecover(hash, v, r, s);
            if (!owners[recovered]) {
                return FAIL_MAGIC;
            }
            if (recovered <= last) {
                return FAIL_MAGIC;
            }
            last = recovered;
            count++;
            if (count >= th) {
                return OK_MAGIC;
            }
        }
        return FAIL_MAGIC;
    }

    function _preSigCheck(uint256 sigLen, uint256 _threshold) internal pure returns (bool) {
        if (sigLen == 0 || _threshold == 0) {
            return false;
        }
        if (sigLen % 65 != 0) {
            return false;
        }
        if (sigLen / 65 < _threshold) {
            return false;
        }
        return true;
    }

    function _sigAt(bytes calldata sigs, uint256 index) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        assembly {
            r := calldataload(add(sigs.offset, index))
            s := calldataload(add(sigs.offset, add(index, 32)))
            v := byte(0, calldataload(add(sigs.offset, add(index, 64))))
        }
    }

    /*//////////////////////////////////////////////////////////////
                                QUERIES
    //////////////////////////////////////////////////////////////*/
    function ownerCount() external view returns (uint256) {
        return ownerList.length;
    }
}
