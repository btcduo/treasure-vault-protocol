// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockReceiver {
    uint256 public sum;

    function isTrustedForwarder(address fwd) external pure returns (bool) {
        if (fwd != address(0)) {
            return true;
        }
        return false;
    }

    function increaseSum() external {
        sum++;
    }
}
