// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library GovernErrors {
    /// @notice Zero address provided.
    error ZeroAddr();

    /// @notice Repeated address provided.
    error RepeatedAddr();

    /// @notice Caller is not an owner.
    error NotOwner();

    /// @notice Caller is not this multisig contract.
    error NotSelf();

    /// @notice Transaction id is out of bounds(txId > nonce).
    error TxIdOutOfBounds();

    /// @notice Caller has already approved this transaction.
    error AlreadyApproved();

    /// @notice Transaction has already been executed.
    error AlreadyExecuted();

    /// @notice Address is already an owner.
    error ExistedOwnerAddr();

    /// @notice Address has already been removed.
    error AlreadyRemoved();

    /// @notice duplicate parameters provided.
    error RepeatedParams();

    /// @notice Parameters would permanently lock the multisig.
    error UnsafeParams();

    /// @notice Not enough approvals to execute the transaction.
    error InsufficientApprovedCount();

    /// @notice Low-level call failed.
    error CallFailed();
}

library VaultErrors {
    /// @notice Caller in a clone is not registered governor.
    error NotGovernor();

    /// @notice Reentrant Calls.
    error Reentrant();

    /// @notice Insufficient underlying to operate.
    error InsufficientUnderlying();

    /// @notice Insufficient shares to operate.
    error InsufficientShares();

    /// @notice Insufficient allowance to operate.
    error InsufficientValue();

    /// @notice Supports only EOA in depositWithPermit function.
    error PermitEOAOnly();

    /// @notice Zero addresses.
    error ZeroAssetAddr();
    error ZeroOwnerAddr();
    error ZeroFwdAddr();

    /// @notice Addresses are not contract.
    error InvalidAssetAddr();
    error InvalidOwnerAddr();
    error InvalidFwdAddr();

    /// @notice Repeated addresses.
    error UnsafeParams();

    /// @notice Addresse == template contract.
    error InvalidParams();

    /// @notice Zero address.
    error ZeroAddr();

    /// @notice Zero amount.
    error ZeroAmount();

    /// @notice Zero shares.
    error ZeroShares();

    /// @notice Zero received amount.
    error ZeroReceived();

    /// @notice The clone's ledger has benn corrupted.
    error BadLedger(uint256 ledger, uint256 actual);
}

library StakingErrors {
    /// @notice Zero address provided in the constructor.
    error ZeroInitAddr();

    /// @notice Provided address is not contract in the constructor.
    error InvalidInitAddr();

    /// @notice Repeated address provided in the constructor.
    error RepeatedInitAddr();

    /// @notice Caller is not Multisig governor.
    error NotGovernor();

    /// @notice Zero amount.
    error ZeroAmount();

    /// @notice Zero received amount.
    error ZeroReceived();

    /// @notice Insufficient balances[user] to operate.
    error InsufficientBalance();

    /// @notice Insufficient rewards[user] to operate.
    error InsufficientReward();

    /// @notice Supports only EOA in stakeWithPermit function.
    error PermitEOAOnly();
}

library ForwarderErrors {
    /// @notice UserOp.sender == zero.
    error ZeroSenderAddr();

    /// @notice Target(UserOp.to) == zero.
    error ZeroTargetAddr();

    /// @notice Target(UserOp.to) != contract.
    error InvalidTargetAddr();

    /// @notice UserOp.gasLimit == 0.
    error BadGasLimit();

    /// @notice UserOp.nonce != nonces[UserOp.sender].
    error BadNonce();

    /// @notice UserOp.deadline has expired.
    error ExpiredRequest();

    /// @notice Invalid signature of UserOp.sender.
    error BadSig();

    /// @notice This forwarder is not trusted by the target(UserOp.to).
    error UntrustfulTarget();

    /// @notice Remained gas too low after executing.
    error UnsafeGas();
}
