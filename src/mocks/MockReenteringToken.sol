// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IVault {
    function deposit(address to, uint256 amt) external returns (uint256);
}

interface IStaking {
    function claimReward() external;
}

contract MockReenteringToken is ERC20 {
    bool public reentered;
    uint256 public sums;

    constructor(string memory name, string memory symbols) ERC20(name, symbols) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address vault = msg.sender;
        uint256 allowed = allowance(from, vault);
        if (allowed != type(uint256).max) {
            _approve(from, vault, allowed - amount);
        }
        if (!reentered) {
            reentered = true;
            IVault(vault).deposit(to, amount);
        }
        _transfer(from, to, amount);
        reentered = false;
        return true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        address staking = msg.sender;
        if (!reentered) {
            reentered = true;
            IStaking(staking).claimReward();
        }
        _transfer(msg.sender, to, value);
        reentered = false;
        return true;
    }

    function isTrustedForwarder(address fwd) external pure returns (bool ok) {
        if (fwd != address(0)) {
            ok = true;
        } else {
            ok = false;
        }
    }

    function sum(uint256 x) external {
        sums = x;
    }

    function burnGas() external {
        uint256 startGas = gasleft();
        while (gasleft() > startGas * 2 / 100) {
            sums = sums * 355 / 1000;
            sums++;
        }
        sums = 0;
    }
}
