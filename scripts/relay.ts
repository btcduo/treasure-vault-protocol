import "dotenv/config";
import { ethers } from "ethers";

type UserOp = {
    sender: string;
    to: string;
    gasLimit: bigint;
    nonce: bigint;
    deadline: bigint;
    data: string;
};

type Permit = {
    owner: string;
    spender: string;
    value: bigint;
    nonce: bigint;
    deadline: bigint;
};

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
    "function name() pure returns(string)",
    "function nonces(address) view returns(uint256)",
    "function execute((address sender,address to,uint256 gasLimit,uint256 nonce,uint256 deadline,bytes data), bytes sig) returns(bool, bytes)"
];

const assetAbi = [
    "function name() pure returns(string)",
    "function nonces(address) view returns(uint256)",
    "function balanceOf(address) view returns(uint256)"
];

const vaultAbi = [
    "function name() pure returns(string)",
    "function balanceOf(address) view returns(uint256)",
    "function depositWithPermit(address to, uint256 amount, uint256 value, uint256 deadline, bytes sig) returns(uint256 shares)",
    "function redeem(address to, uint256 shares) returns(uint256 amount)",
    "function nonces(address) view returns(uint256)" // ERC20Permit nonce
];

const stakingAbi = [
    "function name() pure returns(string)",
    "function balances(address) view returns(uint256)",
    "function rewards(address) view returns(uint256)",
    "function stakeWithPermit(uint256 amount,uint256 deadline,bytes sig)",
    "function unstake(uint256 amount)",
    "function claimReward()"
];

const rewardAbi = [
    "function name() pure returns(string)",
    "function balanceOf(address) view returns(uint256)"
];

