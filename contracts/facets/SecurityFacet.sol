// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibSecurity} from "../libraries/LibSecurity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/**
 * @title SecurityFacet
 * @notice Manages security features for token launches
 * @dev Implements sniper protection, fair launch limits, and token pausing
 */
contract SecurityFacet {

    /// @notice Enable sniper protection for a token for a fixed duration
    /// @param _token Token address
    /// @param _duration Protection duration in seconds
    function enableSniperProtection(address _token, uint256 _duration) external {
        LibDiamond.enforceIsContractOwner();
        require(LibSecurity.validateSniperProtectionDuration(_duration), "Invalid sniper protection duration");
        
        LibSecurity.Layout storage ss = LibSecurity.layout();
        ss.sniperProtectionConfigs[_token] = LibSecurity.SniperProtectionConfig({
            enabled: true,
            duration: _duration,
            startTime: block.timestamp
        });
        
        emit LibSecurity.SniperProtectionEnabled(_token, _duration);
    }

    /// @notice Enable a fair launch phase with max-per-wallet and fixed price
    /// @param _token Token address
    /// @param _duration Duration of fair launch in seconds
    /// @param _maxPerWallet Maximum tokens per wallet
    /// @param _fixedPrice Fixed price per token in wei
    function enableFairLaunch(
        address _token,
        uint256 _duration,
        uint256 _maxPerWallet,
        uint256 _fixedPrice
    ) external {
        LibDiamond.enforceIsContractOwner();
        require(LibSecurity.validateFairLaunchConfig(_duration, _maxPerWallet), "Invalid fair launch configuration");
        require(_fixedPrice > 0, "Fixed price must be greater than 0");
        
        LibSecurity.Layout storage ss = LibSecurity.layout();
        ss.fairLaunchConfigs[_token] = LibSecurity.FairLaunchConfig({
            enabled: true,
            duration: _duration,
            maxPerWallet: _maxPerWallet,
            fixedPrice: _fixedPrice,
            startTime: block.timestamp
        });
        
        emit LibSecurity.FairLaunchEnabled(_token, _duration, _maxPerWallet);
    }

    /// @notice Pause or unpause a token for trading
    /// @param _token Token address
    /// @param _paused True to pause, false to unpause
    function pauseToken(address _token, bool _paused) external {
        LibDiamond.enforceIsContractOwner();
        LibSecurity.layout().tokenPaused[_token] = _paused;
        emit LibSecurity.TokenPaused(_token, _paused);
    }

    /// @notice Validate whether a buy is allowed under current security rules
    /// @param _token Token address
    /// @param _buyer Buyer address
    /// @param _amount Amount of tokens to buy
    /// @return True if the buy is allowed
    function validateBuy(
        address _token,
        address _buyer,
        uint256 _amount
    ) external view returns (bool) {
        LibSecurity.Layout storage ss = LibSecurity.layout();
        
        // Check if token is paused
        if (ss.tokenPaused[_token]) return false;
        
        // Check fair launch limits if active
        LibSecurity.FairLaunchConfig memory config = ss.fairLaunchConfigs[_token];
        if (LibSecurity.isFairLaunchActive(config)) {
            uint256 currentPurchased = ss.walletPurchases[_token][_buyer];
            if (!LibSecurity.validateFairLaunchBuy(config, currentPurchased, _amount)) {
                return false;
            }
        }
        
        return true;
    }

    /// @notice Validate whether a sell is allowed under current security rules
    /// @param _token Token address
    /// @return True if sells are allowed (token not paused)
    function validateSell(
        address _token,
        address /* _seller */,
        uint256 /* _amount */
    ) external view returns (bool) {
        return !LibSecurity.layout().tokenPaused[_token];
    }

    /// @notice Record a wallet purchase for fair launch accounting
    /// @param _token Token address
    /// @param _wallet Buyer wallet address
    /// @param _amount Amount of tokens purchased
    function recordWalletPurchase(address _token, address _wallet, uint256 _amount) external {
        LibDiamond.enforceIsContractOwner();
        LibSecurity.layout().walletPurchases[_token][_wallet] += _amount;
    }

    /// @notice Check if sniper protection is active for a token
    /// @param _token Token address
    /// @return True if protection is active
    function isSniperProtectionActive(address _token) external view returns (bool) {
        LibSecurity.Layout storage ss = LibSecurity.layout();
        return LibSecurity.isSniperProtectionActive(ss.sniperProtectionConfigs[_token]);
    }

    /// @notice Check if fair launch is active for a token
    /// @param _token Token address
    /// @return True if fair launch is active
    function isFairLaunchActive(address _token) external view returns (bool) {
        LibSecurity.Layout storage ss = LibSecurity.layout();
        return LibSecurity.isFairLaunchActive(ss.fairLaunchConfigs[_token]);
    }

    /// @notice Get fair launch configuration for a token
    /// @param _token Token address
    /// @return enabled True if enabled
    /// @return duration Duration in seconds
    /// @return maxPerWallet Maximum tokens per wallet
    /// @return fixedPrice Fixed token price in wei
    /// @return startTime Start timestamp
    function getFairLaunchConfig(address _token) external view returns (
        bool enabled,
        uint256 duration,
        uint256 maxPerWallet,
        uint256 fixedPrice,
        uint256 startTime
    ) {
        LibSecurity.FairLaunchConfig memory config = LibSecurity.layout().fairLaunchConfigs[_token];
        return (
            config.enabled,
            config.duration,
            config.maxPerWallet,
            config.fixedPrice,
            config.startTime
        );
    }

    /// @notice Get sniper protection configuration for a token
    /// @param _token Token address
    /// @return enabled True if enabled
    /// @return duration Duration in seconds
    /// @return startTime Start timestamp
    function getSniperProtectionConfig(address _token) external view returns (
        bool enabled,
        uint256 duration,
        uint256 startTime
    ) {
        LibSecurity.SniperProtectionConfig memory config = LibSecurity.layout().sniperProtectionConfigs[_token];
        return (
            config.enabled,
            config.duration,
            config.startTime
        );
    }

    /// @notice Get remaining sniper protection time for a token
    /// @param _token Token address
    /// @return Remaining seconds
    function getSniperProtectionRemainingTime(address _token) external view returns (uint256) {
        LibSecurity.Layout storage ss = LibSecurity.layout();
        return LibSecurity.getSniperProtectionRemainingTime(ss.sniperProtectionConfigs[_token]);
    }

    /// @notice Get remaining fair launch time for a token
    /// @param _token Token address
    /// @return Remaining seconds
    function getFairLaunchRemainingTime(address _token) external view returns (uint256) {
        LibSecurity.Layout storage ss = LibSecurity.layout();
        return LibSecurity.getFairLaunchRemainingTime(ss.fairLaunchConfigs[_token]);
    }

    /// @notice Get total amount purchased by a wallet during fair launch
    /// @param _token Token address
    /// @param _wallet Wallet address
    /// @return Total amount purchased
    function getWalletPurchaseAmount(address _token, address _wallet) external view returns (uint256) {
        return LibSecurity.layout().walletPurchases[_token][_wallet];
    }

    /// @notice Get consolidated security status for a token
    /// @param _token Token address
    /// @return isPaused Whether token is paused
    /// @return sniperProtectionActive Whether sniper protection is active
    /// @return fairLaunchActive Whether fair launch is active
    /// @return sniperProtectionRemaining Remaining sniper protection seconds
    /// @return fairLaunchRemaining Remaining fair launch seconds
    function getSecurityStatus(address _token) external view returns (
        bool isPaused,
        bool sniperProtectionActive,
        bool fairLaunchActive,
        uint256 sniperProtectionRemaining,
        uint256 fairLaunchRemaining
    ) {
        LibSecurity.Layout storage ss = LibSecurity.layout();
        isPaused = ss.tokenPaused[_token];
        sniperProtectionActive = LibSecurity.isSniperProtectionActive(ss.sniperProtectionConfigs[_token]);
        fairLaunchActive = LibSecurity.isFairLaunchActive(ss.fairLaunchConfigs[_token]);
        sniperProtectionRemaining = LibSecurity.getSniperProtectionRemainingTime(ss.sniperProtectionConfigs[_token]);
        fairLaunchRemaining = LibSecurity.getFairLaunchRemainingTime(ss.fairLaunchConfigs[_token]);
    }

    /// @notice Emergency disable all security mechanisms for a token
    /// @param _token Token address
    function emergencyDisableSecurity(address _token) external {
        LibDiamond.enforceIsContractOwner();
        LibSecurity.Layout storage ss = LibSecurity.layout();
        ss.sniperProtectionConfigs[_token].enabled = false;
        ss.fairLaunchConfigs[_token].enabled = false;
        ss.tokenPaused[_token] = false;
        
        emit LibSecurity.SecurityConfigUpdated(_token, false, false);
    }
}
