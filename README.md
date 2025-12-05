# Faster Launchpad

A gas-efficient memecoin launchpad built on the EIP-2535 Diamond Standard. Tokens are created as ERC-6909 multi-tokens within a single contract, sold via a bonding curve, and automatically graduate to Uniswap V3 when funding targets are met.

## Quick Stats

| Parameter | Value |
|-----------|-------|
| **Total Supply** | 1,000,000 tokens |
| **Bonding Curve Sale** | 684,000 tokens (68.4%) |
| **DEX Liquidity** | 316,000 tokens (31.6%) |
| **Initial Price** | 0.00001 ETH |
| **Final Price** | ~0.0000946 ETH (9.5x) |
| **Graduation Target** | 30 ETH raised |
| **Trading Fee** | 1.2% |
| **Graduation Fee** | 0.1 ETH |
| **Max Buy per TX** | 1 ETH |
| **Price Continuity** | ~0.03% (BC → DEX) |

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

1. Creator calls `createToken()` with metadata, fee config, and optional fair launch settings
2. Diamond mints **1 million ERC-6909 tokens** internally (just storage writes, very cheap)
3. ERC-20 wrapper is deployed instantly via minimal proxy (EIP-1167)
4. All 1M tokens deposited to wrapper, held by Diamond for bonding curve sale
5. Creator must call `initializeToken(wrapper)` to open trading
6. Token is now live and tradeable

### Phase 2: Bonding Curve Trading

1. Users call `buyWithETH()` to purchase tokens (max 1 ETH per tx)
2. Price follows x^1.5 curve: 0.00001 ETH → 0.0000946 ETH (9.5x increase)
3. 1.2% fee deducted: split between creator, Bad Bunnz, and buyback (configurable at creation)
4. **Sells are disabled by default** - admin must call `setSellsEnabled(token, true)` to allow
5. If sells enabled, users can call `sellToken()` to sell back to curve
6. **684,000 tokens** available for bonding curve sale
7. Trading continues until **30 ETH raised** OR all 684k tokens sold

### Phase 3: Graduation

When ETH target (30 ETH) or token limit (684k) is met, graduation triggers automatically:

1. Bonding curve trading closes (`isOpen = false`)
2. 0.1 ETH graduation fee deducted
3. Calculate tokens needed for DEX to match final BC price
4. Burn excess tokens to dead address (maintains price continuity)
5. Create Uniswap V3 pool with ~316k tokens + ~29.9 ETH
6. Full-range liquidity position minted at 0.3% fee tier
7. Position NFT held by Diamond contract (liquidity locked forever)
8. Token wrapper now tradeable on Uniswap at same price as final BC price

### Phase 4: DEX Trading

1. Token trades freely on Uniswap V3 - no restrictions
2. LP fees accumulate in the position (0.3% per swap)
3. Anyone can call `collectFees(token)` to harvest LP fees
4. Fees auto-distribute: 20% platform (fixed) + 80% per token's DEX fee config:
   - Default 80% split: 50% creator, 25% Bad Bunnz, 25% buyback
5. Creator calls `claimCreatorRewards()` anytime to withdraw their share

## Facets

### TokenFacet
Creates ERC-6909 multi-tokens with metadata and fee configuration. Each token gets a unique ID within the Diamond.

