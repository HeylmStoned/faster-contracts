// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LibSecurity
 * @notice Diamond storage library for launch security features
 * @dev Provides configs and helpers for sniper protection and fair launch limits
 */
library LibSecurity {
    bytes32 constant STORAGE_SLOT = keccak256("launchpad.security.storage");

    /// @notice Minimum duration for sniper protection (10 minutes)
    uint256 public constant MIN_SNIPER_PROTECTION_DURATION = 600;
    /// @notice Maximum duration for sniper protection (1 hour)
    uint256 public constant MAX_SNIPER_PROTECTION_DURATION = 3600;
    /// @notice Minimum duration for fair launch (15 minutes)
    uint256 public constant MIN_FAIR_LAUNCH_DURATION = 900;
    /// @notice Maximum duration for fair launch (1 hour)
    uint256 public constant MAX_FAIR_LAUNCH_DURATION = 3600;
    /// @notice Minimum max-per-wallet limit for fair launch
    uint256 public constant MIN_FAIR_LAUNCH_MAX_PER_WALLET = 1000 ether;
    /// @notice Maximum max-per-wallet limit for fair launch
    uint256 public constant MAX_FAIR_LAUNCH_MAX_PER_WALLET = 10000 ether;

    /// @notice Configuration for per-token sniper protection
    struct SniperProtectionConfig {
        bool enabled;
        uint256 duration;
        uint256 startTime;
    }

    /// @notice Configuration for per-token fair launch phase
    struct FairLaunchConfig {
        bool enabled;
        uint256 duration;
        uint256 maxPerWallet;
        uint256 fixedPrice;
        uint256 startTime;
    }

    /// @notice Global security storage layout for the diamond
    struct Layout {
        mapping(address token => SniperProtectionConfig) sniperProtectionConfigs;
        mapping(address token => FairLaunchConfig) fairLaunchConfigs;
        mapping(address token => bool) tokenPaused;
        mapping(address token => mapping(address wallet => uint256)) walletPurchases;
    }

    /// @notice Return a pointer to the security storage layout
    /// @return l Storage pointer to `Layout`
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Validate that a sniper protection duration is within allowed bounds
    /// @param _duration Duration in seconds
    /// @return True if the duration is valid
    function validateSniperProtectionDuration(uint256 _duration) internal pure returns (bool) {
        return _duration >= MIN_SNIPER_PROTECTION_DURATION && 
               _duration <= MAX_SNIPER_PROTECTION_DURATION;
    }

    /// @notice Validate a fair launch configuration tuple
    /// @param _duration Duration in seconds
    /// @param _maxPerWallet Max tokens per wallet
    /// @return True if both duration and per-wallet cap are within bounds
    function validateFairLaunchConfig(uint256 _duration, uint256 _maxPerWallet) internal pure returns (bool) {
        return _duration >= MIN_FAIR_LAUNCH_DURATION && 
               _duration <= MAX_FAIR_LAUNCH_DURATION &&
               _maxPerWallet >= MIN_FAIR_LAUNCH_MAX_PER_WALLET &&
               _maxPerWallet <= MAX_FAIR_LAUNCH_MAX_PER_WALLET;
    }

    /// @notice Check whether sniper protection is currently active
    /// @param _config Sniper protection configuration
    /// @return True if enabled and the current time is before end time
    function isSniperProtectionActive(SniperProtectionConfig memory _config) internal view returns (bool) {
        if (!_config.enabled) return false;
        uint256 endTime = _config.startTime + _config.duration;
        return block.timestamp < endTime;
    }

    /// @notice Check whether fair launch is currently active
    /// @param _config Fair launch configuration
    /// @return True if enabled and the current time is before end time
    function isFairLaunchActive(FairLaunchConfig memory _config) internal view returns (bool) {
        if (!_config.enabled) return false;
        uint256 endTime = _config.startTime + _config.duration;
        return block.timestamp < endTime;
    }

    /// @notice Validate that a new buy amount fits within the fair launch cap
    /// @param _config Fair launch configuration
    /// @param _currentPurchased Amount already purchased by the wallet
    /// @param _buyAmount New amount the wallet intends to buy
    /// @return True if `_currentPurchased + _buyAmount` is within the cap
    function validateFairLaunchBuy(
        FairLaunchConfig memory _config,
        uint256 _currentPurchased,
        uint256 _buyAmount
    ) internal pure returns (bool) {
        if (!_config.enabled) return true;
        return _currentPurchased + _buyAmount <= _config.maxPerWallet;
    }

    /// @notice Get remaining time for sniper protection
    /// @param _config Sniper protection configuration
    /// @return Remaining seconds before protection ends (0 if inactive)
    function getSniperProtectionRemainingTime(SniperProtectionConfig memory _config) internal view returns (uint256) {
        if (!isSniperProtectionActive(_config)) return 0;
        uint256 endTime = _config.startTime + _config.duration;
        return endTime > block.timestamp ? endTime - block.timestamp : 0;
    }

    /// @notice Get remaining time for fair launch
    /// @param _config Fair launch configuration
    /// @return Remaining seconds before fair launch ends (0 if inactive)
    function getFairLaunchRemainingTime(FairLaunchConfig memory _config) internal view returns (uint256) {
        if (!isFairLaunchActive(_config)) return 0;
        uint256 endTime = _config.startTime + _config.duration;
        return endTime > block.timestamp ? endTime - block.timestamp : 0;
    }

    /// @notice Emitted when sniper protection is enabled for a token
    event SniperProtectionEnabled(address indexed token, uint256 duration);

    /// @notice Emitted when fair launch is enabled for a token
    event FairLaunchEnabled(address indexed token, uint256 duration, uint256 maxPerWallet);

    /// @notice Emitted when a token's paused status changes
    event TokenPaused(address indexed token, bool paused);

    /// @notice Emitted when security configuration is globally disabled for a token
    event SecurityConfigUpdated(address indexed token, bool sniperProtection, bool fairLaunch);
}
