// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibToken} from "../libraries/LibToken.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibFee} from "../libraries/LibFee.sol";
import {LibSecurity} from "../libraries/LibSecurity.sol";

/**
 * @title TokenFacet
 * @notice ERC-6909 multi-token implementation with metadata
 * @dev Handles token creation, transfers, and approvals
 */
contract TokenFacet {
    /// @notice Thrown when a balance is insufficient for an operation
    error InsufficientBalance(address owner, uint256 id);
    /// @notice Thrown when allowance or operator permission is insufficient
    error InsufficientPermission(address spender, uint256 id);
    /// @notice Thrown when referencing a non-existent token id
    error TokenDoesNotExist(uint256 id);
    /// @notice Thrown when attempting an action on an already paused token
    error TokenAlreadyPaused(uint256 id);

    /// @notice Restrict functions to existing token ids
    /// @param id ERC-6909 token identifier
    modifier tokenExists(uint256 id) {
        if (id == 0 || id > LibToken.layout().tokenCount) revert TokenDoesNotExist(id);
        _;
    }

    /// @notice Fixed total supply for all tokens (1 million with 18 decimals)
    /// @dev 400k sold via bonding curve, 600k reserved for DEX liquidity
    uint256 public constant TOTAL_SUPPLY = 1_000_000 ether;

    /// @notice Create a new ERC-6909 token with full configuration
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _description Token description
    /// @param _imageUrl Token image URL
    /// @param _website Project website
    /// @param _twitter Twitter handle
    /// @param _telegram Telegram handle
    /// @param _creatorFeePercentage Creator's share of BC trading fees (must sum to 100 with others)
    /// @param _badBunnzFeePercentage Bad Bunnz share of BC trading fees
    /// @param _buybackFeePercentage Buyback share of BC trading fees
    /// @param _dexPlatformFeePercentage Platform share of DEX LP fees (must sum to 100 with others)
    /// @param _dexCreatorFeePercentage Creator share of DEX LP fees
    /// @param _dexBadBunnzFeePercentage Bad Bunnz share of DEX LP fees
    /// @param _dexBuybackFeePercentage Buyback share of DEX LP fees
    /// @param _enableFairLaunch Whether to enable fair launch mode
    /// @param _fairLaunchDuration Duration of fair launch in seconds
    /// @param _maxPerWallet Max tokens per wallet during fair launch
    /// @param _fixedPrice Fixed price during fair launch
    /// @return id Token ID
    /// @return wrapper ERC-20 wrapper address
    function createToken(
        string calldata _name,
        string calldata _symbol,
        string calldata _description,
        string calldata _imageUrl,
        string calldata _website,
        string calldata _twitter,
        string calldata _telegram,
        uint256 _creatorFeePercentage,
        uint256 _badBunnzFeePercentage,
        uint256 _buybackFeePercentage,
        uint256 _dexPlatformFeePercentage,
        uint256 _dexCreatorFeePercentage,
        uint256 _dexBadBunnzFeePercentage,
        uint256 _dexBuybackFeePercentage,
        bool _enableFairLaunch,
        uint256 _fairLaunchDuration,
        uint256 _maxPerWallet,
        uint256 _fixedPrice
    ) external returns (uint256 id, address wrapper) {
        // Validate fee percentages
        require(
            _creatorFeePercentage + _badBunnzFeePercentage + _buybackFeePercentage == 100,
            "BC fee percentages must sum to 100"
        );
        require(
            _dexPlatformFeePercentage + _dexCreatorFeePercentage + _dexBadBunnzFeePercentage + _dexBuybackFeePercentage == 100,
            "DEX fee percentages must sum to 100"
        );
        
        // Validate fair launch params if enabled
        if (_enableFairLaunch) {
            require(_fairLaunchDuration > 0, "Fair launch duration must be > 0");
            require(_maxPerWallet > 0, "Max per wallet must be > 0");
            require(_fixedPrice > 0, "Fixed price must be > 0");
        }
        
        // 1. Create the token
        LibToken.Layout storage ts = LibToken.layout();
        id = ++ts.tokenCount;
        
        LibToken.TokenData storage token = ts.tokens[id];
        token.name = _name;
        token.symbol = _symbol;
        token.description = _description;
        token.imageUrl = _imageUrl;
        token.website = _website;
        token.twitter = _twitter;
        token.telegram = _telegram;
        token.creator = msg.sender;
        token.totalSupply = TOTAL_SUPPLY;
        token.createdAt = block.timestamp;

        ts.balanceOf[address(this)][id] = TOTAL_SUPPLY;
        emit LibToken.Transfer(msg.sender, address(0), address(this), id, TOTAL_SUPPLY);
        
        if (ts.wrapperFactory != address(0)) {
            wrapper = IWrapperFactory(ts.wrapperFactory).wrap6909(address(this), id, 0);
            ts.tokenWrapper[id] = wrapper;
            ts.allowance[address(this)][wrapper][id] = TOTAL_SUPPLY;
        }
        
        emit LibToken.TokenCreated(id, msg.sender, _name, _symbol, TOTAL_SUPPLY, wrapper);
        
        // 2. Set BC fee configuration
        LibFee.Layout storage fs = LibFee.layout();
        fs.tokenFeeConfigs[wrapper] = LibFee.FeeConfig({
            creatorFeePercentage: _creatorFeePercentage,
            badBunnzFeePercentage: _badBunnzFeePercentage,
            buybackFeePercentage: _buybackFeePercentage
        });
        fs.tokenHasCustomFees[wrapper] = true;
        emit LibFee.FeeConfigSet(wrapper, _creatorFeePercentage, _badBunnzFeePercentage, _buybackFeePercentage);
        
        // 3. Set DEX fee configuration
        fs.tokenDEXFeeConfigs[wrapper] = LibFee.DEXFeeConfig({
            platformFeePercentage: _dexPlatformFeePercentage,
            creatorFeePercentage: _dexCreatorFeePercentage,
            badBunnzFeePercentage: _dexBadBunnzFeePercentage,
            buybackFeePercentage: _dexBuybackFeePercentage
        });
        fs.tokenHasCustomDEXFees[wrapper] = true;
        emit LibFee.DEXFeeConfigSet(wrapper, _dexPlatformFeePercentage, _dexCreatorFeePercentage, _dexBadBunnzFeePercentage, _dexBuybackFeePercentage);
        
        // 4. Enable fair launch if requested
        if (_enableFairLaunch) {
            LibSecurity.Layout storage ss = LibSecurity.layout();
            ss.fairLaunchConfigs[wrapper] = LibSecurity.FairLaunchConfig({
                enabled: true,
                duration: _fairLaunchDuration,
                maxPerWallet: _maxPerWallet,
                fixedPrice: _fixedPrice,
                startTime: block.timestamp
            });
            emit LibSecurity.FairLaunchEnabled(wrapper, _fairLaunchDuration, _maxPerWallet);
        }
    }

    /// @notice Transfer `amount` of token `id` from the caller to `receiver`
    /// @param receiver Address receiving the tokens
    /// @param id ERC-6909 token identifier
    /// @param amount Amount of tokens to transfer (18 decimals)
    /// @return success Boolean indicating whether the transfer succeeded
    function transfer(address receiver, uint256 id, uint256 amount) external tokenExists(id) returns (bool success) {
        LibToken.Layout storage ts = LibToken.layout();
        if (ts.balanceOf[msg.sender][id] < amount) revert InsufficientBalance(msg.sender, id);
        
        ts.balanceOf[msg.sender][id] -= amount;
        ts.balanceOf[receiver][id] += amount;
        
        emit LibToken.Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    /// @notice Transfer `amount` of token `id` from `sender` to `receiver`
    /// @dev Uses per-id allowances unless the caller is an operator for `sender`
    /// @param sender Address whose balance is debited
    /// @param receiver Address whose balance is credited
    /// @param id ERC-6909 token identifier
    /// @param amount Amount of tokens to transfer (18 decimals)
    /// @return success Boolean indicating whether the transfer succeeded
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external tokenExists(id) returns (bool success) {
        LibToken.Layout storage ts = LibToken.layout();
        
        if (sender != msg.sender && !ts.isOperator[sender][msg.sender]) {
            uint256 allowed = ts.allowance[sender][msg.sender][id];
            if (allowed < amount) revert InsufficientPermission(msg.sender, id);
            if (allowed != type(uint256).max) {
                ts.allowance[sender][msg.sender][id] = allowed - amount;
            }
        }
        
        if (ts.balanceOf[sender][id] < amount) revert InsufficientBalance(sender, id);
        
        ts.balanceOf[sender][id] -= amount;
        ts.balanceOf[receiver][id] += amount;
        
        emit LibToken.Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /// @notice Approve `spender` to use `amount` of token `id` owned by the caller
    /// @param spender Address that is approved to spend
    /// @param id ERC-6909 token identifier
    /// @param amount Approved amount (18 decimals)
    /// @return success Boolean indicating whether the approval was recorded
    function approve(address spender, uint256 id, uint256 amount) external returns (bool success) {
        LibToken.layout().allowance[msg.sender][spender][id] = amount;
        emit LibToken.Approval(msg.sender, spender, id, amount);
        return true;
    }

    /// @notice Set or revoke an operator approval for all token ids of the caller
    /// @param spender Address that is granted or revoked operator status
    /// @param approved True to grant operator rights, false to revoke
    /// @return success Boolean indicating whether the operator flag was updated
    function setOperator(address spender, bool approved) external returns (bool success) {
        LibToken.layout().isOperator[msg.sender][spender] = approved;
        emit LibToken.OperatorSet(msg.sender, spender, approved);
        return true;
    }

    /// @notice Get the balance of `owner` for token `id`
    /// @param owner Address whose balance is queried
    /// @param id ERC-6909 token identifier
    /// @return balance Amount of tokens owned by `owner`
    function balanceOf(address owner, uint256 id) external view returns (uint256 balance) {
        return LibToken.layout().balanceOf[owner][id];
    }

    /// @notice Get the remaining per-id allowance from `owner` to `spender`
    /// @param owner Token owner address
    /// @param spender Approved spender address
    /// @param id ERC-6909 token identifier
    /// @return remaining Remaining allowance for this id
    function allowance(address owner, address spender, uint256 id) external view returns (uint256 remaining) {
        return LibToken.layout().allowance[owner][spender][id];
    }

    /// @notice Check if `spender` is an operator for all token ids of `owner`
    /// @param owner Token owner address
    /// @param spender Potential operator address
    /// @return approved True if `spender` is an operator for `owner`
    function isOperator(address owner, address spender) external view returns (bool approved) {
        return LibToken.layout().isOperator[owner][spender];
    }

    /// @notice Get the name for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return tokenName Human-readable token name
    function name(uint256 id) external view returns (string memory tokenName) {
        return LibToken.layout().tokens[id].name;
    }

    /// @notice Get the symbol for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return tokenSymbol Ticker symbol
    function symbol(uint256 id) external view returns (string memory tokenSymbol) {
        return LibToken.layout().tokens[id].symbol;
    }

    /// @notice Get the total supply for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return supply Total supply of the token id
    function totalSupply(uint256 id) external view returns (uint256 supply) {
        return LibToken.layout().tokens[id].totalSupply;
    }

    /// @notice Get the number of token ids that have been created
    /// @return count Latest token id that has been created
    function tokenCount() external view returns (uint256 count) {
        return LibToken.layout().tokenCount;
    }

    /// @notice Get the full stored metadata struct for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return data LibToken.TokenData struct containing metadata and stats
    function getTokenData(uint256 id) external view returns (LibToken.TokenData memory data) {
        return LibToken.layout().tokens[id];
    }

    /// @notice Get the ERC-20 wrapper address, if any, for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return wrapper Address of the wrapper contract or zero address if none
    function getTokenWrapper(uint256 id) external view returns (address wrapper) {
        return LibToken.layout().tokenWrapper[id];
    }

    /// @notice Get the creator address for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return creatorAddress Address that originally created the token id
    function creator(uint256 id) external view returns (address creatorAddress) {
        return LibToken.layout().tokens[id].creator;
    }

    /// @notice Set the global wrapper factory used when creating new token ids
    /// @param _factory Address of the wrapper factory contract
    function setWrapperFactory(address _factory) external {
        LibDiamond.enforceIsContractOwner();
        LibToken.layout().wrapperFactory = _factory;
    }

    /// @notice Pause or unpause a specific token id
    /// @dev Callable by the token creator or the diamond owner
    /// @param id ERC-6909 token identifier
    /// @param _paused True to pause transfers, false to unpause
    function pauseToken(uint256 id, bool _paused) external tokenExists(id) {
        LibToken.Layout storage ts = LibToken.layout();
        require(msg.sender == ts.tokens[id].creator || msg.sender == LibDiamond.contractOwner(), "Not authorized");
        ts.tokens[id].isPaused = _paused;
        emit LibToken.TokenPaused(id, _paused);
    }

    /// @notice Mark a token id as verified or unverified
    /// @dev Only the diamond owner can toggle verification status
    /// @param id ERC-6909 token identifier
    /// @param _verified True to set verified, false to unset
    function verifyToken(uint256 id, bool _verified) external tokenExists(id) {
        LibDiamond.enforceIsContractOwner();
        LibToken.layout().tokens[id].isVerified = _verified;
        emit LibToken.TokenVerified(id, _verified);
    }

    /// @notice Record an off-chain or DEX trade for a given token id
    /// @dev Only callable by the wrapper for the id or the diamond owner
    /// @param id ERC-6909 token identifier
    /// @param _amount Traded token amount (18 decimals)
    /// @param _price Trade price expressed in wei
    /// @param _buyer Address that acquired tokens in the trade
    function recordTrade(uint256 id, uint256 _amount, uint256 _price, address _buyer) external tokenExists(id) {
        LibToken.Layout storage ts = LibToken.layout();
        // Allow wrapper or owner to call
        require(
            msg.sender == ts.tokenWrapper[id] || msg.sender == LibDiamond.contractOwner(),
            "Not authorized"
        );
        
        LibToken.TokenData storage token = ts.tokens[id];
        token.totalTrades++;
        token.lastTradeTime = block.timestamp;
        token.totalVolume += _amount;
        
        if (!ts.hasBought[id][_buyer]) {
            ts.hasBought[id][_buyer] = true;
            token.uniqueBuyers++;
        }
        
        emit LibToken.TradeRecorded(id, _amount, _price, _buyer);
    }
}

/// @title IWrapperFactory
/// @notice Minimal factory interface for creating ERC-20 wrappers over ERC-6909 ids
interface IWrapperFactory {
    function wrap6909(address token, uint256 tokenId, uint256 initialDeposit) external returns (address);
}

/// @title IWrapped
/// @notice Minimal interface for a wrapper capable of depositing ERC-6909 balances
interface IWrapped {
    function depositFor(address account, uint256 amount) external;
}
