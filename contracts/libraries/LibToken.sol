// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LibToken
 * @notice Diamond storage library for ERC-6909 multi-token state and metadata
 * @dev Tracks balances, allowances, operators, metadata, and wrapper mappings
 */
library LibToken {
    bytes32 constant STORAGE_SLOT = keccak256("launchpad.token.storage");

    /// @notice Metadata and stats for a single ERC-6909 token id
    struct TokenData {
        string name;
        string symbol;
        string description;
        string imageUrl;
        string website;
        string twitter;
        string telegram;
        address creator;
        uint256 totalSupply;
        uint256 createdAt;
        uint256 lastTradeTime;
        uint256 totalTrades;
        uint256 totalVolume;
        uint256 uniqueBuyers;
        bool isPaused;
        bool isVerified;
        bool graduated;
        address poolAddress;
    }

    /// @notice Global ERC-6909 storage layout for the diamond
    struct Layout {
        uint256 tokenCount;
        mapping(address owner => mapping(uint256 id => uint256 amount)) balanceOf;
        mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) allowance;
        mapping(address owner => mapping(address spender => bool)) isOperator;
        mapping(uint256 id => TokenData) tokens;
        mapping(uint256 id => address) tokenWrapper;
        mapping(uint256 id => mapping(address => bool)) hasBought;
        address wrapperFactory;
    }

    /// @notice Return a pointer to the ERC-6909 token storage layout
    /// @return l Storage pointer to `Layout`
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Emitted when tokens are transferred between accounts
    event Transfer(address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);

    /// @notice Emitted when an operator approval is set or cleared
    event OperatorSet(address indexed owner, address indexed spender, bool approved);

    /// @notice Emitted when an allowance is set for a specific id
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    /// @notice Emitted when a new token id is created
    event TokenCreated(
        uint256 indexed id,
        address indexed creator,
        string name,
        string symbol,
        uint256 totalSupply,
        address wrapper
    );

    /// @notice Emitted when a token id is paused or unpaused
    event TokenPaused(uint256 indexed id, bool paused);

    /// @notice Emitted when a token id is marked verified or unverified
    event TokenVerified(uint256 indexed id, bool verified);

    /// @notice Emitted when a trade is recorded for a token id
    event TradeRecorded(uint256 indexed id, uint256 amount, uint256 price, address buyer);
}
