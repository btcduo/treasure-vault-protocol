// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

contract Vault_Fuzz is Test {
    ProtocolGovernor admin;
    Forwarder fwd;
    Vault impl;
    VaultFactory factory;
    MockERC20 usdt;

    Vault v;

    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address alice;
    address bob;

    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");

        admin = new ProtocolGovernor(owner1, owner2);
        fwd = new Forwarder("Forwarder", "1");

        impl = new Vault();
        factory = new VaultFactory(address(impl), address(admin), address(fwd));

        usdt = new MockERC20("MOCK USDT", "vUSDT");

        alice = makeAddr("ALICE");
        bob = makeAddr("BOB");

        address clone = factory.create(address(usdt));
        v = Vault(clone);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _preFund(address clone, uint256 amt) internal {
        usdt.mint(clone, amt);
        bytes memory data = abi.encodeCall(Vault.sync, ());
        vm.startPrank(owner1);
        uint256 txId = admin.submit(clone, data);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        admin.call(txId);
        vm.stopPrank();
    }

    function _mintAndApprove(address user, uint256 amt) internal {
        usdt.mint(user, amt);

        vm.prank(user);
        usdt.approve(address(v), amt);
    }

    function _sumShares2() internal view returns (uint256) {
        return v.balanceOf(alice) + v.balanceOf(bob);
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ 1
            Single user: deposit -> redeem(all) round-trip
            Verification of accounting and proportions
    //////////////////////////////////////////////////////////////*/
    function testFuzz_roundTrip_deposit_redeem_all(uint96 depRaw) public {
        uint256 dep = uint256(bound(depRaw, 1, 100 ether));
        _mintAndApprove(alice, dep);

        vm.startPrank(alice);
        uint256 shares = v.deposit(alice, dep);
        vm.assume(shares > 0);

        // accounting: should be same without donation.
        assertEq(v.totalUnderlying(), usdt.balanceOf(address(v)));
        assertEq(v.totalSupply(), shares);
        assertEq(v.balanceOf(alice), shares);

        uint256 out = v.redeem(alice, shares);

        // round-trip: for a non-fee-on-transfer ERC20, redeem should return the exact amount deposited.
        assertEq(out, dep);

        assertEq(v.totalUnderlying(), 0);
        assertEq(v.totalSupply(), 0);
        assertEq(v.balanceOf(alice), 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ 2
     Two users: deposit A + deposit B -> Alice withdraw random amount (below deposited amount of Alice)
     Verifies: CEIL rounding prevents Alice from receiving more assets via paying less shares.
    //////////////////////////////////////////////////////////////*/
    function testFuzz_twoUsers_withdrawWithinAliceLimit(uint96 aRaw, uint96 bRaw, uint96 wdRaw) public {
        uint256 a = uint256(bound(aRaw, 100, 100 ether));
        uint256 b = uint256(bound(bRaw, 100, 100 ether));
        uint256 pre = uint256(bound(aRaw, 1, 100));

        // enables unequal conversion between underlying and supply.
        _preFund(address(v), pre);

        _mintAndApprove(alice, a);
        _mintAndApprove(bob, b);

        vm.prank(alice);
        uint256 aliceShares = v.deposit(alice, a);

        vm.prank(bob);
        v.deposit(bob, b);

        // Alice takes the max assets(floor) back via redeem
        uint256 tu = v.totalUnderlying();
        uint256 ts = v.totalSupply();
        uint256 aliceMaxAssets = Math.mulDiv(aliceShares, tu, ts, Math.Rounding.Floor);

        vm.assume(aliceMaxAssets > 0);
        uint256 wd = uint256(bound(wdRaw, 1, aliceMaxAssets));

        uint256 aliceSharesBefore = v.balanceOf(alice);
        uint256 vaultBalBefore = usdt.balanceOf(address(v));
        uint256 tuBefore = v.totalUnderlying();

        vm.startPrank(alice);
        uint256 sharesSpent = v.withdraw(alice, wd);
        vm.stopPrank();

        // core: CEIL rounding in withdraw, must: sharesSpent <= aliceSharesBefore
        assertLe(sharesSpent, aliceSharesBefore);

        // accounting
        assertEq(v.totalUnderlying(), tuBefore - wd);
        assertEq(usdt.balanceOf(address(v)), vaultBalBefore - wd);

        // shares reducing
        assertEq(v.balanceOf(alice), aliceSharesBefore - sharesSpent);

        // total supply equivalent with _sumshares2(), only alice and bob are involved.
        assertEq(v.totalSupply(), _sumShares2());

        // should be equal without donation.
        assertEq(v.totalUnderlying(), usdt.balanceOf(address(v)));
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ 3
     Two users: deposit A + deposit B -> Alice redeem random shares (below deposited amount of Alice)
     Verifies: FLOOR rounding prevents Alice from receiving more assets via paying less shares.
    //////////////////////////////////////////////////////////////*/
    function testFuzz_twoUsers_redeemShares(uint96 aRaw, uint96 bRaw, uint96 rsRaw) public {
        uint256 a = uint256(bound(aRaw, 100, 100 ether));
        uint256 b = uint256(bound(bRaw, 100, 100 ether));

        // enables unequal conversion between underlying and supply.
        uint256 pre = uint256(bound(aRaw, 1, 100));
        _preFund(address(v), pre);

        _mintAndApprove(alice, a);
        _mintAndApprove(bob, b);

        vm.prank(alice);
        uint256 aliceShares = v.deposit(alice, a);

        vm.prank(bob);
        v.deposit(bob, b);

        vm.assume(aliceShares > 0);
        uint256 rs = uint256(bound(rsRaw, 1, aliceShares));

        uint256 tuBefore = v.totalUnderlying();
        uint256 tsBefore = v.totalSupply();
        uint256 vaultBalBefore = usdt.balanceOf(address(v));
        uint256 aliceSharesBefore = v.balanceOf(alice);

        vm.startPrank(alice);
        uint256 out = v.redeem(alice, rs);
        vm.stopPrank();

        // The 'out' must be converted over FLOOR rounding.
        assertEq(usdt.balanceOf(address(v)), vaultBalBefore - out);
        assertEq(v.totalUnderlying(), tuBefore - out);
        assertEq(v.totalSupply(), tsBefore - rs);
        assertEq(v.balanceOf(alice), aliceSharesBefore - rs);

        assertEq(v.totalSupply(), _sumShares2());
        assertEq(v.totalUnderlying(), usdt.balanceOf(address(v)));
    }
}
