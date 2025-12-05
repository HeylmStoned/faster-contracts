// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LibTrading
 * @notice Diamond storage library for bonding curve trading
 * @dev Implements x^1.5 bonding curve pricing and aggregate stats per token
 */
library LibTrading {
    bytes32 constant STORAGE_SLOT = keccak256("launchpad.trading.storage");

    /// @notice Initial token price in ETH
    uint256 public constant INITIAL_PRICE = 0.00001 ether;
    /// @notice Bonding curve steepness constant (~6.42e23)
    uint256 public constant K = 642337649721702000000000;
    /// @notice Maximum token supply for bonding curve
    uint256 public constant MAX_SUPPLY = 800000 ether;
    /// @notice Token limit for bonding curve phase (400k tokens)
    uint256 public constant TOKEN_LIMIT = 400000 ether;
    /// @notice Maximum ETH per buy transaction
    uint256 public constant MAX_BUY_AMOUNT = 1 ether;
    /// @notice Default ETH target for graduation
    uint256 public constant DEFAULT_ETH_TARGET = 30 ether;

    /// @notice Aggregated trading state for a single token
    struct TokenTradingData {
        uint256 totalSold;
        uint256 totalRaised;
        bool isOpen;
        uint256 createdAt;
    }

    /// @notice Global trading storage layout for the diamond
    struct Layout {
        mapping(address token => TokenTradingData) tokenTradingData;
        mapping(address token => uint256) tokenTargets;
        mapping(address token => bool) sellsEnabled;
    }

    /// @notice Return a pointer to the trading storage layout
    /// @return l Storage pointer to `Layout`
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Calculate instantaneous buy price at a given sold amount
    /// @param _sold Current tokens sold (18 decimals)
    /// @return price Price in wei per token
    function getBuyPrice(uint256 _sold) internal pure returns (uint256 price) {
        if (_sold == 0) {
            return INITIAL_PRICE;
        }
        
        uint256 soldNormalized = _sold / 1e18;
        uint256 soldSquareRoot = sqrt(soldNormalized);
        uint256 soldPower15 = soldNormalized * soldSquareRoot;
        uint256 priceIncrease = (K * soldPower15) / 1e18;
        price = INITIAL_PRICE + priceIncrease;
    }

    /// @notice Approximate total ETH cost for buying `_amount` tokens
    /// @param _sold Current tokens sold (18 decimals)
    /// @param _amount Amount of tokens to buy (18 decimals)
    /// @return totalCost ETH cost in wei
    function getBuyCost(uint256 _sold, uint256 _amount) internal pure returns (uint256 totalCost) {
        if (_amount == 0) return 0;
        
        uint256[4] memory chunkSizes = [
            uint256(10000 ether),
            uint256(1000 ether),
            uint256(100 ether),
            uint256(10 ether)
        ];
        
        uint256 remaining = _amount;
        uint256 currentSold = _sold;
        
        for (uint256 i = 0; i < 4; i++) {
            uint256 chunkSize = chunkSizes[i];
            while (remaining >= chunkSize) {
                uint256 avgPrice = getBuyPrice(currentSold + (chunkSize / 2));
                uint256 chunkCost = (avgPrice * chunkSize) / 1e18;
                totalCost += chunkCost;
                currentSold += chunkSize;
                remaining -= chunkSize;
            }
        }
        
        if (remaining > 0) {
            uint256 price = getBuyPrice(currentSold);
            totalCost += (price * remaining) / 1e18;
        }
    }

    /// @notice Approximate number of tokens purchasable for a given ETH amount
    /// @param _sold Current tokens sold (18 decimals)
    /// @param _ethAmount ETH budget in wei
    /// @return tokenAmount Number of tokens purchasable (18 decimals)
    function getTokensForETH(uint256 _sold, uint256 _ethAmount) internal pure returns (uint256 tokenAmount) {
        if (_ethAmount == 0) return 0;
        
        uint256 ethRemaining = _ethAmount;
        uint256 currentSold = _sold;
        
        uint256[4] memory chunkSizes = [
            uint256(10000 ether),
            uint256(1000 ether),
            uint256(100 ether),
            uint256(10 ether)
        ];
        
        for (uint256 i = 0; i < 4; i++) {
            uint256 chunkSize = chunkSizes[i];
            while (ethRemaining > 0 && (currentSold + chunkSize) <= MAX_SUPPLY) {
                uint256 avgPrice = getBuyPrice(currentSold + (chunkSize / 2));
                uint256 chunkCost = (avgPrice * chunkSize) / 1e18;
                
                if (chunkCost <= ethRemaining && (tokenAmount + chunkSize) <= MAX_SUPPLY) {
                    tokenAmount += chunkSize;
                    ethRemaining -= chunkCost;
                    currentSold += chunkSize;
                } else {
                    break;
                }
            }
        }
    }

    /// @notice Derive sell price from buy price with a fixed spread
    /// @param _sold Current tokens sold (18 decimals)
    /// @return price Sell price in wei per token
    function getSellPrice(uint256 _sold) internal pure returns (uint256 price) {
        if (_sold == 0) return 0;
        uint256 buyPrice = getBuyPrice(_sold);
        price = (buyPrice * 95) / 100; // 5% spread
    }

    /// @notice Approximate ETH proceeds from selling `_amount` tokens
    /// @param _sold Current tokens sold (18 decimals)
    /// @param _amount Amount of tokens to sell (18 decimals)
    /// @return totalProceeds ETH proceeds in wei
    function getSellProceeds(uint256 _sold, uint256 _amount) internal pure returns (uint256 totalProceeds) {
        if (_amount == 0) return 0;
        
        uint256 endSold = _sold > _amount ? _sold - _amount : 0;
        uint256 startPrice = getSellPrice(_sold);
        uint256 endPrice = getSellPrice(endSold);
        uint256 avgPrice = (startPrice + endPrice) / 2;
        
        totalProceeds = (avgPrice * _amount) / 1e18;
    }

    /// @notice Get the current buy price at the given sold amount
    /// @param _sold Current tokens sold (18 decimals)
    /// @return Current buy price in wei per token
    function getCurrentPrice(uint256 _sold) internal pure returns (uint256) {
        return getBuyPrice(_sold);
    }

    /// @notice Integer square root using Babylonian method
    /// @param x Value to square root
    /// @return y Floor of the square root of `x`
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Emitted when tokens are bought on the bonding curve
    event TokenBought(address indexed token, address indexed buyer, uint256 tokensOut, uint256 ethSpent);

    /// @notice Emitted when tokens are sold back into the bonding curve
    event TokenSold(address indexed token, address indexed seller, uint256 amount, uint256 price);

    /// @notice Emitted whenever aggregated trading stats are updated
    event TokenTradingDataUpdated(address indexed token, uint256 totalSold, uint256 totalRaised, bool isOpen);

    /// @notice Emitted when sells are enabled or disabled for a token
    event SellsEnabledUpdated(address indexed token, bool enabled);
}
