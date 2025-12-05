// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LibFee
 * @notice Diamond storage library for trading and graduation fee management
 * @dev Provides fee configuration, tracking, and pure calculation helpers
 */
library LibFee {
    bytes32 constant STORAGE_SLOT = keccak256("launchpad.fee.storage");

    /// @notice Basis points denominator (100% = 10000)
    uint256 public constant BASIS_POINTS = 10000;
    /// @notice Fixed platform fee (0.2% of trade amount)
    uint256 public constant PLATFORM_FEE = 20;
    /// @notice Total adjustable fee portion (1.0% of trade amount)
    uint256 public constant ADJUSTABLE_FEE = 100;
    /// @notice Total trading fee (platform + adjustable) in basis points (1.2%)
    uint256 public constant TOTAL_TRADING_FEE = 120;
    /// @notice Flat ETH fee required for graduation
    uint256 public constant GRADUATION_FEE_ETH = 0.1 ether;

    /// @notice Split of the adjustable trading fee portion
    struct FeeConfig {
        uint256 creatorFeePercentage;
        uint256 badBunnzFeePercentage;
        uint256 buybackFeePercentage;
    }

    /// @notice Split configuration for DEX fee distribution
    struct DEXFeeConfig {
        uint256 platformFeePercentage;
        uint256 creatorFeePercentage;
        uint256 badBunnzFeePercentage;
        uint256 buybackFeePercentage;
    }

    /// @notice Concrete fee amounts for a single distribution
    struct FeeBreakdown {
        uint256 platformFee;
        uint256 creatorFee;
        uint256 badBunnzFee;
        uint256 buybackFee;
        uint256 totalFee;
    }

    /// @notice Global fee storage layout for the diamond
    struct Layout {
        address platformWallet;
        address buybackWallet;
        uint256 defaultCreatorFee;
        uint256 defaultPlatformFee;
        uint256 defaultBuybackFee;
        uint256 totalPlatformFees;
        uint256 totalBadBunnzFees;
        uint256 totalBuybackFees;
        uint256 totalGraduationFees;
        uint256 totalCreatorFees;
        mapping(address creator => uint256) creatorRewards;
        mapping(address token => uint256) tokenBuybackFees;
        mapping(address token => FeeConfig) tokenFeeConfigs;
        mapping(address token => DEXFeeConfig) tokenDEXFeeConfigs;
        mapping(address token => bool) tokenHasCustomFees;
        mapping(address token => bool) tokenHasCustomDEXFees;
        DEXFeeConfig globalDEXFeeConfig;
    }

    /// @notice Return a pointer to the global fee storage layout
    /// @return l Storage pointer to `Layout`
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Calculate trading fee breakdown for a given amount
    /// @param _amount Gross fee amount (typically the full trade fee)
    /// @param _creatorFeePercentage Creator share of the adjustable portion (0-100)
    /// @param _badBunnzFeePercentage Bad Bunnz share of the adjustable portion (0-100)
    /// @param _buybackFeePercentage Buyback share of the adjustable portion (0-100)
    /// @return breakdown Struct with platform, creator, Bad Bunnz, buyback, and total fee amounts
    function calculateTradingFees(
        uint256 _amount,
        uint256 _creatorFeePercentage,
        uint256 _badBunnzFeePercentage,
        uint256 _buybackFeePercentage
    ) internal pure returns (FeeBreakdown memory breakdown) {
        require(
            _creatorFeePercentage + _badBunnzFeePercentage + _buybackFeePercentage == 100,
            "Fee percentages must sum to 100"
        );
        
        breakdown.platformFee = (_amount * PLATFORM_FEE) / BASIS_POINTS;
        uint256 adjustableAmount = (_amount * ADJUSTABLE_FEE) / BASIS_POINTS;
        breakdown.creatorFee = (adjustableAmount * _creatorFeePercentage) / 100;
        breakdown.badBunnzFee = (adjustableAmount * _badBunnzFeePercentage) / 100;
        breakdown.buybackFee = (adjustableAmount * _buybackFeePercentage) / 100;
        
        breakdown.totalFee = breakdown.platformFee + breakdown.creatorFee + 
                            breakdown.badBunnzFee + breakdown.buybackFee;
    }

    /// @notice Calculate DEX fee breakdown for an LP fee amount
    /// @param _amount Total LP fees to distribute
    /// @param _platformFeePercentage Platform share (0-100)
    /// @param _creatorFeePercentage Creator share (0-100)
    /// @param _badBunnzFeePercentage Bad Bunnz share (0-100)
    /// @param _buybackFeePercentage Buyback share (0-100)
    /// @return breakdown Struct with platform, creator, Bad Bunnz, buyback and total fee amounts
    function calculateDEXFees(
        uint256 _amount,
        uint256 _platformFeePercentage,
        uint256 _creatorFeePercentage,
        uint256 _badBunnzFeePercentage,
        uint256 _buybackFeePercentage
    ) internal pure returns (FeeBreakdown memory breakdown) {
        require(
            _platformFeePercentage + _creatorFeePercentage + 
            _badBunnzFeePercentage + _buybackFeePercentage == 100,
            "DEX fee percentages must sum to 100"
        );
        
        breakdown.platformFee = (_amount * _platformFeePercentage) / 100;
        breakdown.creatorFee = (_amount * _creatorFeePercentage) / 100;
        breakdown.badBunnzFee = (_amount * _badBunnzFeePercentage) / 100;
        breakdown.buybackFee = (_amount * _buybackFeePercentage) / 100;
        breakdown.totalFee = _amount;
    }

    /// @notice Emitted when trading or DEX fees are distributed for a token
    event FeesDistributed(address indexed token, address indexed creator, uint256 platformFee, uint256 creatorFee, uint256 badBunnzFee, uint256 buybackFee);

    /// @notice Emitted when a graduation fee is paid
    event GraduationFeePaid(address indexed token, uint256 amount);

    /// @notice Emitted when a creator claims accumulated rewards
    event CreatorRewardsClaimed(address indexed creator, uint256 amount);

    /// @notice Emitted when platform fees are withdrawn
    event PlatformFeesWithdrawn(uint256 amount);

    /// @notice Emitted when Bad Bunnz fees are withdrawn
    event BadBunnzFeesWithdrawn(uint256 amount);

    /// @notice Emitted when buyback fees are withdrawn
    event BuybackFeesWithdrawn(uint256 amount);

    /// @notice Emitted when graduation fees are withdrawn
    event GraduationFeesWithdrawn(uint256 amount);

    /// @notice Emitted when per-token bonding curve fee configuration is set
    event FeeConfigSet(address indexed token, uint256 creatorFee, uint256 badBunnzFee, uint256 buybackFee);

    /// @notice Emitted when per-token DEX fee configuration is set
    event DEXFeeConfigSet(address indexed token, uint256 platformFee, uint256 creatorFee, uint256 badBunnzFee, uint256 buybackFee);

    /// @notice Emitted when the global DEX fee configuration is updated
    event GlobalDEXFeeConfigUpdated(uint256 platformFee, uint256 creatorFee, uint256 badBunnzFee, uint256 buybackFee);

    /// @notice Emitted when fee wallets are updated
    event FeeWalletsUpdated(address platformWallet, address buybackWallet);
}
