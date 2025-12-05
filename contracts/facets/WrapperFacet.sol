// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibToken} from "../libraries/LibToken.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title WrapperFacet
 * @notice Diamond facet responsible for managing ERC-20 wrappers for ERC-6909 token ids
 * @dev Uses EIP-1167 minimal proxies for predictable, gas-efficient wrapper deployment
 */
contract WrapperFacet {
    using Clones for address;

    bytes32 constant WRAPPER_STORAGE_SLOT = keccak256("launchpad.wrapper.storage");

    /// @notice Local storage layout for wrapper configuration and instances
    /// @dev `wrappers` is keyed by keccak256(token, tokenId) to avoid collisions
    struct WrapperLayout {
        address implementation;
        mapping(bytes32 => address) wrappers;
    }

    /// @notice Returns the wrapper-specific storage layout for this diamond
    /// @return l Storage pointer to the wrapper layout
    function wrapperLayout() internal pure returns (WrapperLayout storage l) {
        bytes32 slot = WRAPPER_STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Emitted when a new wrapper is created for a token / tokenId pair
    /// @param token Address of the underlying ERC-6909 contract
    /// @param tokenId ERC-6909 token identifier
    /// @param wrapper Address of the newly created wrapper contract
    event WrapperCreated(address indexed token, uint256 indexed tokenId, address wrapper);

    /// @notice Emitted when the global wrapper implementation is updated
    /// @param implementation New implementation contract address
    event ImplementationSet(address implementation);

    /// @notice Set the implementation contract used for new wrapper deployments
    /// @dev Only the diamond owner can update this value
    /// @param _implementation Address of the deployed implementation contract
    function setWrapperImplementation(address _implementation) external {
        LibDiamond.enforceIsContractOwner();
        require(_implementation != address(0), "Invalid implementation");
        wrapperLayout().implementation = _implementation;
        emit ImplementationSet(_implementation);
    }

    /// @notice Deploy (if needed) and/or use an ERC-20 wrapper for a specific ERC-6909 id
    /// @dev If no wrapper exists yet, a minimal proxy is cloned deterministically and initialized
    /// @param token Address of the underlying ERC-6909 contract
    /// @param tokenId ERC-6909 token identifier
    /// @param initialDeposit Amount of ERC-6909 tokens to immediately wrap and mint as ERC-20
    /// @return wrapper Address of the wrapper ERC-20 contract
    function wrap6909(address token, uint256 tokenId, uint256 initialDeposit) external returns (address wrapper) {
        WrapperLayout storage ws = wrapperLayout();
        require(ws.implementation != address(0), "Implementation not set");
        
        bytes32 key = keccak256(abi.encode(token, tokenId));
        wrapper = ws.wrappers[key];

        if (wrapper == address(0)) {
            bytes32 salt = keccak256(abi.encode(token, tokenId));
            wrapper = ws.implementation.cloneDeterministic(salt);

            LibToken.Layout storage ts = LibToken.layout();
            LibToken.TokenData storage tokenData = ts.tokens[tokenId];

            IWrappedInit(wrapper).initialize(
                token,
                tokenId,
                tokenData.name,
                tokenData.symbol,
                18 // decimals
            );

            ws.wrappers[key] = wrapper;
            ts.tokenWrapper[tokenId] = wrapper;
            emit WrapperCreated(token, tokenId, wrapper);
        }

        if (initialDeposit > 0) {
            IERC6909(token).transferFrom(msg.sender, wrapper, tokenId, initialDeposit);
            IWrappedMint(wrapper).mintTo(msg.sender, initialDeposit);
        }
    }

    /// @notice Return the wrapper address for a given ERC-6909 token / tokenId pair
    /// @param token Address of the underlying ERC-6909 token contract
    /// @param tokenId ERC-6909 token identifier
    /// @return wrapper Address of the wrapper or zero address if not created
    function getWrapper(address token, uint256 tokenId) external view returns (address wrapper) {
        bytes32 key = keccak256(abi.encode(token, tokenId));
        return wrapperLayout().wrappers[key];
    }

    /// @notice Predict the deterministic address of a wrapper for `token` / `tokenId`
    /// @dev Uses the same salt and deployer as `wrap6909` to mirror CREATE2 semantics
    /// @param token Address of the underlying ERC-6909 contract
    /// @param tokenId ERC-6909 token identifier
    /// @return predicted Address where the wrapper would be deployed
    function predictWrapper(address token, uint256 tokenId) external view returns (address predicted) {
        WrapperLayout storage ws = wrapperLayout();
        require(ws.implementation != address(0), "Implementation not set");
        
        bytes32 salt = keccak256(abi.encode(token, tokenId));
        return ws.implementation.predictDeterministicAddress(salt, address(this));
    }

    /// @notice Get the current implementation used for wrapper clones
    /// @return implementation Address of the implementation contract
    function getImplementation() external view returns (address implementation) {
        return wrapperLayout().implementation;
    }
}

/// @title IERC6909
/// @notice Minimal ERC-6909 transferFrom interface used by wrappers
interface IERC6909 {
    /// @notice Transfer `amount` of `id` from `sender` to `receiver`
    /// @param sender Address from which tokens are taken
    /// @param receiver Address receiving the tokens
    /// @param id ERC-6909 token identifier
    /// @param amount Amount of tokens to transfer
    /// @return success Boolean indicating success
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool success);
}

/// @title IWrappedInit
/// @notice Initialization interface for a freshly cloned wrapper contract
interface IWrappedInit {
    /// @notice Initialize wrapper metadata and binding to an ERC-6909 token id
    /// @param token Address of the underlying ERC-6909 contract
    /// @param tokenId ERC-6909 token identifier
    /// @param name ERC-20 name for the wrapper
    /// @param symbol ERC-20 symbol for the wrapper
    /// @param decimals ERC-20 decimals used by the wrapper
    function initialize(address token, uint256 tokenId, string memory name, string memory symbol, uint8 decimals) external;
}

/// @title IWrappedMint
/// @notice Minting interface exposed by wrapper implementations
interface IWrappedMint {
    /// @notice Mint wrapper tokens to `account`
    /// @param account Recipient of newly minted wrapper tokens
    /// @param amount Amount of tokens to mint
    function mintTo(address account, uint256 amount) external;
}
