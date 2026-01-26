// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ILogic {
    function initialize(address asset, address governor, address fwd) external;
}
