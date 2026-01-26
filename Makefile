-include .env

RPC=$(SEPOLIA_RPC_URL)

ASSET=0x6CCf1d69fEba6443fe08c8743bA9F4975270941E
REWARD=0x7126766f64EdEc247Bf7431792b284dBe4818843
VAULT=0x513896313649854066ffFF133c4d0C6e3183b0b9
STAKING=0x96aE8362aa05bF592c51E8b04e5DfE45f40bF74C

OWNER1_ADDR=$(shell cast wallet address --private-key $(OWNER1_PRIVATE_KEY))

AMOUNT=100000000000000000000

.PHONY: deploy-sepolia deposit stake unstake redeem claim status \
		relay-deposit relay-stake relay-unstake relay-redeem relay-claim \
		demo-direct demo-relay demo-all

deploy-sepolia:
	forge script script/DeploySepolia.s.sol:DeploySepolia \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--etherscan-api-key $(ETHERSCAN_API_KEY) \
		-vvv

demo-direct:
	$(MAKE) deposit
	$(MAKE) stake
	$(MAKE) claim
	$(MAKE) unstake
	$(MAKE) redeem

demo-relay:
	$(MAKE) relay-deposit
	$(MAKE) relay-stake
	$(MAKE) relay-claim
	$(MAKE) relay-unstake
	$(MAKE) relay-redeem

demo-all:
	$(MAKE) demo-direct
	$(MAKE) demo-relay

deposit:
	cast send $(ASSET) "approve(address,uint256)" $(VAULT) $(AMOUNT) --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY)
	cast send $(VAULT) "deposit(address,uint256)" $(OWNER1_ADDR) $(AMOUNT) --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY)
	cast call $(VAULT) "totalUnderlying()(uint256)" --rpc-url $(RPC)
	cast call $(VAULT) "balanceOf(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC)

stake:
	SHARES=$$(cast call $(VAULT) "balanceOf(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC) | awk '{print $$1}'); \
	cast send $(VAULT) "approve(address,uint256)" $(STAKING) $$SHARES --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY); \
	cast send $(STAKING) "stake(uint256)" $$SHARES --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY); \
	cast call $(STAKING) "totalStaked()(uint256)" --rpc-url $(RPC)

unstake:
	STAKED=$$(cast call $(STAKING) "balances(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC) | awk '{print $$1}'); \
	cast send $(STAKING) "unstake(uint256)" $$STAKED --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY); \
	cast call $(STAKING) "totalStaked()(uint256)" --rpc-url $(RPC)
	cast call $(VAULT) "balanceOf(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC)

redeem:
	SHARES=$$(cast call $(VAULT) "balanceOf(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC) | awk '{print $$1}'); \
	test "$$SHARES" -gt 0; \
	cast send $(VAULT) "redeem(address,uint256)" $(OWNER1_ADDR) $$SHARES --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY)
	cast call $(ASSET) "balanceOf(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC)

claim:
	cast send $(STAKING) "claimReward()" --rpc-url $(RPC) --private-key $(OWNER1_PRIVATE_KEY)
	cast call $(REWARD) "balanceOf(address)(uint256)" $(OWNER1_ADDR) --rpc-url $(RPC)

status:
	pnpm status:latest

relay-deposit:
	pnpm relay:deposit

relay-stake:
	pnpm relay:stake

relay-unstake:
	pnpm relay:unstake

relay-redeem:
	pnpm relay:redeem

relay-claim:
	pnpm relay:claim