```solidity
function createToken(
    string name,
    string symbol,
    string description,
    string imageUrl,
    string website,
    string twitter,
    string telegram,
    uint256 creatorFeePercentage,    // BC fee: creator share (sum must = 100)
    uint256 badBunnzFeePercentage,   // BC fee: Bad Bunnz share
    uint256 buybackFeePercentage,    // BC fee: buyback share
    uint256 dexCreatorFeePercentage,   // DEX LP fee: creator (sum must = 100, platform is fixed 20%)
    uint256 dexBadBunnzFeePercentage,  // DEX LP fee: Bad Bunnz
    uint256 dexBuybackFeePercentage,   // DEX LP fee: buyback
    bool enableFairLaunch,           // Enable fair launch mode
    uint256 fairLaunchDuration,      // Duration in seconds
    uint256 maxPerWallet,            // Max tokens per wallet during fair launch
    uint256 fixedPrice               // Fixed price during fair launch (wei)
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
- `getGraduationStatus(token)` - Returns (graduated, poolAddress, positionId, liquidity)

**Graduation Process (Price Continuity):**

The bonding curve constant K is calibrated so that selling 684k tokens raises ~30 ETH:
- Final BC price ≈ 0.0000946 ETH
- DEX price = (30 ETH - 0.1 fee) / 316k tokens ≈ 0.0000946 ETH
- **Price difference: ~0.03%** (essentially zero)

For early graduation (custom targets < 30 ETH), excess tokens are burned:
```
tokens_for_DEX = ETH_for_DEX / final_BC_price
tokens_burned = remaining_tokens - tokens_for_DEX
```

**Steps:**
1. Trading closes when 30 ETH raised OR 684k tokens sold
2. Deduct 0.1 ETH graduation fee
3. Calculate tokens needed for DEX to match final BC price
4. Burn excess tokens to `0x...dEaD` (only if >1% of remaining)
5. Create Uniswap V3 pool (0.3% fee tier)
6. Mint full-range liquidity position (ticks: -887220 to 887220)
7. Position NFT owned by Diamond (liquidity locked forever)

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
      ├──► 20% Platform (fixed)
      │
      └──► 80% Adjustable (default split):
              ├──► 50% Creator rewards (claimable)
              ├──► 25% Bad Bunnz
              └──► 25% Buyback
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

**Deployed: December 5, 2025** | All contracts verified ✅ | Fixed 20% DEX platform fee

| Contract | Address |
|----------|---------|
| **Diamond** | [`0x8Ee43427E435253Bdc94d9Ab81daeC441C03EB2e`](https://megaeth-testnet-v2.blockscout.com/address/0x8Ee43427E435253Bdc94d9Ab81daeC441C03EB2e) |
| DiamondCut | [`0xD64C6adc320FF3D0B7d09F6770e3095Ed7bF1022`](https://megaeth-testnet-v2.blockscout.com/address/0xD64C6adc320FF3D0B7d09F6770e3095Ed7bF1022) |
| DiamondLoupe | [`0x0edE8cCe0F0065AB48a6c8aa1108e6763a6D6453`](https://megaeth-testnet-v2.blockscout.com/address/0x0edE8cCe0F0065AB48a6c8aa1108e6763a6D6453) |
| TokenFacet | [`0x6799c57642E9F5813dBE2B01c27ce024cb417f87`](https://megaeth-testnet-v2.blockscout.com/address/0x6799c57642E9F5813dBE2B01c27ce024cb417f87) |
| TradingFacet | [`0xA52978d657dE175fD4F537f5d3bfe166c40E47d8`](https://megaeth-testnet-v2.blockscout.com/address/0xA52978d657dE175fD4F537f5d3bfe166c40E47d8) |
| GraduationFacet | [`0xc4a4771d91f6ce5732b287c21F60b2B193fdF0CE`](https://megaeth-testnet-v2.blockscout.com/address/0xc4a4771d91f6ce5732b287c21F60b2B193fdF0CE) |
| FeeFacet | [`0xE75A6cdDc836f4dB8aA1794B05e6545b89c774Bb`](https://megaeth-testnet-v2.blockscout.com/address/0xE75A6cdDc836f4dB8aA1794B05e6545b89c774Bb) |
| SecurityFacet | [`0x73c1eCcc3eD0F14A720069e0B11fe9D6492e0A17`](https://megaeth-testnet-v2.blockscout.com/address/0x73c1eCcc3eD0F14A720069e0B11fe9D6492e0A17) |
| AdminFacet | [`0xC1Eedf19d43D9e2EB462d982475Ac765c072d855`](https://megaeth-testnet-v2.blockscout.com/address/0xC1Eedf19d43D9e2EB462d982475Ac765c072d855) |
| ERC6909Facet | [`0x2976fD1C498070b6f7024Dc7807Ea788b8c3F67D`](https://megaeth-testnet-v2.blockscout.com/address/0x2976fD1C498070b6f7024Dc7807Ea788b8c3F67D) |
| WrapperFacet | [`0x99Ac8ccD4ed5F665330E7d5B49DB83408E8ea0Db`](https://megaeth-testnet-v2.blockscout.com/address/0x99Ac8ccD4ed5F665330E7d5B49DB83408E8ea0Db) |
| DiamondInit | [`0x90dbE1608DcDdbD7407ccaC1005121b63201F7D0`](https://megaeth-testnet-v2.blockscout.com/address/0x90dbE1608DcDdbD7407ccaC1005121b63201F7D0) |
| WrapperImpl | [`0x06aA00B602E7679cD25782aCe884Fb92f8F48b36`](https://megaeth-testnet-v2.blockscout.com/address/0x06aA00B602E7679cD25782aCe884Fb92f8F48b36) |

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
