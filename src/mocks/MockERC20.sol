// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockERC20 is ERC20Permit {
    constructor(string memory name, string memory symbols) ERC20(name, symbols) ERC20Permit(name) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function nonce(address owner) external view returns (uint256) {
        return nonces(owner);
    }

    function digest(bytes32 typeHash) external view returns (bytes32) {
        return _hashTypedDataV4(typeHash);
    }
}
