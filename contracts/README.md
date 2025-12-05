# Faster Launchpad

A gas-efficient memecoin launchpad built on the EIP-2535 Diamond Standard. Tokens are created as ERC-6909 multi-tokens within a single contract, sold via a bonding curve, and automatically graduate to Uniswap V3 when funding targets are met.

## Why This Architecture?

### The Problem with Traditional Token Launches

Traditional launchpads deploy a new ERC-20 contract. This approach has significant drawbacks:

1. **Gas Waste**: Deploying a full ERC-20 contract costs ~1-2M gas per token
2. **Chain Bloat**: Thousands of abandoned tokens pollute the blockchain state forever
3. **Redundant Code**: Every token deploys identical bytecode
4. **Fragmented Liquidity**: Each token exists in isolation

### Our Solution: ERC-6909 Multi-Token Standard

Instead of deploying separate contracts, we use **ERC-6909** - a multi-token standard where all tokens exist within a single contract:

```
Traditional Approach:              Our Approach:
┌─────────────┐                   ┌─────────────────────────────┐
│ Token A     │ (separate)        │      Diamond Contract       │
│ ERC-20      │                   │  ┌─────┬─────┬─────┬─────┐  │
└─────────────┘                   │  │ ID:1│ ID:2│ ID:3│ ... │  │
┌─────────────┐                   │  │TokenA│TokenB│TokenC│    │  │
│ Token B     │ (separate)        │  └─────┴─────┴─────┴─────┘  │
│ ERC-20      │                   │      (single contract)      │
└─────────────┘                   └─────────────────────────────┘
┌─────────────┐
│ Token C     │ (separate)
│ ERC-20      │
└─────────────┘
```

**Benefits:**
- **90%+ Gas Savings**: Creating a new token is just a storage write (~50k gas vs 1-2M)
- **No Chain Bloat**: One contract holds unlimited tokens
- **Shared Infrastructure**: Trading, fees, graduation logic shared across all tokens
- **Upgradeable**: Diamond pattern allows adding features without migration

### ERC-20 Compatibility via Wrappers

ERC-6909 tokens aren't directly compatible with Uniswap and other DeFi protocols. We solve this with **minimal proxy wrappers** (EIP-1167):

```
User wants to trade on Uniswap
            │
            ▼
┌─────────────────────────┐
│   ERC-20 Wrapper        │  ◄── Thin proxy (~45 bytes)
│   (Minimal Proxy)       │
└───────────┬─────────────┘
            │ delegates to
            ▼
┌─────────────────────────┐
│   Diamond Contract      │  ◄── Actual token logic
│   (ERC-6909 storage)    │
└─────────────────────────┘
```

Each wrapper is only ~45 bytes of bytecode (vs ~5KB for a full ERC-20). Wrappers are deployed instantly at token creation, giving each token an ERC-20 compatible address from day one.

**For users and token holders, nothing changes.** Every token has a standard ERC-20 address that works everywhere - wallets, DEXs, block explorers, portfolio trackers. You can transfer, trade, and hold these tokens exactly like any other ERC-20. The ERC-6909 multi-token architecture is invisible to end users; it's just efficient infrastructure running in the background.

### The Diamond Standard (EIP-2535)

The Diamond pattern allows unlimited contract size by splitting logic into "facets":

| Facet | Purpose |
|-------|---------|
| **DiamondCutFacet** | Add, replace, or remove facets |
| **DiamondLoupeFacet** | Introspection (query facets, selectors) |
| **TokenFacet** | Token creation, ERC-6909 transfers, metadata |
| **TradingFacet** | Bonding curve buy/sell, price calculations |
| **GraduationFacet** | Uniswap V3 pool creation, LP fee collection |
| **FeeFacet** | Fee distribution, creator rewards, withdrawals |
| **SecurityFacet** | Anti-sniper protection, fair launch limits |
| **AdminFacet** | Owner controls, emergency functions |
| **ERC6909Facet** | Extended token metadata, graduation status |
| **WrapperFacet** | ERC-20 wrapper deployment and management |

