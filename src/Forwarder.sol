//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// OpenZeppelin
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Interfaces
import {IERC1271} from "./interfaces/IERC1271.sol";
import {ITrustedByTarget} from "./interfaces/ITrustedByTarget.sol";

// Errors
import {ForwarderErrors} from "./libraries/Errors.sol";

// Structs
import "./structs/UserOp.sol";

/// @title Forwarder
/// @notice EIP-712 forwarder for ERC-2771 meta-transactions.
/**
 * @dev Safe summaries:
 * Verifies an EIP-712 signature from `op.sender` (compatibility with ERC-1271)
 * Enforces per-sender nonces to prevent replay.
 * Enforces `deadline` to bound signature validaty.
 * Appends `sender` to calldata(20 bytes) so targets can derive `_msgSender()` via ERC-2771.
 * Requires the target to explicitly trust this forwarder via `isTrustedForwarder(address)`.
 */
contract Forwarder {
    using ECDSA for bytes32;

    bytes32 public constant TYPE_HASH =
        keccak256("UserOp(address sender,address to,uint256 gasLimit,uint256 nonce,uint256 deadline,bytes data)");

    bytes32 public constant DOMAIN_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 public immutable _nameHash;
    bytes32 public immutable _versionHash;
    uint256 public immutable _chainId;
    bytes32 public immutable _domainSeparator;

    mapping(address => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deployed(address indexed contract_, string name_, string version_);
    event Verified(address indexed sender, address indexed to);
    event Executed(
        address indexed sender,
        address indexed to,
        uint256 gasLimit,
        uint256 gasLeft,
        uint256 nonce,
        uint256 deadline,
        bytes32 dataHash
    );

    constructor(string memory name_, string memory version_) {
        _nameHash = keccak256(bytes(name_));
        _versionHash = keccak256(bytes(version_));
        _chainId = block.chainid;
        _domainSeparator = _buildDomainSeparator(_nameHash, _versionHash, _chainId, address(this));

        emit Deployed(address(this), name_, version_);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC HELPERS
    //////////////////////////////////////////////////////////////*/
    /// @notice Returns the EIP-712 domain separator for this forwarder.
    /// @dev Recomputes the domain separator when chainId has changed.
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == _chainId) {
            return _domainSeparator;
        } else {
            return _buildDomainSeparator(_nameHash, _versionHash, block.chainid, address(this));
        }
    }

    /// @notice Computes the struct hash for a `UserOp`.
    function structHash(UserOp calldata op) public pure returns (bytes32) {
        return
            keccak256(abi.encode(TYPE_HASH, op.sender, op.to, op.gasLimit, op.nonce, op.deadline, keccak256(op.data)));
    }

    /// @notice Computes the digest to be singed for a `UserOp`.
    function digest(UserOp calldata op) public view returns (bytes32 dig_) {
        bytes32 domainHash_ = domainSeparator();
        bytes32 structHash_ = structHash(op);
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, hex"1901")
            mstore(add(ptr, 0x02), domainHash_)
            mstore(add(ptr, 0x22), structHash_)
            dig_ := keccak256(ptr, 0x42)
        }
    }

    /// @notice Verifies `sig` via ESDSA for an EOA, via ERC-1271 for a contract.
    /// @dev Reverts on mismatch.
    function isValidSignatureNow(address signer, bytes32 hash, bytes calldata sig) public view {
        if (signer.code.length == 0) {
            address recovered = hash.recoverCalldata(sig);
            if (recovered != signer) {
                revert ForwarderErrors.BadSig();
            }
        } else {
            bytes4 magic = IERC1271(signer).isValidSignature(hash, sig);
            if (magic != 0x1626ba7e) {
                revert ForwarderErrors.BadSig();
            }
        }
    }

    /// @notice Validates `UserOp` and `sig` before executing.
    function checkParams(UserOp calldata op, bytes calldata sig) public {
        _checkParams(op, sig);
        emit Verified(op.sender, op.to);
    }

    /*//////////////////////////////////////////////////////////////
                                EXTERNAL
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Executes a meta-transaction on `op.to` on behalf of `op.sender`.
     * @dev Requirements:
     * `op.to` is contract.
     * `op.to` trust this forwarder.
     * `op.nonce` is unused.
     * `op.deadline` is unexpired.
     * `sig` is valid EIP-712 signature by `op.sender`
     * @dev Effects:
     * Increments `nonces[op.sender]`.
     * Calls `op.to` with `op.data || op.sender` and exactly `op.gasLimit` gas.
     * Bubbles up target revert reasons.
     */
    function execute(UserOp calldata op, bytes calldata sig) external returns (bool ok, bytes memory ret) {
        checkParams(op, sig);
        bool trusted = ITrustedByTarget(op.to).isTrustedForwarder(address(this));
        if (!trusted) {
            revert ForwarderErrors.UntrustfulTarget();
        }

        nonces[op.sender] = op.nonce + 1;

        bytes memory data = abi.encodePacked(op.data, op.sender);

        (ok, ret) = op.to.call{gas: op.gasLimit}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (gasleft() <= op.gasLimit / 63) {
            revert ForwarderErrors.UnsafeGas();
        }

        emit Executed(op.sender, op.to, op.gasLimit, gasleft(), op.nonce, op.deadline, keccak256(op.data));
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/
    function _verifySig(UserOp calldata op, bytes calldata sig) internal view {
        isValidSignatureNow(op.sender, digest(op), sig);
    }

    function _checkParams(UserOp calldata op, bytes calldata sig) internal view {
        if (op.sender == address(0)) {
            revert ForwarderErrors.ZeroSenderAddr();
        }
        if (op.to == address(0)) {
            revert ForwarderErrors.ZeroTargetAddr();
        }
        if (op.to.code.length == 0) {
            revert ForwarderErrors.InvalidTargetAddr();
        }
        if (op.gasLimit == 0) {
            revert ForwarderErrors.BadGasLimit();
        }
        if (op.nonce != nonces[op.sender]) {
            revert ForwarderErrors.BadNonce();
        }
        if (op.deadline < block.timestamp) {
            revert ForwarderErrors.ExpiredRequest();
        }
        _verifySig(op, sig);
    }

    function _buildDomainSeparator(bytes32 nameHash_, bytes32 versionHash_, uint256 chainId_, address thisAddr_)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOMAIN_HASH, nameHash_, versionHash_, chainId_, thisAddr_));
    }
}
