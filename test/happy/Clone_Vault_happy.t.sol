// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {Vault} from "src/Vault.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/// @title Clone+Vault(Template) happy-path tests
/// @notice Validates the expected successful flow:
/// Initialize: VaultFactory.create(MockERC20) -> BaseCloneFactory._deployClone(salt) -> Vault.initialize(MockERC20, ProtocolGovernor).
/// Works for user in the clone(Vault-based): deposit / depositWithPermit -> withdraw / redeem.
/// Works for owner in the clone(Vault-based): skimAssetSurplus.
contract Clone_Vault_happy is Test {
    ProtocolGovernor admin;
    Forwarder fwd;
    Vault vault;
    VaultFactory factory;
    MockERC20 usdt;
    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;
    address alice;
    uint256 alicePK;

    /// @notice Source: OpenZeppelin's ERC20Permit.sol, used to calculate the user's signature(see: _sig()).
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @notice Owner's duties: invokes skimShareSurplus / skimAssetSurplus in the clone.
    function setUp() public {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");
        admin = new ProtocolGovernor(owner1, owner2);
        fwd = new Forwarder("Forwarder", "1");
        vault = new Vault();
        factory = new VaultFactory(address(vault), address(admin), address(fwd));
        usdt = new MockERC20("MOCK USDT", "vUSDT");
        (alice, alicePK) = makeAddrAndKey("ALICE");
    }

    /*///////////////////////////////////////////
                        Helpers
    ///////////////////////////////////////////*/
    /// @notice Deploys and initializes a clone instance.
    function _initFor(MockERC20 token) internal returns (Vault clone) {
        clone = Vault(factory.create(address(token)));
    }

    /// @notice Mints the clone's tokens to an address.
    function _mintTo(address user_, uint256 amount) internal {
        usdt.mint(user_, amount);
    }

    /// @notice Calls the depositWithPermit in the clone instance.
    function _dpstTo(Vault c, MockERC20 token, address to, uint256 amount, uint256 deadline)
        internal
        returns (uint256)
    {
        return c.depositWithPermit(to, amount, amount, deadline, _sig(c, token, amount, deadline));
    }

    /// @notice Source of nonce_: OpenZeppelin's Nonces.sol
    /// @notice Source of hash_: OpenZeppelin's ERC20Permit.sol
    /// @notice Source of digest_: OpenZepplin's EIP712.sol
    function _sig(Vault c, MockERC20 token, uint256 value, uint256 deadline) internal view returns (bytes memory) {
        uint256 nonce_ = token.nonce(alice);
        bytes32 hash_ = keccak256(abi.encode(PERMIT_TYPEHASH, alice, address(c), value, nonce_, deadline));
        bytes32 digest_ = token.digest(hash_);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest_);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Work flow: submit( 1 owner needed ) -> approve( 2 owner ) -> call( 1 owner ).
    function _adminInvokes(address to, bytes memory data) internal {
        vm.startPrank(owner1);
        uint256 txId = admin.submit(to, data);
        admin.approve(txId);
        vm.startPrank(owner2);
        admin.approve(txId);
        admin.call(txId);
        vm.stopPrank();
    }

    /*///////////////////////////////////////////
                        Tests
    ///////////////////////////////////////////*/
    /// @notice Deploys the clone then initializes it on the template(Vault).
    /// @dev The admin and the asset are correctly stored in the clone.
    function test_init_usdt_OK() public {
        Vault clone = Vault(factory.create(address(usdt)));
        assertEq(address(clone.asset()), address(usdt));
        assertEq(clone.governor(), address(admin));
        assertEq(clone.totalUnderlying(), 0);
        assertEq(clone.totalSupply(), 0);
    }

    /// @notice Deposits tokens into the clone via deposit().
    /// @dev Requires prior ERC20 approval to the clone.
    /// @dev Flow: mint -> deploy+init clone -> approve(clone, 200) -> deposit(user, 100) + deposit(user1, 100) -> assert balances.
    function test_deposit_OK() public {
        address user = address(0xb0b);
        address user1 = address(0xa1a);
        vm.startPrank(user);
        _mintTo(user, 200);
        Vault clone = _initFor(usdt);
        usdt.approve(address(clone), 200);
        clone.deposit(user, 100);
        clone.deposit(user1, 100);
        vm.stopPrank();
        uint256 balance0 = clone.balanceOf(user);
        assertEq(clone.balanceOf(user1), balance0);
        vm.stopPrank();
    }

    /// @notice Deposits tokens into the clone via depositWithPermit().
    /// @dev Token allowance is granted via the user's signature, without a prior on-chain approval.
    /// @dev Flow: mint -> deploy+init clone -> construct signature -> depositWithPermit(alice, ... , signature) -> assert balances.
    function test_depositWithPermit_OK() public {
        vm.startPrank(alice);
        uint256 amt = 200;
        uint256 deadline = block.timestamp + 1;
        _mintTo(alice, amt);
        Vault clone = _initFor(usdt);
        bytes memory sig = _sig(clone, usdt, amt, deadline);
        uint256 shares = clone.depositWithPermit(alice, amt, amt, deadline, sig);
        assertEq(amt, shares);
        vm.stopPrank();
    }

    /// @notice Withdraws tokens from the clone via withdraw().
    /// @dev Converts inputed tokens to supplied shares.
    /// @dev Flow: mint -> deploy+init clone -> depositWithPermit(...) -> withdraw(alice, amt) -> assert balances.
    function test_withdraw_OK() public {
        vm.startPrank(alice);
        uint256 amt = 200;
        uint256 deadline = block.timestamp + 1;
        _mintTo(alice, amt);
        Vault clone = _initFor(usdt);
        uint256 shares = _dpstTo(clone, usdt, alice, amt, deadline);
        uint256 beforeShare = clone.balanceOf(alice);
        uint256 beforeUsdt = usdt.balanceOf(alice);
        clone.withdraw(alice, amt);
        assertEq(shares, amt);
        assertEq(clone.balanceOf(alice), beforeShare - 200);
        assertEq(usdt.balanceOf(alice), beforeUsdt + 200);
    }

    /// @notice Redeems tokens from the clone via redeem().
    /// @dev Converts inputed shares to supplied tokens.
    /// @dev Flow: mint -> deploy+init clone -> depositWithPermit(...) -> redeem(alice, amt) -> assert balances.
    function test_redeem_OK() public {
        vm.startPrank(alice);
        uint256 amt = 200;
        uint256 deadline = block.timestamp + 1;
        _mintTo(alice, amt);
        Vault clone = _initFor(usdt);
        uint256 shares = _dpstTo(clone, usdt, alice, amt, deadline);
        uint256 beforeShare = clone.balanceOf(alice);
        uint256 beforeUsdt = usdt.balanceOf(alice);
        clone.redeem(alice, shares);
        assertEq(clone.balanceOf(alice), beforeShare - 200);
        assertEq(usdt.balanceOf(alice), beforeUsdt + 200);
    }

    /// @notice Skims three party's tokens to the treasury.
    /// @dev Flow: mint -> mint tokens into clone -> admin invokes skimAssetSurplus -> assert balances.
    function test_skimAssetSurplus_OK() public {
        Vault clone = _initFor(usdt);
        usdt.mint(address(clone), 200);
        bytes memory data = abi.encodeCall(Vault.skimAssetSurplus, (alice));
        uint256 assetOfClone = usdt.balanceOf(address(clone));
        uint256 assetOfAlice = usdt.balanceOf(alice);
        _adminInvokes(address(clone), data);
        assertEq(usdt.balanceOf(address(clone)), assetOfClone - 200);
        assertEq(usdt.balanceOf(alice), assetOfAlice + 200);
    }
}
