//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct UserOp {
    address sender;
    address to;
    uint256 gasLimit;
    uint256 nonce;
    uint256 deadline;
    bytes data;
}
