// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibToken} from "../libraries/LibToken.sol";
import {LibFee} from "../libraries/LibFee.sol";
import {LibDEX} from "../libraries/LibDEX.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title DiamondInit
 * @notice Initialization contract for configuring core diamond state
 * @dev Called once via delegatecall from the diamond during deployment or upgrade
 */
contract DiamondInit {
    /// @notice Initialization parameters for core fee, DEX and wrapper config
    struct InitParams {
        address platformWallet;
        address buybackWallet;
        uint256 defaultCreatorFee;
        uint256 defaultPlatformFee;
        uint256 defaultBuybackFee;
        address uniswapV3Factory;
        address nonfungiblePositionManager;
        address weth;
        address wrapperFactory;
    }

    /// @notice Initialize core fee, DEX, token and interface support configuration
    /// @param params Packed initialization parameters
    function init(InitParams calldata params) external {
        LibFee.Layout storage fs = LibFee.layout();
        fs.platformWallet = params.platformWallet;
        fs.buybackWallet = params.buybackWallet;
        fs.defaultCreatorFee = params.defaultCreatorFee;
        fs.defaultPlatformFee = params.defaultPlatformFee;
        fs.defaultBuybackFee = params.defaultBuybackFee;
        fs.globalDEXFeeConfig = LibFee.DEXFeeConfig({
            platformFeePercentage: 30,
            creatorFeePercentage: 50,
            badBunnzFeePercentage: 10,
            buybackFeePercentage: 10
        });

        LibDEX.Layout storage ds = LibDEX.layout();
        ds.uniswapV3Factory = params.uniswapV3Factory;
        ds.nonfungiblePositionManager = params.nonfungiblePositionManager;
        ds.weth = params.weth;

        LibToken.Layout storage tokenStorage = LibToken.layout();
        tokenStorage.wrapperFactory = params.wrapperFactory;

        LibDiamond.DiamondStorage storage diamondStorage = LibDiamond.diamondStorage();
        diamondStorage.supportedInterfaces[type(IERC165).interfaceId] = true;
        diamondStorage.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        diamondStorage.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
    }
}
