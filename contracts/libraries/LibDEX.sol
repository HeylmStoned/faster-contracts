// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LibDEX
 * @notice Diamond storage library for DEX integration and graduation
 * @dev Manages Uniswap V3 addresses, pool mappings and price math helpers
 */
library LibDEX {
    bytes32 constant STORAGE_SLOT = keccak256("launchpad.dex.storage");

    /// @notice Default Uniswap V3 pool fee tier (0.3%)
    uint24 public constant POOL_FEE = 3000;

    /// @notice DEX storage layout for each diamond instance
    struct Layout {
        address uniswapV3Factory;
        address nonfungiblePositionManager;
        address weth;
        mapping(address token => uint256) tokenToPositionId;
        mapping(address token => address) tokenToPool;
        mapping(address token => bool) tokenGraduated;
    }

    /// @notice Return a pointer to the DEX storage layout
    /// @return l Storage pointer to `Layout`
    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    /// @notice Compute Uniswap V3 sqrtPriceX96 from token and quote amounts
    /// @param _numerator Amount of token in the numerator (token0)
    /// @param _denominator Amount of token in the denominator (token1)
    /// @return sqrtPriceX96 Price as a Q64.96 square root value
    function calculateSqrtPriceX96(uint256 _numerator, uint256 _denominator) internal pure returns (uint160) {
        require(_denominator > 0, "denominator cannot be zero");
        if (_numerator == 0) return 0;
        
        uint256 sqrtNum = sqrt(_numerator);
        uint256 sqrtDenom = sqrt(_denominator);
        uint256 result = (sqrtNum * (2**96)) / sqrtDenom;
        return uint160(result);
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

    /// @notice Emitted when a Uniswap V3 pool is created or discovered for a token
    event PoolCreated(address indexed token, address indexed pool);

    /// @notice Emitted when a new liquidity position is created for a token
    event PositionCreated(address indexed token, uint256 positionId);

    /// @notice Emitted when a token is marked as graduated to a DEX pool
    event TokenGraduated(address indexed token, address indexed pool, uint256 positionId);

    /// @notice Emitted when DEX fees are collected for a token
    event FeesCollected(address indexed token, uint256 amount0, uint256 amount1);
}
