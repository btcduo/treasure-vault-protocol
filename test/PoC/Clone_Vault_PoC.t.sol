// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {BaseCloneFactory} from "src/eip1167/BaseCloneFactory.sol";
import {Vault} from "src/Vault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";
import {MockReenteringToken} from "src/mocks/MockReenteringToken.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {VaultErrors} from "src/libraries/Errors.sol";

/// @title Clone+Vault(Template) PoC-path tests.
/// @notice Includes the common vulnerable points:
/// Template contract can be initialized by a malicious address.
/// Reentrancy attacks.
/// share mis-accounting allows leak value from remaining shareholders by an attacker.
contract Clone_Vault_PoC is Test {
    ProtocolGovernor admin;
    Forwarder fwd;
    Vault vault;
    VaultFactory factory;
    MockERC20 usdt;
    MockReenteringToken badToken;
    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address alice;
    uint256 alicePK;
    address attacker;

    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");
        admin = new ProtocolGovernor(owner1, owner2);
        fwd = new Forwarder("Forwarder", "1");
        vault = new Vault();
        factory = new VaultFactory(address(vault), address(admin), address(fwd));
        usdt = new MockERC20("MOCK USDT", "vUSDT");
        badToken = new MockReenteringToken("Reenter", "vReenter");
        (alice, alicePK) = makeAddrAndKey("ALICE");
        attacker = makeAddr("ATTACKER");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    // Deploys and initializes a clone(`token`) instance by `who`.
    function _deployClone(address who, address token) internal returns (Vault clone) {
        vm.prank(who);
        address c = factory.create(token);
        clone = Vault(c);
    }

    // Transfers `amt` to `clone` without invoking `deposit()`.
    function _preFundUnderlying(address clone, uint256 amt) internal {
        address funder = makeAddr("FUNDER");
        usdt.mint(funder, amt);
        vm.prank(funder);
        usdt.transfer(clone, amt);
    }

    // Deposits `amt` of `usdt` to a `dead` address.
    function _preFundSupply(address clone, uint256 amt) internal {
        address funder = makeAddr("FUNDER");
        address dead = 0x000000000000000000000000000000000000dEaD;
        usdt.mint(funder, amt);
        vm.prank(funder);
        usdt.approve(clone, amt);
        vm.prank(funder);
        Vault(clone).deposit(dead, amt);
    }

    // Calls via Multisig governance.
    function _governorCall(address to, bytes memory data) internal {
        vm.startPrank(owner1);
        uint256 txId = admin.submit(to, data);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        admin.call(txId);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Proof: Vault(template contract) cannot be initialized by `attacker`.
    function test_PoC_initialize_template_revert() public {
        vm.startPrank(attacker);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(usdt), address(admin), address(fwd));
    }

    /// @notice Proof: A single token can be deployed at most once.
    function test_PoC_duplicate_deploy_usdt_revert() public {
        factory.create(address(usdt));
        vm.expectRevert(BaseCloneFactory.AlreadyDeployed.selector);
        factory.create(address(usdt));
    }

    /// @notice Proof: Reentrancy attacks is prevented by `nonReentrant`.
    function test_PoC_Reentrant_Failed() public {
        Vault clone = _deployClone(attacker, address(badToken));
        badToken.mint(attacker, 200);
        vm.startPrank(attacker);
        badToken.approve(address(clone), 200);
        vm.expectRevert(VaultErrors.Reentrant.selector);
        clone.deposit(attacker, 200);
    }

    /**
     * @notice Proof: Share accounting with FLOOR.
     * @dev Workflow:
     * deploys and initializes clone ->
     *  pre-funding totalUnderlying( amount: 133 ) ->
     *   pre-funding totalSupply( amount: 20 ) ->
     *    deposit `amt = 15` by `attacker` ->
     *     assert balances (15 * 20 / 133 ≈ 2.25) == 2
     */
    function test_PoC_deposit_shareAccounting_floor() public {
        Vault clone = _deployClone(attacker, address(usdt));
        _preFundUnderlying(address(clone), 113);
        _preFundSupply(address(clone), 20);
        bytes memory data = abi.encodeCall(Vault.sync, ());
        _governorCall(address(clone), data);
        uint256 totalUnderlying_ = clone.totalUnderlying();
        uint256 totalSupply_ = clone.totalSupply();
        assertEq(totalUnderlying_, 113 + 20);
        assertEq(totalSupply_, 20);
        uint256 amt = 15;
        uint256 preCal = amt * totalSupply_ / totalUnderlying_;
        usdt.mint(attacker, amt);
        vm.startPrank(attacker);
        usdt.approve(address(clone), amt);
        clone.deposit(attacker, amt);
        assertEq(clone.totalUnderlying(), totalUnderlying_ + 15);
        assertEq(clone.balanceOf(attacker), preCal);
        assertEq(preCal, 2);
    }

    /**
     * @notice Proof: Share accounting with CEIL.
     * @dev Workflow:
     * deploys and initializes clone ->
     *  pre-funding totalUnderlying( amount: 133 ) ->
     *   pre-funding totalSupply( amount: 20 ) ->
     *    deposit `amt = 15` by `attacker` ->
     *     REVERT when using `15` to call `withdraw`
     */
    function test_PoC_withdraw_shareAccounting_ceil() public {
        Vault clone = _deployClone(attacker, address(usdt));
        _preFundUnderlying(address(clone), 113);
        _preFundSupply(address(clone), 20);
        bytes memory data = abi.encodeCall(Vault.sync, ());
        _governorCall(address(clone), data);
        uint256 damt = 15;
        usdt.mint(attacker, damt);
        vm.startPrank(attacker);
        usdt.approve(address(clone), damt);
        clone.deposit(attacker, damt);
        uint256 sharesOf = clone.balanceOf(attacker);
        assertTrue(clone.previewWithdraw(damt) > sharesOf);
        vm.expectRevert(VaultErrors.InsufficientShares.selector);
        clone.withdraw(attacker, damt);
    }
}
