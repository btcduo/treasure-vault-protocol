//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library SplitSig {
    error BadSig();

    function split(bytes calldata sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        if (sig.length != 65 && sig.length != 64) {
            revert BadSig();
        }
        if (sig.length == 65) {
            assembly {
                r := calldataload(sig.offset)
                s := calldataload(add(sig.offset, 32))
                v := byte(0, calldataload(add(sig.offset, 64)))
            }
        } else {
            bytes32 vs;
            assembly {
                r := calldataload(sig.offset)
                vs := calldataload(add(sig.offset, 32))
            }
            s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            v = uint8((uint256(vs) >> 255) + 27);
        }
    }
}
