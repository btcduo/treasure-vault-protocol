//SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Forge
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

// Handler
import {Protocol_Handler, IVaultLike, IERC20Like, IStakingLike, IForwarderLike} from "./Protocol_Handler.sol";

// Protocol aggregation
import {Vault} from "src/Vault.sol";
import {ProtocolGovernor} from "src/governance/ProtocolGovernor.sol";
import {Forwarder} from "src/Forwarder.sol";
import {VaultFactory} from "src/eip1167/VaultFactory.sol";
import {LinearStaking} from "src/LinearStaking.sol";
import {MockERC20} from "src/mocks/MockERC20.sol";

/// @title Protocol_Invariant_Base
abstract contract Protocol_Invariant_Base is StdInvariant, Test {
    /// @notice Provides logic functions to the ERC-1167 clone.
    Vault template;

    /// @notice Multisig government.
    ProtocolGovernor governor;

    /// @notice ERC-712 based forwarder contract.
    Forwarder fwd;

    /// @notice Deploys the ERC-1167 clone.
    VaultFactory factory;

    LinearStaking staking;

    MockERC20 asset;

    /// @notice ERC-1167 clone contract.
    Vault vault;

    Protocol_Handler handler;

    address owner1;
    uint256 pk1;
    address owner2;
    uint256 pk2;

    address[] actors;
    uint256[] actorPKs;

    function setUp() public {
        _setUpBase();
        _setUpChild();
    }

    function _directVaultSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = Protocol_Handler.act_deposit_direct.selector;
        s[1] = Protocol_Handler.act_withdraw_direct.selector;
        s[2] = Protocol_Handler.act_redeem_direct.selector;
    }

    function _directStakingSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = Protocol_Handler.act_deposit_direct.selector;
        s[1] = Protocol_Handler.act_stake_direct.selector;
        s[2] = Protocol_Handler.act_unstake_direct.selector;
        s[3] = Protocol_Handler.act_skip.selector;
        s[4] = Protocol_Handler.act_claim_direct.selector;
    }

    function _forwardedVaultSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = Protocol_Handler.act_deposit_forwarded.selector;
        s[1] = Protocol_Handler.act_withdraw_forwarded.selector;
        s[2] = Protocol_Handler.act_redeem_forwarded.selector;
    }

    function _forwardedStakingSels() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = Protocol_Handler.act_deposit_forwarded.selector;
        s[1] = Protocol_Handler.act_stake_forwarded.selector;
        s[2] = Protocol_Handler.act_unstake_forwarded.selector;
        s[3] = Protocol_Handler.act_skip.selector;
        s[4] = Protocol_Handler.act_claim_forwarded.selector;
    }
    // Setup ( deploy, makeAddr, etc...)

    function _setUpBase() internal {
        (owner1, pk1) = makeAddrAndKey("OWNER1");
        (owner2, pk2) = makeAddrAndKey("OWNER2");

        // generates the actors.
        uint256 N = 5;
        actors = new address[](N);
        actorPKs = new uint256[](N);
        for (uint256 i; i < N; i++) {
            (address a, uint256 pk) = makeAddrAndKey(string.concat("actor_", vm.toString(i)));
            actors[i] = a;
            actorPKs[i] = pk;
        }

        template = new Vault();
        governor = new ProtocolGovernor(owner1, owner2);
        fwd = new Forwarder("Forwarder", "1");
        factory = new VaultFactory(address(template), address(governor), address(fwd));
        asset = new MockERC20("MOCK USDT", "vUSDT");

        address clone = factory.create(address(asset));
        vault = Vault(clone);
        staking = new LinearStaking(address(vault), address(asset), address(governor), address(fwd));

        handler = _deployHandler();

        targetContract(address(handler));
    }

    // Empty virtual function, override by child contracts.
    function _setUpChild() internal virtual {}

    function _deployHandler() internal returns (Protocol_Handler handler_) {
        handler_ =
            new Protocol_Handler(address(vault), address(asset), address(staking), address(fwd), actors, actorPKs);
    }

    function _setRewardRate(uint256 x) internal {
        bytes memory data = abi.encodeCall(LinearStaking.setRewardRate, (x));
        vm.startPrank(owner1);
        uint256 txId = governor.submit(address(staking), data);
        governor.approve(txId);
        vm.startPrank(owner2);
        governor.approve(txId);
        governor.call(txId);
        vm.stopPrank();
    }
}