All 10 facets share storage via libraries and can be upgraded independently without migrating tokens or liquidity.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Diamond Proxy                          │
│                 (Single Entry Point)                        │
├─────────────────────────────────────────────────────────────┤
│  TokenFacet    │  TradingFacet   │  GraduationFacet        │
│  FeeFacet      │  SecurityFacet  │  AdminFacet             │
│  ERC6909Facet  │  WrapperFacet   │  DiamondLoupe/Cut       │
├─────────────────────────────────────────────────────────────┤
│                   Shared Storage (Libraries)                │
│  LibToken │ LibTrading │ LibFee │ LibSecurity │ LibDEX     │
└─────────────────────────────────────────────────────────────┘
```

## Token Lifecycle

```
1. CREATE          2. BONDING CURVE       3. GRADUATION         4. DEX TRADING
   ┌─────┐            ┌─────────┐           ┌─────────┐          ┌─────────┐
   │Token│ ────────►  │  Buy    │ ───────►  │Graduate │ ───────► │Uniswap  │
   │Created│          │  Only   │           │to DEX   │          │V3 Pool  │
   └─────┘            └─────────┘           └─────────┘          └─────────┘
                      (Sells disabled       (Auto when           (Free market
                       by default)           target met)          trading)
```

### Phase 1: Token Creation

1. Creator calls `createToken()` with name, symbol, metadata, and total supply
2. Diamond mints ERC-6909 tokens internally (just storage writes, very cheap)
3. ERC-20 wrapper is deployed instantly via minimal proxy (EIP-1167)
4. All tokens sent to Diamond contract for bonding curve sale
5. Token is now live and tradeable

### Phase 2: Bonding Curve Trading

1. Users call `buyWithETH()` to purchase tokens
2. Price follows x^1.5 curve - starts low, increases with demand
3. 1.2% fee deducted: split between platform, creator, and buyback
4. **Sells are disabled by default** - admin must call `setSellsEnabled(token, true)` to allow
5. If sells enabled, users can call `sellToken()` to sell back to curve
6. Trading continues until graduation target reached (default: 30 ETH raised)

### Phase 3: Graduation

When ETH target is met, graduation triggers automatically:

1. Bonding curve trading closes (`isOpen = false`)
2. 0.1 ETH graduation fee deducted
3. Remaining tokens + raised ETH used to create Uniswap V3 pool
4. Full-range liquidity position minted at 0.3% fee tier
5. Position NFT held by Diamond contract (liquidity locked forever)
6. Any excess tokens burned to dead address
7. Token wrapper now tradeable on Uniswap

### Phase 4: DEX Trading

1. Token trades freely on Uniswap V3 - no restrictions
2. LP fees accumulate in the position
3. Anyone can call `collectFees(token)` to harvest LP fees
4. Fees auto-distribute: 50% creator, 30% platform, 10% Bad Bunnz, 10% buyback
5. Creator calls `claimCreatorRewards()` anytime to withdraw their share

## Facets

### TokenFacet
Creates ERC-6909 multi-tokens with metadata. Each token gets a unique ID within the Diamond.

```solidity
function createToken(
    string name,
    string symbol,
    string description,
    string imageUrl,
    string website,
    string twitter,
    string telegram
) returns (uint256 id, address wrapper)
```

All tokens are created with a fixed supply of **1 million tokens**:
- 684k sold via bonding curve (~30 ETH raised)
- 316k goes to DEX liquidity at graduation
- **~0 tokens burned** - DEX opens at same price as final BC price (0.026% difference)

### TradingFacet
Handles bonding curve trading with an x^1.5 price curve.

**Key Functions:**
- `buyWithETH(token, buyer, minTokensOut)` - Buy tokens with ETH
- `sellToken(token, amount, seller, minEthOut)` - Sell tokens back (requires admin approval)
- `setSellsEnabled(token, enabled)` - Admin: enable/disable sells per token
- `areSellsEnabled(token)` - Check if sells are enabled

**Bonding Curve Parameters:**
- Total Supply: 1 million tokens (fixed)
- Bonding Curve Allocation: 684k tokens (68.4%)
- DEX Liquidity: 316k tokens (31.6%)
- Initial Price: 0.00001 ETH
- Final Price: ~0.0000946 ETH (9.5x from start)
- Price Growth: x^1.5 curve (calibrated for price continuity)
- Max Single Buy: 1 ETH
- Graduation Target: ~30 ETH

### GraduationFacet
Graduates tokens from bonding curve to Uniswap V3.

**Key Functions:**
- `graduate(token)` - Graduate token to DEX (auto-called when target met)
- `collectFees(token)` - Collect LP fees and auto-distribute to creator
- `isTokenGraduated(token)` - Check graduation status

**Graduation Process (Price Continuity):**

The bonding curve is calibrated so that at the default 30 ETH target:
- Final BC price = Initial DEX price (no price gap)
- Zero tokens burned

For custom graduation targets, excess tokens are burned to maintain price continuity:
```
DEX_price = ETH_raised / tokens_for_DEX = final_BC_price
```

**Steps:**
1. Trading closes when ETH target or token limit reached
2. Calculate tokens needed for DEX to match final BC price
3. Burn any excess tokens (zero at default 30 ETH target)
4. Create Uniswap V3 pool with remaining tokens + raised ETH
5. Mint full-range liquidity position (owned by Diamond, locked forever)

### FeeFacet
Manages fee collection and distribution.

**Fee Structure:**
- Trading Fee: 1.2% (0.2% platform + 1.0% adjustable)
- Graduation Fee: 0.1 ETH flat
- DEX LP Fees: Split per config (default 50% creator, 30% platform, 10% Bad Bunnz, 10% buyback)

**Key Functions:**
- `claimCreatorRewards()` - Creators claim accumulated rewards
- `getCreatorRewards(creator)` - Check claimable balance
- `withdrawPlatformFees(amount)` - Admin: withdraw platform fees

### SecurityFacet
Launch protection mechanisms.

**Features:**
- Sniper Protection: Block buys during initial period
- Fair Launch: Max per-wallet limits during launch
- Token Pausing: Emergency pause trading

### AdminFacet
Owner administrative functions.

**Key Functions:**
- `owner()` / `transferOwnership(newOwner)`
- `setFeeWallets(platform, buyback)`
- `emergencyWithdraw(token, amount)`

### ERC6909Facet
Extended ERC-6909 functionality and metadata views.

### WrapperFacet
Creates ERC-20 wrapper tokens for ERC-6909 IDs using minimal proxies (EIP-1167).

## Fee Flow

### Bonding Curve Fees
```
User buys/sells
      │
      ▼
