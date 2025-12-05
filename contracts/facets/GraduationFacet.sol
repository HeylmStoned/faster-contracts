// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDEX} from "../libraries/LibDEX.sol";
import {LibTrading} from "../libraries/LibTrading.sol";
import {LibFee} from "../libraries/LibFee.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GraduationFacet
 * @notice Handles token graduation from bonding curve to Uniswap V3
 * @dev Creates pool, burns excess tokens, and provides initial liquidity
 */
contract GraduationFacet is ReentrancyGuard {

    /// @notice Burn address used to destroy excess tokens
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Graduate a token from bonding curve to a Uniswap V3 pool
    /// @dev Computes pool price to match final bonding-curve price and seeds full-range liquidity
    /// @param _token Token address to graduate
    /// @return pool Created or existing Uniswap V3 pool address
    /// @return positionId NFT position ID for the liquidity
    function graduate(address _token) external returns (address pool, uint256 positionId) {
        // Allow owner OR self-call (for auto-graduation)
        require(
            msg.sender == LibDiamond.contractOwner() || msg.sender == address(this),
            "Only owner or self"
        );
        LibDEX.Layout storage ds = LibDEX.layout();
        LibTrading.Layout storage ts = LibTrading.layout();
        LibFee.Layout storage fs = LibFee.layout();
        
        require(!ds.tokenGraduated[_token], "Token already graduated");
        
        // 1. Close trading if still open
        LibTrading.TokenTradingData storage data = ts.tokenTradingData[_token];
        if (data.isOpen) {
            data.isOpen = false;
            emit LibTrading.TokenTradingDataUpdated(_token, data.totalSold, data.totalRaised, false);
        }
        
        // 2. Get balances
        uint256 tokenBalance = IERC20(_token).balanceOf(address(this));
        uint256 ethBalance = data.totalRaised;
        uint256 totalSold = data.totalSold;
        
        require(tokenBalance > 0, "No tokens to graduate");
        require(ethBalance > 0, "No ETH to graduate");
        
        // 3. Deduct graduation fee
        uint256 graduationFee = LibFee.GRADUATION_FEE_ETH;
        require(ethBalance > graduationFee, "Insufficient ETH for graduation");
        
        fs.totalGraduationFees += graduationFee;
        uint256 ethForDEX = ethBalance - graduationFee;
        
        // 4. Calculate final bonding curve price
        uint256 finalPrice = LibTrading.getBuyPrice(totalSold);
        
        // 5. Calculate tokens for DEX to match BC price
        // DEX price = ethForDEX / tokensForDEX => tokensForDEX = ethForDEX * 1e18 / finalPrice
        uint256 tokensForDEX = (ethForDEX * 1e18) / finalPrice;
        
        // Cap at available tokens
        if (tokensForDEX > tokenBalance) {
            tokensForDEX = tokenBalance;
        }
        
        // 6. Burn excess tokens
        uint256 tokensToBurn = tokenBalance - tokensForDEX;
        if (tokensToBurn > 0) {
            IERC20(_token).transfer(DEAD_ADDRESS, tokensToBurn);
            emit TokensBurned(_token, tokensToBurn);
        }
        
        // 7. Create pool and position
        pool = _createOrGetPool(_token, tokensForDEX, ethForDEX);
        
        // Convert ETH to WETH
        IWETH(ds.weth).deposit{value: ethForDEX}();
        
        // Approve tokens
        IERC20(_token).approve(ds.nonfungiblePositionManager, tokensForDEX);
        IERC20(ds.weth).approve(ds.nonfungiblePositionManager, ethForDEX);
        
        // Create position
        positionId = _createLiquidityPosition(_token, tokensForDEX, ethForDEX);
        
        // Store mappings
        ds.tokenToPool[_token] = pool;
        ds.tokenToPositionId[_token] = positionId;
        ds.tokenGraduated[_token] = true;
        
        emit LibDEX.PoolCreated(_token, pool);
        emit LibDEX.PositionCreated(_token, positionId);
        emit LibDEX.TokenGraduated(_token, pool, positionId);
    }
    
    /// @notice Emitted when surplus tokens are burned during graduation
    event TokensBurned(address indexed token, uint256 amount);

    /// @notice Manually create a pool and position without relying on bonding curve state
    /// @param _token Token address
    /// @param _tokenAmount Token amount to deposit as liquidity
    /// @param _ethAmount ETH amount to deposit as liquidity
    /// @return pool Uniswap V3 pool address
    /// @return positionId NFT position ID for the liquidity position
    function createPoolAndPosition(
        address _token,
        uint256 _tokenAmount,
        uint256 _ethAmount
    ) external payable nonReentrant returns (address pool, uint256 positionId) {
        LibDiamond.enforceIsContractOwner();
        LibDEX.Layout storage ds = LibDEX.layout();
        
        require(!ds.tokenGraduated[_token], "Token already graduated");
        require(_tokenAmount > 0, "Token amount must be greater than 0");
        require(_ethAmount > 0, "ETH amount must be greater than 0");
        
        // Create or get pool
        pool = _createOrGetPool(_token, _tokenAmount, _ethAmount);
        
        // Convert ETH to WETH
        IWETH(ds.weth).deposit{value: _ethAmount}();
        
        // Approve tokens
        IERC20(_token).approve(ds.nonfungiblePositionManager, _tokenAmount);
        IERC20(ds.weth).approve(ds.nonfungiblePositionManager, _ethAmount);
        
        // Create position
        positionId = _createLiquidityPosition(_token, _tokenAmount, _ethAmount);
        
        // Store mappings
        ds.tokenToPool[_token] = pool;
        ds.tokenToPositionId[_token] = positionId;
        ds.tokenGraduated[_token] = true;
        
        emit LibDEX.PoolCreated(_token, pool);
        emit LibDEX.PositionCreated(_token, positionId);
        emit LibDEX.TokenGraduated(_token, pool, positionId);
    }

    /// @notice Collect accrued Uniswap V3 fees and auto-distribute to creator/platform
    /// @dev Anyone can call this - fees are automatically split and credited
    /// @param _token Token address
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(address _token) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        LibDEX.Layout storage ds = LibDEX.layout();
        
        require(ds.tokenGraduated[_token], "Token not graduated");
        
        uint256 positionId = ds.tokenToPositionId[_token];
        require(positionId > 0, "No position found");
        
        (amount0, amount1) = INonfungiblePositionManager(ds.nonfungiblePositionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        
        address pool = ds.tokenToPool[_token];
        address token0 = IUniswapV3Pool(pool).token0();
        uint256 wethAmount = (token0 == ds.weth) ? amount0 : amount1;
        
        if (wethAmount > 0) {
            // Unwrap WETH to ETH
            IWETH(ds.weth).withdraw(wethAmount);
            
            // Auto-distribute fees using DEX fee config
            _distributeDEXFees(_token, wethAmount);
        }
        
        emit LibDEX.FeesCollected(_token, amount0, amount1);
    }
    
    /// @notice Internal function to distribute DEX fees to creator and platform
    /// @param _token Token address
    /// @param _ethAmount Total ETH fees to distribute
    function _distributeDEXFees(address _token, uint256 _ethAmount) internal {
        LibFee.Layout storage fs = LibFee.layout();
        
        // Get creator address
        address creator = _getTokenCreator(_token);
        
        // Get DEX fee config (token-specific or global)
        LibFee.DEXFeeConfig memory config = fs.tokenHasCustomDEXFees[_token] 
            ? fs.tokenDEXFeeConfigs[_token] 
            : fs.globalDEXFeeConfig;
        
        // Calculate fee breakdown
        uint256 platformFee = (_ethAmount * config.platformFeePercentage) / 100;
        uint256 creatorFee = (_ethAmount * config.creatorFeePercentage) / 100;
        uint256 badBunnzFee = (_ethAmount * config.badBunnzFeePercentage) / 100;
        uint256 buybackFee = _ethAmount - platformFee - creatorFee - badBunnzFee;
        
        // Credit fees to storage (claimable later)
        fs.totalPlatformFees += platformFee;
        fs.totalBadBunnzFees += badBunnzFee;
        fs.totalBuybackFees += buybackFee;
        
        // Credit creator rewards directly (they can claim anytime)
        if (creator != address(0) && creatorFee > 0) {
            fs.creatorRewards[creator] += creatorFee;
            fs.totalCreatorFees += creatorFee;
        }
        
        emit LibFee.FeesDistributed(_token, creator, platformFee, creatorFee, badBunnzFee, buybackFee);
    }

    /// @notice Create or fetch an existing pool for a token/WETH pair, initializing price if needed
    /// @param _token Token address
    /// @param _tokenAmount Token amount used for initial price calculation
    /// @param _ethAmount ETH amount used for initial price calculation
    /// @return pool Uniswap V3 pool address
    function _createOrGetPool(address _token, uint256 _tokenAmount, uint256 _ethAmount) internal returns (address pool) {
        LibDEX.Layout storage ds = LibDEX.layout();
        
        pool = IUniswapV3Factory(ds.uniswapV3Factory).getPool(_token, ds.weth, LibDEX.POOL_FEE);
        if (pool == address(0)) {
            pool = IUniswapV3Factory(ds.uniswapV3Factory).createPool(_token, ds.weth, LibDEX.POOL_FEE);
            
            require(_tokenAmount > 0 && _ethAmount > 0, "Invalid amounts for price calculation");
            
            uint160 sqrtPriceX96;
            if (_token < ds.weth) {
                sqrtPriceX96 = LibDEX.calculateSqrtPriceX96(_ethAmount, _tokenAmount);
            } else {
                sqrtPriceX96 = LibDEX.calculateSqrtPriceX96(_tokenAmount, _ethAmount);
            }
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }
    }

    /// @notice Create a full-range Uniswap V3 liquidity position for a token/WETH pair
    /// @param _token Token address
    /// @param _tokenAmount Token amount to deposit
    /// @param _wethAmount WETH amount to deposit
    /// @return positionId NFT position ID
    function _createLiquidityPosition(
        address _token,
        uint256 _tokenAmount,
        uint256 _wethAmount
    ) internal returns (uint256 positionId) {
        LibDEX.Layout storage ds = LibDEX.layout();
        
        (address token0, address token1) = _token < ds.weth ? (_token, ds.weth) : (ds.weth, _token);
        (uint256 amount0Desired, uint256 amount1Desired) = _token < ds.weth 
            ? (_tokenAmount, _wethAmount) 
            : (_wethAmount, _tokenAmount);

        // Full range position (divisible by tick spacing of 60 for 0.3% fee tier)
        int24 tickLower = -887220;
        int24 tickUpper = 887220;

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: LibDEX.POOL_FEE,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 300
        });

        (positionId, , , ) = INonfungiblePositionManager(ds.nonfungiblePositionManager).mint(params);
    }

    /// @notice Attempt to read the creator from the token contract, ignoring failures
    /// @param _token Token address
    /// @return Creator address or zero address if unavailable
    function _getTokenCreator(address _token) internal view returns (address) {
        try IMemecoinToken(_token).creator() returns (address creator) {
            return creator;
        } catch {
            return address(0);
        }
    }

    /// @notice Get position details for a graduated token's liquidity position
    /// @param _token Token address
    /// @return positionId NFT position ID
    /// @return liquidity Current position liquidity
    /// @return tokensOwed0 Uncollected token0 fees
    /// @return tokensOwed1 Uncollected token1 fees
    function getPositionDetails(address _token) external view returns (
        uint256 positionId,
        uint128 liquidity,
        uint256 tokensOwed0,
        uint256 tokensOwed1
    ) {
        LibDEX.Layout storage ds = LibDEX.layout();
        positionId = ds.tokenToPositionId[_token];
        require(positionId > 0, "No position found");
        
        (, , , , , , , uint128 _liquidity, , , uint128 _tokensOwed0, uint128 _tokensOwed1) = 
            INonfungiblePositionManager(ds.nonfungiblePositionManager).positions(positionId);
        
        liquidity = _liquidity;
        tokensOwed0 = _tokensOwed0;
        tokensOwed1 = _tokensOwed1;
    }

    /// @notice Get the Uniswap V3 pool address for a token
    /// @param _token Token address
    /// @return Pool address or zero if not graduated
    function getPoolAddress(address _token) external view returns (address) {
        return LibDEX.layout().tokenToPool[_token];
    }

    /// @notice Check if a token has been graduated to a DEX pool
    /// @param _token Token address
    /// @return True if graduated
    function isTokenGraduated(address _token) external view returns (bool) {
        return LibDEX.layout().tokenGraduated[_token];
    }

    /// @notice Get consolidated graduation status and liquidity data for a token
    /// @param _token Token address
    /// @return graduated True if graduated
    /// @return pool Pool address
    /// @return positionId NFT position ID
    /// @return liquidity Current liquidity
    function getGraduationStatus(address _token) external view returns (
        bool graduated,
        address pool,
        uint256 positionId,
        uint128 liquidity
    ) {
        LibDEX.Layout storage ds = LibDEX.layout();
        graduated = ds.tokenGraduated[_token];
        pool = ds.tokenToPool[_token];
        positionId = ds.tokenToPositionId[_token];
        
        if (graduated && positionId > 0) {
            (, , , , , , , liquidity, , , , ) = 
                INonfungiblePositionManager(ds.nonfungiblePositionManager).positions(positionId);
        }
    }

    /// @notice Set core DEX contract addresses
    /// @param _uniswapV3Factory Uniswap V3 factory address
    /// @param _nonfungiblePositionManager Position manager address
    /// @param _weth WETH token address
    function setDEXAddresses(
        address _uniswapV3Factory,
        address _nonfungiblePositionManager,
        address _weth
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibDEX.Layout storage ds = LibDEX.layout();
        ds.uniswapV3Factory = _uniswapV3Factory;
        ds.nonfungiblePositionManager = _nonfungiblePositionManager;
        ds.weth = _weth;
    }

    /// @notice Recover arbitrary ERC-20 tokens from this facet
    /// @param _token Token address
    /// @param _amount Amount to recover
    function recoverToken(address _token, uint256 _amount) external {
        LibDiamond.enforceIsContractOwner();
        IERC20(_token).transfer(msg.sender, _amount);
    }

    /// @notice Recover all ETH held by this facet
    function recoverETH() external {
        LibDiamond.enforceIsContractOwner();
        (bool success, ) = payable(msg.sender).call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    /// @notice Allow the facet to receive ETH (e.g. from Uniswap)
    receive() external payable {}
}

/// @title IWETH
/// @notice Minimal WETH interface for deposit/withdraw
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title IUniswapV3Factory
/// @notice Minimal Uniswap V3 factory interface
interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @title IUniswapV3Pool
/// @notice Minimal Uniswap V3 pool interface
interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title INonfungiblePositionManager
/// @notice Minimal Uniswap V3 position manager interface
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    
    function mint(MintParams calldata params) external payable returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    
    function positions(uint256 tokenId) external view returns (
        uint96 nonce,
        address operator,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );
    
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

/// @title IMemecoinToken
/// @notice Minimal interface used for reading token creator
interface IMemecoinToken {
    function creator() external view returns (address);
}
