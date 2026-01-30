# Peer Credit Circles (PCC) ⚡

Decentralized micro-lending/investment pools for friend groups on Base.

## What is PCC?

Friends pool funds together on-chain. External projects can request funding from the pool. Pool members vote on whether to approve. If approved, funds are released. Projects reward the pool, distributed proportionally to each member's contribution.

```
FRIENDS ──deposit──▶ POOL ◀──request── PROJECTS
   │                  │                    │
   │                  ▼                    │
   │        [VOTING + GUARDIANS]           │
   │                  │                    │
   └◀─── REWARDS ◀────┴────────────────────┘
         (proportional)
```

## Features

- **Invite-only pools** - Friends create private pools
- **Share-weighted voting** - Vote power = deposit amount
- **Guardian system** - Large requests (>20% of pool) need guardian approval
- **Collateral** - Required for loans/investments, optional for grants
- **Proportional rewards** - Members earn based on their share

## Contracts

| Contract | Description |
|----------|-------------|
| `Pool.sol` | Core logic: deposits, voting, requests, rewards |
| `ShareToken.sol` | Non-transferable ERC20 for pool shares |
| `PoolFactory.sol` | Factory to create and track pools |

## Request Types

| Type | Collateral | Use Case |
|------|------------|----------|
| `GRANT` | Optional | Community funding, no repayment expected |
| `LOAN` | Required | Working capital, repay with interest |
| `INVESTMENT` | Required | Equity/token return expected |

## Quick Start

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test -vv

# Deploy (Base Sepolia)
forge script script/Deploy.s.sol --rpc-url base-sepolia --broadcast
```

## Configuration

When creating a pool:

```solidity
PoolConfig({
    name: "Alpha Circle",
    depositToken: USDC_ADDRESS,     // or address(0) for ETH
    minDeposit: 100e18,             // 100 USDC minimum
    votingPeriod: 3 days,
    quorumBps: 5000,                // 50% must vote
    approvalThresholdBps: 6000,     // 60% YES to pass
    guardianThresholdBps: 2000      // 20% triggers guardian approval
})
```

## Security

- **ReentrancyGuard** on all fund movements
- **SafeERC20** for token transfers
- **Non-transferable shares** (soulbound)
- **Guardian multi-sig** for large withdrawals
- **CEI pattern** throughout

## Tests

```
✅ test_Deposit
✅ test_MultipleDeposits
✅ test_Withdraw
✅ test_CreateGrantRequest
✅ test_CreateLoanRequestWithCollateral
✅ test_VoteAndApprove
✅ test_VoteAndReject
✅ test_QuorumNotMet
✅ test_ExecuteSmallRequest
✅ test_ExecuteLargeRequestNeedsGuardians
✅ test_ShareTokenNonTransferable
✅ test_RevertWhen_DepositBelowMin
✅ test_RevertWhen_DepositNotWhitelisted
✅ test_RevertWhen_LoanWithoutCollateral
```

## Roadmap

- [x] Core contracts
- [x] Unit tests (14 passing)
- [ ] Fuzz tests
- [ ] Deploy to Base Sepolia
- [ ] Farcaster Mini App UI
- [ ] Deploy to Base Mainnet

## License

MIT

---

Built by Shawn ⚡ for Bhavya
