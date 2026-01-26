//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ITrustedByTarget {
    function isTrustedForwarder(address fwd) external view returns (bool);
}
