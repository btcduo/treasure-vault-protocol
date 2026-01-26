// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {Forwarder} from "../src/Forwarder.sol";
import {Vault} from "../src/Vault.sol";
import {VaultFactory} from "../src/eip1167/VaultFactory.sol";
import {ProtocolGovernor} from "../src/governance/ProtocolGovernor.sol";
import {LinearStaking} from "../src/LinearStaking.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract DeploySepolia is Script {
    // output
    string internal constant OUT = "deployments/sepolia.json";
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    function run() external {
        // --- env ---
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        uint256 owner1Pk = vm.envUint("OWNER1_PRIVATE_KEY");
        uint256 owner2Pk = vm.envUint("OWNER2_PRIVATE_KEY");

        require(owner1Pk != 0, "zero owner1 private key");
        require(owner2Pk != 0, "zero owner2 private key");

        address deployer = vm.addr(deployerPk);
        address owner1 = vm.addr(owner1Pk);
        address owner2 = vm.addr(owner2Pk);

        require(block.chainid == SEPOLIA_CHAIN_ID, "wrong chainId (need sepolia)");
        require(owner1 != address(0), "zero owner1 address");
        require(owner2 != address(0), "zero owner2 address");
        require(owner2 != owner1, "same owner addresses");

        // --- deploy ---
        vm.startBroadcast(deployerPk);

        Forwarder fwd = new Forwarder("ProtocolForwarder", "1");
        ProtocolGovernor gov = new ProtocolGovernor(owner1, owner2);

        Vault vaultTemplate = new Vault();
        VaultFactory factory = new VaultFactory(address(vaultTemplate), address(gov), address(fwd));

        MockERC20 asset = new MockERC20("Mock Asset", "mAST");
        MockERC20 reward = new MockERC20("Mock Reward", "mRWD");

        // mint assets to the onwers.
        asset.mint(owner1, 1_000_000e18);
        asset.mint(owner2, 1_000_000e18);

        // depoloys and initializes the vault clone（share token）
        address vaultClone = factory.create(address(asset));

        // stakingToken = vaultClone share；rewardToken = reward
        LinearStaking staking = new LinearStaking(vaultClone, address(reward), address(gov), address(fwd));

        // pre-funding reward tokens to staking contract.
        reward.mint(address(staking), 500_000e18);

        vm.stopBroadcast();

        // set reward rate by multisig.
        uint256 newRate = 1e16; // 0.01 token / sec
        bytes memory data = abi.encodeCall(LinearStaking.setRewardRate, (newRate));

        vm.startBroadcast(owner1Pk);
        uint256 txId = gov.submit(address(staking), data);
        gov.approve(txId);
        vm.stopBroadcast();

        vm.startBroadcast(owner2Pk);
        gov.approve(txId);
        gov.call(txId);
        vm.stopBroadcast();

        // --- deployments/sepolia.json ---
        string memory obj = "sepolia";
        string memory json = vm.serializeUint(obj, "chainId", block.chainid);
        json = vm.serializeAddress(obj, "deployer", deployer);
        json = vm.serializeAddress(obj, "owner1", owner1);
        json = vm.serializeAddress(obj, "owner2", owner2);

        json = vm.serializeAddress(obj, "Forwarder", address(fwd));
        json = vm.serializeAddress(obj, "ProtocolGovernor", address(gov));
        json = vm.serializeAddress(obj, "VaultTemplate", address(vaultTemplate));
        json = vm.serializeAddress(obj, "VaultFactory", address(factory));
        json = vm.serializeAddress(obj, "AssetToken", address(asset));
        json = vm.serializeAddress(obj, "RewardToken", address(reward));
        json = vm.serializeAddress(obj, "VaultClone", vaultClone);
        json = vm.serializeAddress(obj, "LinearStaking", address(staking));

        vm.writeJson(json, OUT);

        // --- print ---
        console2.log("Forwarder        :", address(fwd));
        console2.log("ProtocolGovernor :", address(gov));
        console2.log("VaultTemplate    :", address(vaultTemplate));
        console2.log("VaultFactory     :", address(factory));
        console2.log("AssetToken       :", address(asset));
        console2.log("RewardToken      :", address(reward));
        console2.log("VaultClone       :", vaultClone);
        console2.log("LinearStaking    :", address(staking));
        console2.log("Wrote deployments:", OUT);
    }
}
