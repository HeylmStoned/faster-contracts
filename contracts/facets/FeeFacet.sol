// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibFee} from "../libraries/LibFee.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FeeFacet
 * @notice Manages trading fees, graduation fees, and fee distribution
 * @dev Supports configurable fee splits between creator, platform, and buyback
 */
contract FeeFacet is ReentrancyGuard {

    /// @notice Set per-token bonding curve trading fee percentages
    /// @dev Creator or diamond owner may call; percentages must sum to 100
    /// @param _token Token address
    /// @param _creatorFeePercentage Creator share of adjustable portion
    /// @param _badBunnzFeePercentage Bad Bunnz share of adjustable portion
    /// @param _buybackFeePercentage Buyback share of adjustable portion
    function setBondingCurveFeePercentages(
        address _token,
        uint256 _creatorFeePercentage,
        uint256 _badBunnzFeePercentage,
        uint256 _buybackFeePercentage
    ) external {
        require(
            _creatorFeePercentage + _badBunnzFeePercentage + _buybackFeePercentage == 100,
            "Fee percentages must sum to 100"
        );
        
        address creator = _getTokenCreator(_token);
        require(
            msg.sender == LibDiamond.contractOwner() || msg.sender == creator,
            "Only owner or token creator can set fees"
        );
        
        LibFee.Layout storage fs = LibFee.layout();
        fs.tokenFeeConfigs[_token] = LibFee.FeeConfig({
            creatorFeePercentage: _creatorFeePercentage,
            badBunnzFeePercentage: _badBunnzFeePercentage,
            buybackFeePercentage: _buybackFeePercentage
        });
        fs.tokenHasCustomFees[_token] = true;
        
        emit LibFee.FeeConfigSet(_token, _creatorFeePercentage, _badBunnzFeePercentage, _buybackFeePercentage);
    }

    /// @notice Set per-token DEX LP fee percentages
    /// @dev Creator or diamond owner may call; percentages must sum to 100
    /// @dev Platform gets fixed 20%, these percentages split the remaining 80%
    /// @param _token Token address
    /// @param _creatorFeePercentage Creator share of adjustable 80% portion
    /// @param _badBunnzFeePercentage Bad Bunnz share of adjustable 80% portion
    /// @param _buybackFeePercentage Buyback share of adjustable 80% portion
    function setDEXFeePercentages(
        address _token,
        uint256 _creatorFeePercentage,
        uint256 _badBunnzFeePercentage,
        uint256 _buybackFeePercentage
    ) external {
        require(
            _creatorFeePercentage + _badBunnzFeePercentage + _buybackFeePercentage == 100,
            "DEX fee percentages must sum to 100"
        );
        
        address creator = _getTokenCreator(_token);
        require(
            msg.sender == LibDiamond.contractOwner() || msg.sender == creator,
            "Only owner or token creator can set DEX fees"
        );
        
        LibFee.Layout storage fs = LibFee.layout();
        fs.tokenDEXFeeConfigs[_token] = LibFee.DEXFeeConfig({
            creatorFeePercentage: _creatorFeePercentage,
            badBunnzFeePercentage: _badBunnzFeePercentage,
            buybackFeePercentage: _buybackFeePercentage
        });
        fs.tokenHasCustomDEXFees[_token] = true;
        
        emit LibFee.DEXFeeConfigSet(_token, _creatorFeePercentage, _badBunnzFeePercentage, _buybackFeePercentage);
    }

    /// @notice Update the global DEX fee configuration used as default
    /// @dev Only owner; percentages must sum to 100. Platform gets fixed 20%.
    /// @param _creatorFeePercentage Creator share of adjustable 80% portion
    /// @param _badBunnzFeePercentage Bad Bunnz share of adjustable 80% portion
    /// @param _buybackFeePercentage Buyback share of adjustable 80% portion
    function updateGlobalDEXFeeConfig(
        uint256 _creatorFeePercentage,
        uint256 _badBunnzFeePercentage,
        uint256 _buybackFeePercentage
    ) external {
        LibDiamond.enforceIsContractOwner();
        require(
            _creatorFeePercentage + _badBunnzFeePercentage + _buybackFeePercentage == 100,
            "DEX fee percentages must sum to 100"
        );
        
        LibFee.Layout storage fs = LibFee.layout();
        fs.globalDEXFeeConfig = LibFee.DEXFeeConfig({
            creatorFeePercentage: _creatorFeePercentage,
            badBunnzFeePercentage: _badBunnzFeePercentage,
            buybackFeePercentage: _buybackFeePercentage
        });
        
        emit LibFee.GlobalDEXFeeConfigUpdated(_creatorFeePercentage, _badBunnzFeePercentage, _buybackFeePercentage);
    }

    /// @notice Distribute bonding-curve trading fees held by the diamond
    /// @dev Callable by the diamond owner; msg.value must equal `_tradingFee`
    /// @param _token Token address
    /// @param _creator Creator address
    /// @param _tradingFee Total fee in wei to distribute
    function distributeTradingFees(
        address _token,
        address _creator,
        uint256 _tradingFee
    ) external payable {
        LibDiamond.enforceIsContractOwner();
        require(msg.value == _tradingFee, "Incorrect fee amount sent");
        
        LibFee.Layout storage fs = LibFee.layout();
        
        LibFee.FeeConfig memory config = fs.tokenHasCustomFees[_token] ? 
            fs.tokenFeeConfigs[_token] : 
            LibFee.FeeConfig({
                creatorFeePercentage: 50,
                badBunnzFeePercentage: 25,
                buybackFeePercentage: 25
            });
        
        LibFee.FeeBreakdown memory breakdown = LibFee.calculateTradingFees(
            _tradingFee,
            config.creatorFeePercentage,
            config.badBunnzFeePercentage,
            config.buybackFeePercentage
        );
        
        fs.creatorRewards[_creator] += breakdown.creatorFee;
        fs.totalPlatformFees += breakdown.platformFee;
        fs.totalBadBunnzFees += breakdown.badBunnzFee;
        fs.totalBuybackFees += breakdown.buybackFee;
        fs.totalCreatorFees += breakdown.creatorFee;
        fs.tokenBuybackFees[_token] += breakdown.buybackFee;
        
        emit LibFee.FeesDistributed(_token, _creator, breakdown.platformFee, breakdown.creatorFee, breakdown.badBunnzFee, breakdown.buybackFee);
    }

    /// @notice Distribute DEX LP fees held by the diamond according to DEX config
    /// @dev Callable by the diamond owner; msg.value must equal `_totalLPFees`
    /// @param _token Token address
    /// @param _creator Creator address
    /// @param _totalLPFees Total LP fees received in wei
    function distributeDEXFees(
        address _token,
        address _creator,
        uint256 _totalLPFees
    ) external payable {
        LibDiamond.enforceIsContractOwner();
        require(msg.value == _totalLPFees, "Incorrect fee amount sent");
        
        LibFee.Layout storage fs = LibFee.layout();
        
        LibFee.DEXFeeConfig memory config = fs.tokenHasCustomDEXFees[_token] ? 
            fs.tokenDEXFeeConfigs[_token] : 
            fs.globalDEXFeeConfig;
        
        LibFee.FeeBreakdown memory breakdown = LibFee.calculateDEXFees(
            _totalLPFees,
            config.creatorFeePercentage,
            config.badBunnzFeePercentage,
            config.buybackFeePercentage
        );
        
        fs.totalPlatformFees += breakdown.platformFee;
        fs.creatorRewards[_creator] += breakdown.creatorFee;
        fs.totalCreatorFees += breakdown.creatorFee;
        fs.totalBadBunnzFees += breakdown.badBunnzFee;
        fs.totalBuybackFees += breakdown.buybackFee;
        
        emit LibFee.FeesDistributed(_token, _creator, breakdown.platformFee, breakdown.creatorFee, breakdown.badBunnzFee, breakdown.buybackFee);
    }

    /// @notice Pay and account for a graduation fee
    /// @dev Only owner; msg.value must be at least `GRADUATION_FEE_ETH`
    /// @param _token Token address graduating
    function payGraduationFee(address _token) external payable {
        LibDiamond.enforceIsContractOwner();
        require(msg.value >= LibFee.GRADUATION_FEE_ETH, "Insufficient graduation fee");
        LibFee.layout().totalGraduationFees += msg.value;
        emit LibFee.GraduationFeePaid(_token, msg.value);
    }

    /// @notice Claim accumulated creator rewards
    function claimCreatorRewards() external nonReentrant {
        LibFee.Layout storage fs = LibFee.layout();
        uint256 amount = fs.creatorRewards[msg.sender];
        require(amount > 0, "No rewards to claim");
        
        fs.creatorRewards[msg.sender] = 0;
        
        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit LibFee.CreatorRewardsClaimed(msg.sender, amount);
    }

    /// @notice Withdraw platform fee balance to the owner
    /// @param _amount Amount to withdraw
    function withdrawPlatformFees(uint256 _amount) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibFee.Layout storage fs = LibFee.layout();
        require(_amount <= fs.totalPlatformFees, "Insufficient platform fees");
        
        fs.totalPlatformFees -= _amount;
        
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        require(success, "ETH transfer failed");
        
        emit LibFee.PlatformFeesWithdrawn(_amount);
    }

    /// @notice Withdraw Bad Bunnz fee balance to the owner
    /// @param _amount Amount to withdraw
    function withdrawBadBunnzFees(uint256 _amount) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibFee.Layout storage fs = LibFee.layout();
        require(_amount <= fs.totalBadBunnzFees, "Insufficient Bad Bunnz fees");
        
        fs.totalBadBunnzFees -= _amount;
        
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        require(success, "ETH transfer failed");
        
        emit LibFee.BadBunnzFeesWithdrawn(_amount);
    }

    /// @notice Withdraw global buyback fee balance to the owner
    /// @param _amount Amount to withdraw
    function withdrawBuybackFees(uint256 _amount) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibFee.Layout storage fs = LibFee.layout();
        require(_amount <= fs.totalBuybackFees, "Insufficient buyback fees");
        
        fs.totalBuybackFees -= _amount;
        
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        require(success, "ETH transfer failed");
        
        emit LibFee.BuybackFeesWithdrawn(_amount);
    }

    /// @notice Withdraw per-token buyback fee balance to the owner
    /// @param _token Token address
    /// @param _amount Amount to withdraw
    function withdrawTokenBuybackFees(address _token, uint256 _amount) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibFee.Layout storage fs = LibFee.layout();
        require(_amount <= fs.tokenBuybackFees[_token], "Insufficient token buyback fees");
        require(_amount <= fs.totalBuybackFees, "Insufficient total buyback fees");
        
        fs.tokenBuybackFees[_token] -= _amount;
        fs.totalBuybackFees -= _amount;
        
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        require(success, "ETH transfer failed");
        
        emit LibFee.BuybackFeesWithdrawn(_amount);
    }

    /// @notice Withdraw accumulated graduation fees to the owner
    /// @param _amount Amount to withdraw
    function withdrawGraduationFees(uint256 _amount) external nonReentrant {
        LibDiamond.enforceIsContractOwner();
        LibFee.Layout storage fs = LibFee.layout();
        require(_amount <= fs.totalGraduationFees, "Insufficient graduation fees");
        
        fs.totalGraduationFees -= _amount;
        
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        require(success, "ETH transfer failed");
        
        emit LibFee.GraduationFeesWithdrawn(_amount);
    }

    /// @notice Convenience helper for creators to set their bonding-curve fee share
    /// @param _token Token address
    /// @param _creatorFeePercentage Creator share (capped at 70%)
    function setCreatorBondingCurveFees(address _token, uint256 _creatorFeePercentage) external {
        require(_creatorFeePercentage <= 70, "Creator fee cannot exceed 70%");
        require(msg.sender == _getTokenCreator(_token), "Only token creator can set their fees");
        
        uint256 remainingPercentage = 100 - _creatorFeePercentage;
        uint256 badBunnzFeePercentage = remainingPercentage / 2;
        uint256 buybackFeePercentage = remainingPercentage - badBunnzFeePercentage;
        
        LibFee.Layout storage fs = LibFee.layout();
        fs.tokenFeeConfigs[_token] = LibFee.FeeConfig({
            creatorFeePercentage: _creatorFeePercentage,
            badBunnzFeePercentage: badBunnzFeePercentage,
            buybackFeePercentage: buybackFeePercentage
        });
        fs.tokenHasCustomFees[_token] = true;
        
        emit LibFee.FeeConfigSet(_token, _creatorFeePercentage, badBunnzFeePercentage, buybackFeePercentage);
    }

    /// @notice Convenience helper for creators to set their DEX fee share
    /// @param _token Token address
    /// @param _creatorFeePercentage Creator share (capped at 60%)
    /// @dev Platform gets fixed 0.2%, remaining split: creator + proportional bad bunnz/buyback
    function setCreatorDEXFees(address _token, uint256 _creatorFeePercentage) external {
        require(_creatorFeePercentage <= 60, "Creator fee cannot exceed 60%");
        require(msg.sender == _getTokenCreator(_token), "Only token creator can set their fees");
        
        // Remaining percentage split proportionally between bad bunnz and buyback (1:1 ratio)
        uint256 remainingPercentage = 100 - _creatorFeePercentage;
        uint256 badBunnzFeePercentage = remainingPercentage / 2;
        uint256 buybackFeePercentage = remainingPercentage - badBunnzFeePercentage;
        
        LibFee.Layout storage fs = LibFee.layout();
        fs.tokenDEXFeeConfigs[_token] = LibFee.DEXFeeConfig({
            creatorFeePercentage: _creatorFeePercentage,
            badBunnzFeePercentage: badBunnzFeePercentage,
            buybackFeePercentage: buybackFeePercentage
        });
        fs.tokenHasCustomDEXFees[_token] = true;
        
        emit LibFee.DEXFeeConfigSet(_token, _creatorFeePercentage, badBunnzFeePercentage, buybackFeePercentage);
    }

    /// @notice Get unclaimed creator rewards
    /// @param _creator Creator address
    /// @return Amount of rewards in wei
    function getCreatorRewards(address _creator) external view returns (uint256) {
        return LibFee.layout().creatorRewards[_creator];
    }

    /// @notice Get per-token buyback fee balance
    /// @param _token Token address
    /// @return Amount of buyback fees in wei
    function getTokenBuybackFees(address _token) external view returns (uint256) {
        return LibFee.layout().tokenBuybackFees[_token];
    }

    /// @notice Get platform-wide fee statistics
    /// @return platformFees Total platform fees
    /// @return badBunnzFees Total Bad Bunnz fees
    /// @return buybackFees Total buyback fees
    /// @return graduationFees Total graduation fees
    /// @return creatorFees Total creator fees
    function getPlatformStats() external view returns (
        uint256 platformFees,
        uint256 badBunnzFees,
        uint256 buybackFees,
        uint256 graduationFees,
        uint256 creatorFees
    ) {
        LibFee.Layout storage fs = LibFee.layout();
        return (
            fs.totalPlatformFees,
            fs.totalBadBunnzFees,
            fs.totalBuybackFees,
            fs.totalGraduationFees,
            fs.totalCreatorFees
        );
    }

    /// @notice Get the flat ETH graduation fee
    /// @return Fee amount in wei
    function getGraduationFee() external pure returns (uint256) {
        return LibFee.GRADUATION_FEE_ETH;
    }

    /// @notice Get the total trading fee in basis points
    /// @return Total fee (platform + adjustable) in basis points
    function getTradingFeePercentage() external pure returns (uint256) {
        return LibFee.TOTAL_TRADING_FEE;
    }

    /// @notice Get a normalized trading fee breakdown for a token using 10000 units
    /// @param _token Token address
    /// @return platformFee Platform fee share
    /// @return creatorFee Creator fee share
    /// @return badBunnzFee Bad Bunnz fee share
    /// @return buybackFee Buyback fee share
    /// @return totalFee Total fee (should equal 10000 units)
    function getFeeBreakdown(address _token) external view returns (
        uint256 platformFee,
        uint256 creatorFee,
        uint256 badBunnzFee,
        uint256 buybackFee,
        uint256 totalFee
    ) {
        LibFee.Layout storage fs = LibFee.layout();
        
        LibFee.FeeConfig memory config = fs.tokenHasCustomFees[_token] ? 
            fs.tokenFeeConfigs[_token] : 
            LibFee.FeeConfig({
                creatorFeePercentage: 50,
                badBunnzFeePercentage: 25,
                buybackFeePercentage: 25
            });
        
        LibFee.FeeBreakdown memory breakdown = LibFee.calculateTradingFees(
            10000,
            config.creatorFeePercentage,
            config.badBunnzFeePercentage,
            config.buybackFeePercentage
        );
        
        return (
            breakdown.platformFee,
            breakdown.creatorFee,
            breakdown.badBunnzFee,
            breakdown.buybackFee,
            breakdown.totalFee
        );
    }

    /// @notice Get the configured DEX fee percentages for a token
    /// @dev Platform fee is always fixed at 20%, returned as constant
    /// @param _token Token address
    /// @return platformFeePercent Fixed platform fee percentage (always 20)
    /// @return creatorFee Creator percentage of adjustable 80% portion
    /// @return badBunnzFee Bad Bunnz percentage of adjustable 80% portion
    /// @return buybackFee Buyback percentage of adjustable 80% portion
    /// @return hasCustomFees True if the token has its own DEX config
    function getDEXFeeBreakdown(address _token) external view returns (
        uint256 platformFeePercent,
        uint256 creatorFee,
        uint256 badBunnzFee,
        uint256 buybackFee,
        bool hasCustomFees
    ) {
        LibFee.Layout storage fs = LibFee.layout();
        hasCustomFees = fs.tokenHasCustomDEXFees[_token];
        
        LibFee.DEXFeeConfig memory config = hasCustomFees ? 
            fs.tokenDEXFeeConfigs[_token] : 
            fs.globalDEXFeeConfig;
        
        return (
            LibFee.DEX_PLATFORM_FEE_PERCENT, // Fixed 20%
            config.creatorFeePercentage,
            config.badBunnzFeePercentage,
            config.buybackFeePercentage,
            hasCustomFees
        );
    }

    /// @notice Attempt to get the creator from an external token, ignoring failures
    /// @param _token Token address
    /// @return Address of the creator or zero address if unavailable
    function _getTokenCreator(address _token) internal view returns (address) {
        try IMemecoinToken(_token).creator() returns (address creator) {
            return creator;
        } catch {
            return address(0);
        }
    }

    /// @notice Allow the facet to receive raw ETH
    receive() external payable {}
}

/// @title IMemecoinToken
/// @notice Minimal interface used by the fee facet for creator lookup
interface IMemecoinToken {
    function creator() external view returns (address);
}
