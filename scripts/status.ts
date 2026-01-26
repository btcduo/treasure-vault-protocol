import "dotenv/config";
import { ethers } from "ethers";

function mustEnv(name: string): string {
    const v = process.env[name];
    if(!v || v.trim() === "") throw new Error(`Missing Env: ${name}`);
    return v.trim();
}

function envOr(name: string, fallback: string): string {
    const v = process.env[name];
    return v && v.trim() !== "" ? v.trim() : fallback;
}

function now(): number {
    return Math.floor(Date.now() / 1000);
}

const forwarderAbi = [
    "function nonces(address) view returns(uint256)"
];

const assetAbi = [
    "function balanceOf(address) view returns(uint256)"
];

const vaultAbi = [
    "function totalSupply() view returns(uint256)",
    "function totalUnderlying() view returns(uint256)",
    "function balanceOf(address) view returns(uint256)"
];

const stakingAbi = [
    "function totalStaked() view returns(uint256)",
    "function balances(address) view returns(uint256)",
    "function rewards(address) view returns(uint256)"
];

const rewardAbi = [
    "function balanceOf(address) view returns(uint256)"
];

async function main() {
    const action = process.argv[2];
    if(!action || !["latest"].includes(action)) {
        console.log("Usage: pnpm status:latest");
        process.exit(1);
    }

    const rpc = mustEnv("SEPOLIA_RPC_URL");

    // keys
    const userPk = envOr("USER_PRIVATE_KEY", mustEnv("OWNER1_PRIVATE_KEY"));

    // addrs
    const forwarderAddr = envOr("FORWARDER_ADDR", "0x65db83e93dC958dd5766e8cA014F88847707019C");
    const assetAddr = envOr("ASSET_ADDR", "0x6CCf1d69fEba6443fe08c8743bA9F4975270941E");
    const vaultAddr = envOr("VAULT_ADDR", "0x513896313649854066ffFF133c4d0C6e3183b0b9");
    const stakingAddr = envOr("STAKING_ADDR", "0x96aE8362aa05bF592c51E8b04e5DfE45f40bF74C");
    const rewardAddr = envOr("REWARD_ADDR", "0x7126766f64EdEc247Bf7431792b284dBe4818843");

    const provider = new ethers.JsonRpcProvider(rpc);

    const user = new ethers.Wallet(userPk, provider);

    const forwarder = new ethers.Contract(forwarderAddr, forwarderAbi, provider);
    const asset = new ethers.Contract(assetAddr, assetAbi, provider);
    const vault = new ethers.Contract(vaultAddr, vaultAbi, provider);
    const staking = new ethers.Contract(stakingAddr, stakingAbi, provider);
    const reward = new ethers.Contract(rewardAddr, rewardAbi, provider);

    const userAddr = await user.getAddress();

    if(action === "latest") {
        const nonce: bigint = await forwarder.nonces(userAddr);
        const assets: bigint = await asset.balanceOf(userAddr);
        const shares: bigint = await vault.balanceOf(userAddr);
        const staked: bigint = await staking.balances(userAddr);
        const pending: bigint = await staking.rewards(userAddr);
        const rewards: bigint = await reward.balanceOf(userAddr);

        const _totalUnderlying: bigint = await vault.totalUnderlying();
        const _totalSupply: bigint = await vault.totalSupply();
        
        const _totalStaked: bigint = await staking.totalStaked();

        console.log("user:", userAddr.toString());
        console.log("fwd     nonce   =", nonce.toString());
        console.log("asset   tokens  =", assets.toString());
        console.log("vault   shares  =", shares.toString());
        console.log("staked  shares  =", staked.toString());
        console.log("pending rewards =", pending.toString());
        console.log("reward  tokens  =", rewards.toString());
        console.log("vault:", vaultAddr.toString());
        console.log("totalUnderlying =", _totalUnderlying.toString());
        console.log("totalSupply     =", _totalSupply.toString());
        console.log("staking:", stakingAddr.toString());
        console.log("totalStaked     =", _totalStaked.toString());
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});