async function main() {
    const action = process.argv[2];
    if(!action || !["deposit", "stake", "unstake", "redeem", "claim"].includes(action)) {
        console.log("Usage: pnpm relay:deposit | stake | unstake | redeem | claim");
        process.exit(1);
    }

    const rpc = mustEnv("SEPOLIA_RPC_URL");

    // keys
    const relayerPk = envOr("RELAYER_PRIVATE_KEY", mustEnv("PRIVATE_KEY"));
    const userPk = envOr("USER_PRIVATE_KEY", mustEnv("OWNER1_PRIVATE_KEY"));

    // addrs
    const forwarderAddr = envOr("FORWARDER_ADDR", "0x65db83e93dC958dd5766e8cA014F88847707019C");
    const assetAddr = envOr("ASSET_ADDR", "0x6CCf1d69fEba6443fe08c8743bA9F4975270941E");
    const vaultAddr = envOr("VAULT_ADDR", "0x513896313649854066ffFF133c4d0C6e3183b0b9");
    const stakingAddr = envOr("STAKING_ADDR", "0x96aE8362aa05bF592c51E8b04e5DfE45f40bF74C");
    const rewardAddr = envOr("REWARD_ADDR", "0x7126766f64EdEc247Bf7431792b284dBe4818843");

    // domains
    const fwdName = envOr("FORWARDER_NAME", "ProtocolForwarder");
    const fwdVersion = envOr("FORWARDER_VERSION", "1");

    const provider = new ethers.JsonRpcProvider(rpc);
    const net = await provider.getNetwork();
    const chainId = Number(net.chainId);

    const relayer = new ethers.Wallet(relayerPk, provider);
    const user = new ethers.Wallet(userPk, provider);

    const forwarder = new ethers.Contract(forwarderAddr, forwarderAbi, provider);
    const asset = new ethers.Contract(assetAddr, assetAbi, provider);
    const vault = new ethers.Contract(vaultAddr, vaultAbi, provider);
    const staking = new ethers.Contract(stakingAddr, stakingAbi, provider);
    const reward = new ethers.Contract(rewardAddr, rewardAbi, provider);

    const userAddr = await user.getAddress();
    const relayerAddr = await relayer.getAddress();

    console.log("chainId    :", chainId);
    console.log("user       :", userAddr);
    console.log("relayer    :", relayerAddr);

    const opGasLimit = 400000n;
    const nonceBefore: bigint = await forwarder.nonces(userAddr);
    const opDeadline = BigInt(now()) + 1800n;
    const amount = 100000000000000000000n;

    // EIP-712 types
    const userOpTypes = {
        UserOp: [
            { name: "sender", type: "address" },
            { name: "to", type: "address" },
            { name: "gasLimit", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" },
            { name: "data", type: "bytes" }
        ]
    };

    const permitTypes = {
        Permit: [
            { name: "owner", type: "address" },
            { name: "spender", type: "address" },
            { name: "value", type: "uint256" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" }
        ]
    };

    const fwdDomain = {
        name: fwdName,
        version: fwdVersion,
        chainId,
        verifyingContract: forwarderAddr
    };

    function buildUserOp(params: {
        sender: string;
        to: string;
        gasLimit: bigint;
        nonce: bigint;
        deadline: bigint;
        data: string;
    }): UserOp {
        return {
            sender: params.sender,
            to: params.to,
            gasLimit: params.gasLimit,
            nonce: params.nonce,
            deadline: params.deadline,
            data: params.data,
        };
    }

    async function signPermit2612(params: {
        token: any;
        tokenAddr: string;
        owner: any;
        ownerAddr: string;
        spender: string;
        value: bigint;
        deadline: bigint;
        chainId: bigint | number;
        permitTypes: any;
        name?: string;
        version?: string;
    }) {
        const nonce: bigint = await params.token.nonces(params.ownerAddr);
        const tokenName: string = params.name ?? (await params.token.name());
        const version = params.version ?? "1";

        const domain = {
            name: tokenName,
            version,
            chainId: params.chainId,
            verifyingContract: params.tokenAddr
        };

        const message: Permit = {
            owner: params.ownerAddr,
            spender: params.spender,
            value: params.value,
            nonce,
            deadline: params.deadline
        };
    
        const sig = await params.owner.signTypedData(domain, params.permitTypes, message);
        return { sig, nonce };
    }

    async function execForwarded(
        forwarder: any,
        relayer: any,
        user: any,
        userAddr: string,
        fwdDomain: any,
        userOpTypes: any,
        op: UserOp,
        nonceBefore: bigint
    ) {
        const opSig = await user.signTypedData(fwdDomain, userOpTypes, op);

        const forwarderWithRelayer = forwarder.connect(relayer);

        const gasEst: bigint = await forwarderWithRelayer.getFunction("execute").estimateGas(op, opSig);
        const gasLimitTx = gasEst + gasEst / 4n + 100000n;

        const tx = await forwarderWithRelayer.getFunction("execute")(op, opSig, { gasLimit: gasLimitTx });
        await tx.wait();

        const nonceAfter: bigint = await forwarder.nonces(userAddr);
        if(nonceAfter !== nonceBefore + 1n) throw new Error("nonce did not increment as expected");

        return tx.hash;
    }

    if(action === "deposit") {
        console.log("forwarder  :", forwarderAddr);
        console.log("vault      :", vaultAddr);

        const assets: bigint = await asset.balanceOf(userAddr);
        if(assets < amount) throw new Error("user has insufficient asset tokens.");

        const permitDeadline = BigInt(now()) + 3600n;

        const { sig: permitSig } = await signPermit2612({
            token: asset,
            tokenAddr: assetAddr,
            owner: user,
            ownerAddr: userAddr,
            spender: vaultAddr,
            value: amount,
            deadline: permitDeadline,
            chainId,
            permitTypes
        });

        const vaultIface = new ethers.Interface(vaultAbi);
        const callData = vaultIface.encodeFunctionData("depositWithPermit", [
            userAddr, amount, amount, permitDeadline, permitSig
        ]);

        const op = buildUserOp({
            sender: userAddr,
            to: vaultAddr,
            gasLimit: opGasLimit,
            nonce: nonceBefore,
            deadline: opDeadline,
            data: callData
        });

        const txHash = await execForwarded(
            forwarder, relayer, user, userAddr, fwdDomain, userOpTypes, op, nonceBefore
        );
        console.log("tx =", txHash);
        console.log("OK: forwarded depositWithPermit succeeded");
        return;
    }

    if(action === "stake") {
        console.log("forwarder  :", forwarderAddr);
        console.log("staking    :", stakingAddr);

        const shares: bigint = await vault.balanceOf(userAddr);
        if(shares < amount) throw new Error("user has insufficient vault shares.");

        const permitDeadline = BigInt(now()) + 3600n;

        const { sig: permitSig } = await signPermit2612({
            token: vault,
            tokenAddr: vaultAddr,
            owner: user,
            ownerAddr: userAddr,
            spender: stakingAddr,
            value: amount,
            deadline: permitDeadline,
            chainId,
            permitTypes
        });

        const stakingIface = new ethers.Interface(stakingAbi);
        const callData = stakingIface.encodeFunctionData("stakeWithPermit", [
            amount, permitDeadline, permitSig
        ]);

        const op = buildUserOp({
            sender: userAddr,
            to: stakingAddr,
            gasLimit: opGasLimit,
            nonce: nonceBefore,
            deadline: opDeadline,
            data: callData
        });

        const txHash = await execForwarded(
            forwarder, relayer, user, userAddr, fwdDomain, userOpTypes, op, nonceBefore
        );

        console.log("tx =", txHash);
        console.log("OK: forwarded stakeWithPermit succeeded");
        return;
    }

    if(action === "unstake") {
        console.log("forwarder  :", forwarderAddr);
        console.log("staking    :", stakingAddr);

        const staked: bigint = await staking.balances(userAddr);
        if(staked === 0n) throw new Error("user has 0 staked tokens.");

        const amount = staked;

        const stakingIface = new ethers.Interface(stakingAbi);
        const callData = stakingIface.encodeFunctionData("unstake", [amount]);

        const op = buildUserOp({
            sender: userAddr,
            to: stakingAddr,
            gasLimit: opGasLimit,
            nonce: nonceBefore,
            deadline: opDeadline,
            data: callData
        });

        const txHash = await execForwarded(
            forwarder, relayer, user, userAddr, fwdDomain, userOpTypes, op, nonceBefore
        );

        console.log("tx =", txHash);
        console.log("OK: forwarded unstake succeeded");
        return;
    }

    if(action === "redeem") {
        console.log("forwarder  :", forwarderAddr);
        console.log("vault    :", vaultAddr);

        const shares: bigint = await vault.balanceOf(userAddr);
        if(shares === 0n) throw new Error("user has 0 vault shares.");

        const amount = shares;

        const stakingIface = new ethers.Interface(vaultAbi);
        const callData = stakingIface.encodeFunctionData("redeem", [userAddr, amount]);

        const op = buildUserOp({
            sender: userAddr,
            to: vaultAddr,
            gasLimit: opGasLimit,
            nonce: nonceBefore,
            deadline: opDeadline,
            data: callData
        });

        const txHash = await execForwarded(
            forwarder, relayer, user, userAddr, fwdDomain, userOpTypes, op, nonceBefore
        );

        console.log("tx =", txHash);
        console.log("OK: forwarded redeem succeeded");
        return;
    }

    if(action === "claim") {
        console.log("forwarder  :", forwarderAddr);
        console.log("staking    :", stakingAddr);

        const pending: bigint = await staking.rewards(userAddr);
        if(pending === 0n) throw new Error("user has no pending rewards");
        
        const stakingIface = new ethers.Interface(stakingAbi);
        const callData = stakingIface.encodeFunctionData("claimReward", []);

        const op = buildUserOp({
            sender: userAddr,
            to: stakingAddr,
            gasLimit: opGasLimit,
            nonce: nonceBefore,
            deadline: opDeadline,
            data: callData
        });

        const txHash = await execForwarded(
            forwarder, relayer, user, userAddr, fwdDomain, userOpTypes, op, nonceBefore
        );

        console.log("tx =", txHash);
        console.log("OK: forwarded claimReward succeeded");
        return;
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});