// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibToken} from "../libraries/LibToken.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/**
 * @title ERC6909Facet
 * @notice ERC-6909 multi-token singleton facet that operates over shared LibToken storage
 * @dev Exposes core ERC-6909 transfer / approval flows and rich per-id metadata helpers
 */
contract ERC6909Facet {

    /// @notice Transfer `amount` of token `id` from the caller to `receiver`
    /// @dev Reverts if the token id does not exist or the caller has insufficient balance
    /// @param receiver Address receiving the tokens
    /// @param id ERC-6909 token identifier
    /// @param amount Amount of tokens to transfer (18 decimals)
    /// @return success Boolean indicating whether the transfer succeeded
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success) {
        LibToken.Layout storage ts = LibToken.layout();
        require(id > 0 && id <= ts.tokenCount, "Token does not exist");
        require(ts.balanceOf[msg.sender][id] >= amount, "Insufficient balance");
        
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
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool success) {
        LibToken.Layout storage ts = LibToken.layout();
        require(id > 0 && id <= ts.tokenCount, "Token does not exist");
        
        if (sender != msg.sender && !ts.isOperator[sender][msg.sender]) {
            uint256 allowed = ts.allowance[sender][msg.sender][id];
            require(allowed >= amount, "Insufficient permission");
            if (allowed != type(uint256).max) {
                ts.allowance[sender][msg.sender][id] = allowed - amount;
            }
        }
        
        require(ts.balanceOf[sender][id] >= amount, "Insufficient balance");

        ts.balanceOf[sender][id] -= amount;
        ts.balanceOf[receiver][id] += amount;

        emit LibToken.Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    /// @notice Approve `spender` to use `amount` of token `id` owned by the caller
    /// @dev Setting `amount` to type(uint256).max is treated as infinite approval
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

    /// @notice Create a new ERC-6909 token id with rich metadata and fixed total supply
    /// @dev Optionally deploys and wires an ERC-20 wrapper if a wrapper factory is configured in LibToken storage
    /// @param _name Human-readable token name
    /// @param _symbol Short ticker symbol
    /// @param _description Long-form textual description
    /// @param _imageUrl URL to a token image
    /// @param _website Project website URL
    /// @param _twitter Twitter/X handle or URL
    /// @param _telegram Telegram handle or URL
    /// @param _totalSupply Fixed supply for this token id (18 decimals)
    /// @param _recipient Address that ultimately receives the created supply or wrapped ERC-20
    /// @return id Newly created token id
    /// @return wrapper Address of the associated wrapper token or zero address if none was deployed
    function createToken(
        string calldata _name,
        string calldata _symbol,
        string calldata _description,
        string calldata _imageUrl,
        string calldata _website,
        string calldata _twitter,
        string calldata _telegram,
        uint256 _totalSupply,
        address _recipient
    ) external returns (uint256 id, address wrapper) {
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
        token.totalSupply = _totalSupply;
        token.createdAt = block.timestamp;

        if (ts.wrapperFactory != address(0)) {
            ts.balanceOf[address(this)][id] = _totalSupply;
            emit LibToken.Transfer(msg.sender, address(0), address(this), id, _totalSupply);

            wrapper = IWrapperFactory(ts.wrapperFactory).wrap6909(address(this), id, 0);
            ts.tokenWrapper[id] = wrapper;
            ts.allowance[address(this)][wrapper][id] = _totalSupply;
            IWrapped(wrapper).depositFor(_recipient, _totalSupply);

            emit LibToken.TokenCreated(id, msg.sender, _name, _symbol, _totalSupply, wrapper);
        } else {
            ts.balanceOf[_recipient][id] = _totalSupply;
            emit LibToken.TokenCreated(id, msg.sender, _name, _symbol, _totalSupply, address(0));
            emit LibToken.Transfer(msg.sender, address(0), _recipient, id, _totalSupply);
        }
    }

    /// @notice Record an off-chain or DEX trade for a given token id
    /// @dev Only callable by the diamond owner or the configured wrapper for the token id
    /// @param id ERC-6909 token identifier
    /// @param _amount Traded token amount (18 decimals)
    /// @param _price Trade price expressed in wei
    /// @param _buyer Address that acquired tokens in the trade
    function recordTrade(uint256 id, uint256 _amount, uint256 _price, address _buyer) external {
        LibToken.Layout storage ts = LibToken.layout();
        require(id > 0 && id <= ts.tokenCount, "Token does not exist");
        require(
            msg.sender == LibDiamond.contractOwner() || msg.sender == ts.tokenWrapper[id],
            "Only owner or wrapper"
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

    /// @notice Set the global wrapper factory used when creating new token ids
    /// @dev Restricted to the diamond owner; affects subsequent `createToken` calls only
    /// @param _factory Address of the wrapper factory contract
    function setWrapperFactory(address _factory) external {
        LibDiamond.enforceIsContractOwner();
        LibToken.layout().wrapperFactory = _factory;
    }

    /// @notice Pause or unpause a specific token id
    /// @dev Callable by the token creator or the diamond owner
    /// @param id ERC-6909 token identifier
    /// @param _paused True to pause transfers, false to unpause
    function pauseToken(uint256 id, bool _paused) external {
        LibToken.Layout storage ts = LibToken.layout();
        require(id > 0 && id <= ts.tokenCount, "Token does not exist");
        require(
            msg.sender == ts.tokens[id].creator || msg.sender == LibDiamond.contractOwner(),
            "Not authorized"
        );
        ts.tokens[id].isPaused = _paused;
        emit LibToken.TokenPaused(id, _paused);
    }

    /// @notice Mark a token id as verified or unverified
    /// @dev Only the diamond owner can toggle verification status
    /// @param id ERC-6909 token identifier
    /// @param _verified True to set verified, false to unset
    function verifyToken(uint256 id, bool _verified) external {
        LibDiamond.enforceIsContractOwner();
        LibToken.Layout storage ts = LibToken.layout();
        require(id > 0 && id <= ts.tokenCount, "Token does not exist");
        ts.tokens[id].isVerified = _verified;
        emit LibToken.TokenVerified(id, _verified);
    }

    /// @notice Update graduation status and associated pool address for a token id
    /// @dev Intended to be called by the graduation / DEX facet once a token is graduated
    /// @param id ERC-6909 token identifier
    /// @param _graduated True if the token has been graduated to a DEX pool
    /// @param _poolAddress Address of the associated liquidity pool
    function setTokenGraduated(uint256 id, bool _graduated, address _poolAddress) external {
        LibDiamond.enforceIsContractOwner();
        LibToken.Layout storage ts = LibToken.layout();
        require(id > 0 && id <= ts.tokenCount, "Token does not exist");
        ts.tokens[id].graduated = _graduated;
        ts.tokens[id].poolAddress = _poolAddress;
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

    /// @notice Get the decimals used for all token ids in this ERC-6909 instance
    /// @dev All ids share the same decimals; the `id` argument is ignored
    /// @param id ERC-6909 token identifier (unused)
    /// @return decimals_ Number of decimals (always 18)
    function decimals(uint256 id) external pure returns (uint8 decimals_) {
        id; // silence unused parameter warning
        return 18;
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

    /// @notice Get the creator address for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return creatorAddress Address that originally created the token id
    function creator(uint256 id) external view returns (address creatorAddress) {
        return LibToken.layout().tokens[id].creator;
    }

    /// @notice Get the ERC-20 wrapper address, if any, for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return wrapper Address of the wrapper contract or zero address if none
    function getTokenWrapper(uint256 id) external view returns (address wrapper) {
        return LibToken.layout().tokenWrapper[id];
    }

    /// @notice Get the full stored metadata struct for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return data LibToken.TokenData struct containing metadata and stats
    function getTokenData(uint256 id) external view returns (LibToken.TokenData memory data) {
        return LibToken.layout().tokens[id];
    }

    /// @notice Get unpacked extended metadata fields for token id `id`
    /// @param id ERC-6909 token identifier
    /// @return description Long-form description
    /// @return imageUrl Image URL
    /// @return website Project website URL
    /// @return twitter Twitter/X handle or URL
    /// @return telegram Telegram handle or URL
    /// @return createdAt Timestamp when the token id was created
    /// @return lastTradeTime Timestamp of the last recorded trade
    /// @return totalTrades Number of trades recorded for the token id
    /// @return totalVolume Cumulative traded token volume
    /// @return uniqueBuyers Count of unique buyers
    /// @return isPaused Whether the token id is currently paused
    /// @return isVerified Whether the token id is marked as verified
    /// @return graduated Whether the token has been graduated to a DEX
    /// @return poolAddress Address of the graduated pool, if any
    function getExtendedMetadata(uint256 id) external view returns (
        string memory description,
        string memory imageUrl,
        string memory website,
        string memory twitter,
        string memory telegram,
        uint256 createdAt,
        uint256 lastTradeTime,
        uint256 totalTrades,
        uint256 totalVolume,
        uint256 uniqueBuyers,
        bool isPaused,
        bool isVerified,
        bool graduated,
        address poolAddress
    ) {
        LibToken.TokenData memory token = LibToken.layout().tokens[id];
        return (
            token.description,
            token.imageUrl,
            token.website,
            token.twitter,
            token.telegram,
            token.createdAt,
            token.lastTradeTime,
            token.totalTrades,
            token.totalVolume,
            token.uniqueBuyers,
            token.isPaused,
            token.isVerified,
            token.graduated,
            token.poolAddress
        );
    }

    /// @notice Returns true if this facet supports a given interface id
    /// @dev Advertises support for ERC-165 and ERC-6909
    /// @param interfaceId Interface identifier as specified in ERC-165
    /// @return supported True if the interface is supported
    function supportsInterface(bytes4 interfaceId) external pure returns (bool supported) {
        return interfaceId == 0x01ffc9a7
            || interfaceId == 0x0f632fb3;
    }
}

/// @title IWrapperFactory
/// @notice Minimal factory interface for creating ERC-20 wrappers over ERC-6909 ids
interface IWrapperFactory {
    /// @notice Deploy or fetch a wrapper for `token` / `tokenId` and optionally deposit
    /// @param token Address of the ERC-6909 token contract
    /// @param tokenId ERC-6909 token identifier being wrapped
    /// @param initialDeposit Amount of ERC-6909 tokens to deposit into the wrapper
    /// @return wrapper Address of the deployed or existing wrapper contract
    function wrap6909(address token, uint256 tokenId, uint256 initialDeposit) external returns (address wrapper);
}

/// @title IWrapped
/// @notice Minimal interface for a wrapper capable of depositing ERC-6909 balances
interface IWrapped {
    /// @notice Deposit wrapped tokens on behalf of `account`
    /// @param account Recipient of the wrapped ERC-20 tokens
    /// @param amount Amount to deposit and mint
    function depositFor(address account, uint256 amount) external;
}
