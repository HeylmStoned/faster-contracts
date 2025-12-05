// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibTrading} from "../libraries/LibTrading.sol";
import {LibToken} from "../libraries/LibToken.sol";
import {LibFee} from "../libraries/LibFee.sol";
import {LibSecurity} from "../libraries/LibSecurity.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibDEX} from "../libraries/LibDEX.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TradingFacet
 * @notice Handles bonding curve trading operations
 * @dev Implements buy/sell with exponential bonding curve and auto-graduation
 */
contract TradingFacet is ReentrancyGuard {

    /// @notice Initialize trading state for a token
    /// @param _token Token address to initialize
    function initializeToken(address _token) external {
        LibDiamond.enforceIsContractOwner();
        LibTrading.Layout storage ts = LibTrading.layout();
        require(ts.tokenTradingData[_token].createdAt == 0, "Token already initialized");
        
        ts.tokenTradingData[_token] = LibTrading.TokenTradingData({
            totalSold: 0,
            totalRaised: 0,
            isOpen: true,
            createdAt: block.timestamp
        });
        
        emit LibTrading.TokenTradingDataUpdated(_token, 0, 0, true);
    }

    /// @notice Buy bonding-curve tokens using ETH
    /// @param _token Token address being purchased
    /// @param _buyer Address that will receive tokens and refunds
    /// @param _minTokensOut Minimum acceptable tokens out to protect against slippage
    /// @return tokensOut Amount of tokens bought
    /// @return ethSpent ETH amount actually spent (excluding fee)
    function buyWithETH(
        address _token,
        address _buyer,
        uint256 _minTokensOut
    ) external payable nonReentrant returns (uint256 tokensOut, uint256 ethSpent) {
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData storage data = ts.tokenTradingData[_token];
        LibSecurity.Layout storage ss = LibSecurity.layout();
        
        require(data.isOpen, "Trading is closed");
        require(msg.value > 0, "Must send ETH");
        require(msg.value <= LibTrading.MAX_BUY_AMOUNT, "Exceeds max buy amount (1 ETH)");
        require(!ss.tokenPaused[_token], "Token is paused");
        
        LibSecurity.FairLaunchConfig memory fairConfig = ss.fairLaunchConfigs[_token];
        if (LibSecurity.isFairLaunchActive(fairConfig)) {
            uint256 currentPurchased = ss.walletPurchases[_token][_buyer];
            require(
                LibSecurity.validateFairLaunchBuy(fairConfig, currentPurchased, 0),
                "Fair launch: validation failed"
            );
        }
        
        uint256 fee = (msg.value * LibFee.TOTAL_TRADING_FEE) / LibFee.BASIS_POINTS;
        uint256 ethForTokens = msg.value - fee;
        
        bool isFairLaunch = LibSecurity.isFairLaunchActive(fairConfig);
        
        if (isFairLaunch) {
            // Fair launch: use fixed price
            tokensOut = (ethForTokens * 1e18) / fairConfig.fixedPrice;
            ethSpent = (tokensOut * fairConfig.fixedPrice) / 1e18;
        } else {
            // Normal: use bonding curve
            tokensOut = LibTrading.getTokensForETH(data.totalSold, ethForTokens);
            ethSpent = LibTrading.getBuyCost(data.totalSold, tokensOut);
        }
        
        require(tokensOut > 0, "Insufficient ETH for purchase");
        
        if (data.totalSold + tokensOut > LibTrading.TOKEN_LIMIT) {
            tokensOut = LibTrading.TOKEN_LIMIT - data.totalSold;
            require(tokensOut > 0, "Token limit reached");
            // Recalculate ethSpent for capped amount
            if (isFairLaunch) {
                ethSpent = (tokensOut * fairConfig.fixedPrice) / 1e18;
            } else {
                ethSpent = LibTrading.getBuyCost(data.totalSold, tokensOut);
            }
        }
        
        require(tokensOut >= _minTokensOut, "Output below minimum (slippage too high)");
        
        if (isFairLaunch) {
            uint256 currentPurchased = ss.walletPurchases[_token][_buyer];
            require(currentPurchased + tokensOut <= fairConfig.maxPerWallet, "Exceeds max per wallet");
            ss.walletPurchases[_token][_buyer] = currentPurchased + tokensOut;
        }
        require(ethSpent <= ethForTokens, "Calculation error");
        
        data.totalSold += tokensOut;
        data.totalRaised += ethSpent;
        
        require(IERC20(_token).balanceOf(address(this)) >= tokensOut, "Insufficient token balance");
        IERC20(_token).transfer(_buyer, tokensOut);
        
        address creator = _getTokenCreator(_token);
        _distributeTradingFees(_token, creator, fee);
        
        _recordTrade(_token, tokensOut, ethSpent, _buyer);
        
        uint256 refund = ethForTokens - ethSpent;
        if (refund > 0) {
            (bool success, ) = payable(_buyer).call{value: refund}("");
            require(success, "Refund failed");
        }
        
        emit LibTrading.TokenBought(_token, _buyer, tokensOut, ethSpent);
        emit LibTrading.TokenTradingDataUpdated(_token, data.totalSold, data.totalRaised, data.isOpen);
        
        uint256 tokenTarget = _getTokenTarget(_token);
        if (data.totalSold >= LibTrading.TOKEN_LIMIT || data.totalRaised >= tokenTarget) {
            data.isOpen = false;
            emit LibTrading.TokenTradingDataUpdated(_token, data.totalSold, data.totalRaised, false);
            
            // Check if not already graduated
            LibDEX.Layout storage ds = LibDEX.layout();
            if (!ds.tokenGraduated[_token]) {
                try IGraduationFacet(address(this)).graduate(_token) {
                } catch {
                    emit GraduationFailed(_token, "Auto-graduation failed - use manual graduation");
                }
            }
        }
    }
    
    event GraduationFailed(address indexed token, string reason);
    
    /// @dev Get effective ETH target for a token, falling back to default if unset
    function _getTokenTarget(address _token) internal view returns (uint256) {
        LibTrading.Layout storage ts = LibTrading.layout();
        uint256 customTarget = ts.tokenTargets[_token];
        return customTarget > 0 ? customTarget : LibTrading.DEFAULT_ETH_TARGET;
    }

    /// @notice Sell bonding-curve tokens back for ETH
    /// @param _token Token address being sold
    /// @param _amount Amount of tokens to sell
    /// @param _seller Address that will receive ETH proceeds
    /// @param _minEthOut Minimum acceptable ETH out to protect against slippage
    /// @return price Gross ETH before fee
    /// @return fee Trading fee deducted in ETH
    function sellToken(
        address _token,
        uint256 _amount,
        address _seller,
        uint256 _minEthOut
    ) external nonReentrant returns (uint256 price, uint256 fee) {
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData storage data = ts.tokenTradingData[_token];
        LibSecurity.Layout storage ss = LibSecurity.layout();
        
        require(data.isOpen, "Trading is closed");
        require(ts.sellsEnabled[_token], "Sells not enabled for this token");
        require(_amount > 0, "Amount must be greater than 0");
        require(data.totalSold >= _amount, "Insufficient tokens to sell");
        require(!ss.tokenPaused[_token], "Token is paused");
        
        price = LibTrading.getSellProceeds(data.totalSold, _amount);
        fee = (price * LibFee.TOTAL_TRADING_FEE) / LibFee.BASIS_POINTS;
        uint256 netProceeds = price - fee;
        
        require(netProceeds > 0, "Net proceeds must be greater than 0");
        require(netProceeds >= _minEthOut, "Output below minimum (slippage too high)");
        
        data.totalSold -= _amount;
        data.totalRaised -= price;
        
        IERC20(_token).transferFrom(_seller, address(this), _amount);
        
        address creator = _getTokenCreator(_token);
        _distributeTradingFees(_token, creator, fee);
        
        _recordTrade(_token, _amount, price, _seller);
        
        (bool success, ) = payable(_seller).call{value: netProceeds}("");
        require(success, "ETH transfer failed");
        
        emit LibTrading.TokenSold(_token, _seller, _amount, price);
        emit LibTrading.TokenTradingDataUpdated(_token, data.totalSold, data.totalRaised, data.isOpen);
    }

    /// @notice Manually close trading for a token
    /// @param _token Token address to close
    function closeTrading(address _token) external {
        LibDiamond.enforceIsContractOwner();
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData storage data = ts.tokenTradingData[_token];
        data.isOpen = false;
        
        emit LibTrading.TokenTradingDataUpdated(_token, data.totalSold, data.totalRaised, data.isOpen);
    }

    /// @notice Enable or disable sells for a token (admin only)
    /// @dev Sells are disabled by default - must be explicitly enabled
    /// @param _token Token address
    /// @param _enabled True to allow sells, false to disable
    function setSellsEnabled(address _token, bool _enabled) external {
        LibDiamond.enforceIsContractOwner();
        LibTrading.layout().sellsEnabled[_token] = _enabled;
        emit LibTrading.SellsEnabledUpdated(_token, _enabled);
    }

    /// @notice Check if sells are enabled for a token
    /// @param _token Token address
    /// @return True if sells are enabled
    function areSellsEnabled(address _token) external view returns (bool) {
        return LibTrading.layout().sellsEnabled[_token];
    }

    /// @notice Withdraw remaining tokens and raised ETH in preparation for graduation
    /// @param _token Token address being prepared for graduation
    /// @return remainingTokens Remaining token balance withdrawn to caller
    /// @return raisedETH Total ETH raised withdrawn to caller
    /// @return totalSold Final total sold amount
    function withdrawForGraduation(address _token) external returns (uint256 remainingTokens, uint256 raisedETH, uint256 totalSold) {
        LibDiamond.enforceIsContractOwner();
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData storage data = ts.tokenTradingData[_token];
        
        require(!data.isOpen, "Trading must be closed first");
        
        remainingTokens = IERC20(_token).balanceOf(address(this));
        require(remainingTokens > 0, "No tokens to withdraw");
        
        raisedETH = data.totalRaised;
        require(address(this).balance >= raisedETH, "Insufficient ETH balance");
        
        totalSold = data.totalSold;
        
        IERC20(_token).transfer(msg.sender, remainingTokens);
        (bool success, ) = payable(msg.sender).call{value: raisedETH}("");
        require(success, "ETH transfer failed");
    }

    /// @notice Distribute trading fees between platform, creator, Bad Bunnz, and buyback
    /// @param _token Token the fees were generated from
    /// @param _creator Creator address associated with the token
    /// @param _tradingFee Total trading fee amount in wei
    function _distributeTradingFees(address _token, address _creator, uint256 _tradingFee) internal {
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

    /// @notice Attempt to read creator from token, ignoring failures
    /// @param _token Token address implementing `creator()`
    /// @return Address of the creator or zero address if unavailable
    function _getTokenCreator(address _token) internal view returns (address) {
        try IMemecoinToken(_token).creator() returns (address creator) {
            return creator;
        } catch {
            return address(0);
        }
    }

    /// @notice Attempt to record a trade on the token contract, ignoring failures
    /// @param _token Token contract expected to implement `recordTrade`
    /// @param _amount Amount traded
    /// @param _price Price in wei
    /// @param _buyer Buyer address
    function _recordTrade(address _token, uint256 _amount, uint256 _price, address _buyer) internal {
        try IMemecoinToken(_token).recordTrade(_amount, _price, _buyer) {} catch {}
    }

    /// @notice Get expected buy price and fee for purchasing `_amount` tokens
    /// @param _token Token address
    /// @param _amount Token amount to buy
    /// @return price Gross ETH required
    /// @return fee Trading fee amount in ETH
    function getBuyPrice(address _token, uint256 _amount) external view returns (uint256 price, uint256 fee) {
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData memory data = ts.tokenTradingData[_token];
        require(data.isOpen, "Trading is closed");
        
        price = LibTrading.getBuyCost(data.totalSold, _amount);
        fee = (price * LibFee.TOTAL_TRADING_FEE) / LibFee.BASIS_POINTS;
    }

    /// @notice Get expected sell price and fee for selling `_amount` tokens
    /// @param _token Token address
    /// @param _amount Token amount to sell
    /// @return price Gross ETH returned
    /// @return fee Trading fee amount in ETH
    function getSellPrice(address _token, uint256 _amount) external view returns (uint256 price, uint256 fee) {
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData memory data = ts.tokenTradingData[_token];
        require(data.isOpen, "Trading is closed");
        require(data.totalSold >= _amount, "Insufficient tokens to sell");
        
        price = LibTrading.getSellProceeds(data.totalSold, _amount);
        fee = (price * LibFee.TOTAL_TRADING_FEE) / LibFee.BASIS_POINTS;
    }

    /// @notice Get the current bonding curve price for a token
    /// @param _token Token address
    /// @return Current price in wei per token
    function getCurrentPrice(address _token) external view returns (uint256) {
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData memory data = ts.tokenTradingData[_token];
        return LibTrading.getCurrentPrice(data.totalSold);
    }

    /// @notice Get aggregated trading stats and current price for a token
    /// @param _token Token address
    /// @return totalSold Total tokens sold
    /// @return totalRaised Total ETH raised
    /// @return currentPrice Current price in wei per token
    /// @return isOpen Whether trading is open
    function getTokenStats(address _token) external view returns (
        uint256 totalSold,
        uint256 totalRaised,
        uint256 currentPrice,
        bool isOpen
    ) {
        LibTrading.Layout storage ts = LibTrading.layout();
        LibTrading.TokenTradingData memory data = ts.tokenTradingData[_token];
        return (
            data.totalSold,
            data.totalRaised,
            LibTrading.getCurrentPrice(data.totalSold),
            data.isOpen
        );
    }

    /// @notice Get raw trading data struct for a token
    /// @param _token Token address
    /// @return LibTrading.TokenTradingData struct
    function getTokenTradingData(address _token) external view returns (LibTrading.TokenTradingData memory) {
        return LibTrading.layout().tokenTradingData[_token];
    }

    /// @notice Get effective ETH target for a token
    /// @param _token Token address
    /// @return Target ETH amount for graduation
    function getTokenTarget(address _token) external view returns (uint256) {
        return _getTokenTarget(_token);
    }

    /// @notice Set custom ETH graduation target for a token
    /// @param _token Token address
    /// @param _target Target ETH amount (must be >0 and <= 1000 ETH)
    function setTokenTarget(address _token, uint256 _target) external {
        LibDiamond.enforceIsContractOwner();
        require(_target > 0, "Target must be > 0");
        require(_target <= 1000 ether, "Target cannot exceed 1000 ETH");
        LibTrading.layout().tokenTargets[_token] = _target;
        emit TokenTargetSet(_token, _target);
    }

    /// @notice Emitted when a custom ETH target is set for a token
    event TokenTargetSet(address indexed token, uint256 target);

    /// @notice Allow the facet to receive ETH from trades and refunds
    receive() external payable {}
}

/// @title IMemecoinToken
/// @notice Minimal interface used by trading for creator lookup and trade recording
interface IMemecoinToken {
    function creator() external view returns (address);
    function recordTrade(uint256 amount, uint256 price, address buyer) external;
}

/// @title IGraduationFacet
/// @notice Minimal interface to trigger token graduation
interface IGraduationFacet {
    function graduate(address _token) external returns (address pool, uint256 positionId);
}
