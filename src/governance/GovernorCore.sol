// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../libraries/Errors.sol";

/// @title GovernorCore used in conjunction with the upgradeable ProtocolGovernor.
/// @notice Core governance logic for a 2+ owner approval-based executor.
/// @dev Invariants:
/// - threshold must satisfy: 2 <= threshold <= ownerList.length.
/// - governance state changes must be executed via onlySelf (queued tx).
/// - external interactions must NOT use delegatecall (avoid context/storage corruption).
abstract contract GovernorCore {
    /// @notice Contains the params of transaction.
    struct Tx {
        address target;
        bytes data;
        bool executed;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @dev threshold is constrained by ownerList length: 2..ownerList.length (see _modifyThreshold).
    uint256 public threshold;

    /// @dev Incremented in _submit(address, bytes).
    uint256 public nonce;

    mapping(uint256 => Tx) public txs;

    address[] public ownerList;

    mapping(address => bool) public owners;

    /// @dev ownerIndex stores index+1 (0 means non-owner).
    mapping(address => uint256) public ownerIndex;

    mapping(uint256 => mapping(address => bool)) public approved;

    /*//////////////////////////////////////////////////////////////
                    CONSTRUCTOR & PARAMETER SETTINGS
    //////////////////////////////////////////////////////////////*/
    /// @notice Assigns two addresses as owners.
    /// @notice Sets the threshold as two.
    /// @dev NO ZERO address, NOT SAME address.
    constructor(address _owner1, address _owner2) {
        if (_owner1 == address(0) || _owner2 == address(0)) {
            revert GovernErrors.ZeroAddr();
        }
        if (_owner1 == _owner2) {
            revert GovernErrors.RepeatedAddr();
        }

        ownerList.push(_owner1);
        ownerIndex[_owner1] = ownerList.length;
        owners[_owner1] = true;
        ownerList.push(_owner2);
        ownerIndex[_owner2] = ownerList.length;
        owners[_owner2] = true;
        threshold = 2;
    }

    /*//////////////////////////////////////////////////////////////
                            ACESS CONTROL
    //////////////////////////////////////////////////////////////*/
    modifier onlyOwner() {
        if (!owners[msg.sender]) {
            revert GovernErrors.NotOwner();
        }
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert GovernErrors.NotSelf();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event OwnerAdded(address indexed who);
    event OwnerRemoved(address indexed who);
    event ThresholdModified(uint256 oldThreshold, uint256 newThreshold);
    event Submitted(address indexed proposer, uint256 txId);
    event Approved(address indexed approver, uint256 txId, uint256 approvedCount, uint256 needCount);
    event Executed(address indexed executor, address target, bytes4 selector, bool executed);

    /*//////////////////////////////////////////////////////////////
                                ONLYSELF
    //////////////////////////////////////////////////////////////*/
    function addOwner(address addr) external onlySelf {
        _addOwner(addr);
    }

    function removeOwner(address addr) external onlySelf {
        _removeOwner(addr);
    }

    function modifyThreshold(uint256 newThresh) external onlySelf {
        _modifyThreshold(newThresh);
    }

    /*//////////////////////////////////////////////////////////////
                                CORES
    //////////////////////////////////////////////////////////////*/
    /// @dev Addr not zero, not existed.
    function _addOwner(address addr) internal onlySelf {
        _notZeroAddr(addr);

        if (owners[addr] || ownerIndex[addr] != 0) {
            revert GovernErrors.ExistedOwnerAddr();
        }

        ownerList.push(addr);
        ownerIndex[addr] = ownerList.length;
        owners[addr] = true;
        emit OwnerAdded(addr);
    }

    /// @dev Addr not zero, still owner, [ 2 <= threshold <= ownerList.length ]
    function _removeOwner(address addr) internal onlySelf {
        _notZeroAddr(addr);

        if (!owners[addr] || ownerIndex[addr] == 0) {
            revert GovernErrors.AlreadyRemoved();
        }
        if (threshold >= ownerList.length || ownerList.length <= 2) {
            revert GovernErrors.UnsafeParams();
        }

        uint256 idxPlusOne = ownerIndex[addr];
        uint256 idx = idxPlusOne - 1;
        uint256 lastIdx = ownerList.length - 1;
        if (idx != lastIdx) {
            address lastOwner = ownerList[lastIdx];
            ownerList[idx] = lastOwner;
            ownerIndex[lastOwner] = idxPlusOne;
        }
        ownerList.pop();
        ownerIndex[addr] = 0;
        owners[addr] = false;
        emit OwnerRemoved(addr);
    }

    /// @dev Satisfy: [ 2 <= newThresh <= ownerList.length ], [ newThresh != threshold ]
    function _modifyThreshold(uint256 newThresh) internal onlySelf {
        if (newThresh > ownerList.length || newThresh < 2) {
            revert GovernErrors.UnsafeParams();
        }
        if (newThresh == threshold) {
            revert GovernErrors.RepeatedParams();
        }

        uint256 oldThresh = threshold;
        threshold = newThresh;
        emit ThresholdModified(oldThresh, newThresh);
    }

    /// @dev Satisfy: _target not zero.
    /// @dev Allows zero _data for upgradibility.
    function _submit(address _target, bytes memory _data) internal returns (uint256 txId) {
        _notZeroAddr(_target);
        txId = nonce++;
        txs[txId] = Tx({target: _target, data: _data, executed: false});
        emit Submitted(msg.sender, txId);
    }

    /// @dev Satisfy: txId MUST not above the nonce, transaction unapproved and not executed.
    function _approve(uint256 txId) internal {
        _validTxId(txId, nonce);
        _notApproved(approved[txId][msg.sender]);
        _notExecuted(txs[txId].executed);

        approved[txId][msg.sender] = true;
        uint256 count = _approvedCount(txId);
        emit Approved(msg.sender, txId, count, threshold);
    }

    /// @dev Satisfy:
    /// - txId NUST not above the nonce
    /// - approved count reaches the threshold
    /// - transaction's target address not zero
    /// - transaction not executed
    function _call(uint256 txId) internal {
        _validTxId(txId, nonce);
        if (threshold > _approvedCount(txId)) {
            revert GovernErrors.InsufficientApprovedCount();
        }
        Tx storage t = txs[txId];
        _notZeroAddr(t.target);
        _notExecuted(t.executed);

        t.executed = true;
        (bool ok, bytes memory ret) = t.target.call(t.data);
        if (!ok) {
            if (t.target == address(this)) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            } else {
                revert GovernErrors.CallFailed();
            }
        }

        emit Executed(msg.sender, t.target, bytes4(t.data), t.executed);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    /// @dev Calculates approved count.
    function _approvedCount(uint256 txId) internal view returns (uint256 count) {
        for (uint256 i; i < ownerList.length; i++) {
            if (approved[txId][ownerList[i]] == true) {
                count++;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                VERIFICAIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev Revert if the transaction is approved.
    function _notApproved(bool approved_) internal pure {
        if (approved_) {
            revert GovernErrors.AlreadyApproved();
        }
    }

    /// @dev Revert if the transaction is executed.
    function _notExecuted(bool executed_) internal pure {
        if (executed_) {
            revert GovernErrors.AlreadyExecuted();
        }
    }

    /// @dev Revert if the address is zero.
    function _notZeroAddr(address addr) internal pure {
        if (addr == address(0)) {
            revert GovernErrors.ZeroAddr();
        }
    }

    /// @dev Revert if the txId greater than the nonce.
    function _validTxId(uint256 txId, uint256 _nonce) internal pure {
        if (txId > _nonce) {
            revert GovernErrors.TxIdOutOfBounds();
        }
    }
}