1.2% fee deducted
      │
      ├──► 0.2% Platform (fixed)
      │
      └──► 1.0% Adjustable:
              ├──► Creator rewards (claimable)
              ├──► Bad Bunnz
              └──► Buyback
```

### DEX LP Fees
```
Trades on Uniswap V3
      │
      ▼
Anyone calls collectFees(token)
      │
      ▼
Auto-distributed:
      ├──► 50% Creator rewards (claimable)
      ├──► 30% Platform
      ├──► 10% Bad Bunnz
      └──► 10% Buyback
```

### Creator Claiming
Creators can call `claimCreatorRewards()` at any time to withdraw their accumulated fees from both bonding curve trading and DEX LP fees.

## Sell Protection

**Sells are disabled by default** to prevent pump-and-dump schemes.

Admin must explicitly enable sells per token:
```solidity
diamond.setSellsEnabled(tokenAddress, true);
```

This does NOT affect DEX trading after graduation - only bonding curve sells.

## Deployment

### Prerequisites
- Node.js 18+
- Hardhat
- Private key with testnet ETH

### Deploy
```bash
npx hardhat run scripts/deploy-diamond-full.js --network megaethTestnet
```

### Verify
```bash
npx hardhat run scripts/verify-diamond.js --network megaethTestnet
```

## Contract Addresses (MegaETH Testnet)

| Contract | Address |
|----------|---------|
| Diamond | `0x2b0898215B8bD4C8B7509ffe73aD7b239a9A363F` |
| DiamondCut | `0x36d6993501c991b665a87b9F9E1582C9Eb2740D4` |
| DiamondLoupe | `0xb1ef51f44c2531D9abA76B123F149C7AE96bA9fE` |
| TokenFacet | `0x6Fcee80c9c9FC77C58B6D01C5fc2B470B85b2404` |
| TradingFacet | `0x9a7AE3E94A2BBdEE91a5e785a6fDF159B5595077` |
| GraduationFacet | `0xa893948756FE745aA13b09bad8E7968Af42b8031` |
| FeeFacet | `0x371ABc1d04e8429F3F8A9B4De0c3726791479025` |
| SecurityFacet | `0xCC455800cB72FaC63B2664F3b4541A0c8ED6aB5F` |
| AdminFacet | `0x79Fcb9C647c422d1AF71B73F9A09F3350167A4b4` |
| ERC6909Facet | `0xFD861B9Adf32cB2A3b3cFAEE678F70f7FF1495B5` |
| WrapperFacet | `0x8216a7e5BE75bA5FA5c28b9f3C53f2a6d6942278` |

## External Dependencies

- Uniswap V3 Factory: `0x94996d371622304f2eb85df1eb7f328f7b317c3e`
- Position Manager: `0x1279f3cbf01ad4f0cfa93f233464581f4051033a`
- WETH: `0x4200000000000000000000000000000000000006`

## Security Considerations

1. **Sells Disabled by Default**: Prevents early dumping
2. **Fair Launch Limits**: Optional per-wallet caps during launch
3. **Sniper Protection**: Optional delay before trading starts
4. **Owner Controls**: Admin can pause tokens, recover funds
5. **Non-Upgradeable LP**: Liquidity position owned by Diamond, not extractable

## License

MIT
