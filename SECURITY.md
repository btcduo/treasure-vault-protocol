# Security Policy
> [!WARNING]
> This repository is a **portfolio / educational** project. It has **NOT** been formally audited.
> **Do NOT use in production.**

## Scope
This repo focuses on demonstrating:
- A multisig governor (ERC-1271) controlling privileged parameters.
- A meta-tx forwarder (EIP-712) executing calls with replay protection.
- An EIP-1167 clone factory deploying per-asset vault instances.
- A vault + linear staking workflow with tests / scripts for demonstration.

Non-goals:
- Production hardening (pause, emergency procedures, monitoring, audits).
- Full ERC20 behavioral compatibility (rebasing / fee-on-transfer end-to-end).
- Full wallet compatibility (permit paths are EOA-only).
- Upgradability / migration framework for live deployments.

## Trust assumptions
- **Governor is trusted**: the multisig can change privileged parameters (e.g., staking reward rate; vault surplus skimming / ledger sync).
- **Trusted forwarder is critical**: targets must explicitly trust the forwarder; otherwise forwarded calls must revert.
- **Relayer is not trusted**: relayers can censor, reorder, or refuse to relay, but should not be able to forge a valid user operation.

---

## Multisig Government
**Description**
The Multisig contract ensures that specific function calls must be approved by multiple owners before execution.
It prevents a single owner from abusing their privileges, and reduces the risk that a lost private key permanently blocks owner-facing operations.
It assigns two different addresses as owners and sets the threshold to `2` during construction.
Additionally, it guarantees the invariant: `2 <= threshold <= ownerList.length`.

**Impact**
Privilege escalation can occur if `threshold` falls below `2`, or the system can enter a deadlock state if `threshold` exceeds the number of owners.

**Recommendation**
Keep the invariant: `threshold < ownerList.length && ownerList.length > 1` during execution of `_removeOwner()`.
Keep the invariant: `newThreshold <= ownerList.length && newThreshold > 1` during execution of `_modifyThreshold()`.
> [These requirements are defined in this protocol.]

---

## Meta-Transactions (Forwarder)
**Description**
The Forwarder verifies an EIP-712 signed `UserOp` and executes the target call with:
- nonce-based replay protection
- deadline-based expiration
- target-side trust gating (the target must explicitly trust this forwarder)
- sender recovery (EOA via ECDSA, smart wallets via ERC-1271)

**Security properties**
- **Replay protection**: `nonces[op.sender]` must match `op.nonce`, and is incremented before execution.
- **Expiry**: rejects expired operations (`deadline < block.timestamp`).
- **Target trust**: the forwarder reverts unless `op.to` trusts this forwarder.
- **Gas griefing check**: includes an EIP-150 style post-call gas check to avoid under-gassing tricks.

**Known limitations**
- Relayers can censor / reorder user operations (liveness is not guaranteed).
- This forwarder is a **demo format**, not a full ERC-4337 bundler pipeline.
- Targets must implement the expected “trusted forwarder + sender suffix” pattern correctly.

---

## EIP-1167 Clone Factory
**Description**
The factory deploys deterministic minimal proxies (CREATE2) and initializes clones via a low-level call.
It enforces:
- non-zero and contract addresses for critical dependencies
- one vault clone per asset (as defined by the factory mapping)

**Known limitations**
- No upgradability for already-deployed clones. New logic requires a new template + factory migration.
- Initialization correctness relies on the template's 'initialize()' being protected against re-initialization.

---

## Vault
**Description**
A per-asset vault that mints shares against deposited underlying, supports withdraw/redeem, and provides governor-only ledger maintenance hooks.

**Governor powers**
- `sync()`: reconcile internal accounting when actual token balance exceeds tracked `totalUnderlying`.
- `skimAssetSurplus(to)`: transfer surplus underlying (actual - managed) to `to`.

**Known limitations**
- fee-on-transfer / rebasing tokens are **NOT supported end-to-end**.
  - deposit credits `received`, but withdraw/redeem assume exact transfers.
- Permit deposit is **EOA-only** (smart wallets / ERC-1271 signers are rejected).
- No pause / emergency withdraw / rescue mechanisms (portfolio constraint).

---

## Linear Staking
**Description**
A linear reward staking contract using a global accumulator (`rewardPerTokenStored`) and per-user accounting.

**Governor powers**
- `setRewardRate(newRate)`: updates the emission rate (requires reward tokens to be pre-funded).

**Known limitations**
- staking must be **pre-funded** with reward tokens, otherwise `claimReward()` may revert due to insufficient balance.
- fee-on-transfer / rebasing tokens are **NOT supported end-to-end**.
  - stake credits `received`, but unstake assumes exact transfers.
- Permit staking is **EOA-only** (smart wallets / ERC-1271 signers are rejected).
- No reward “period finish / duration” framework (continuous emission model for demo).

---

## Operational notes
- Any deployment scripts, `.env`, and private keys are for **testing only** (e.g., Sepolia).
- Addresses in `deployments/*.json` are for reproducibility, not a production source of truth.
