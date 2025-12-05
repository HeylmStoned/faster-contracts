// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibToken} from "../libraries/LibToken.sol";
import {LibTrading} from "../libraries/LibTrading.sol";
import {LibFee} from "../libraries/LibFee.sol";
import {LibDEX} from "../libraries/LibDEX.sol";

/**
 * @title AdminFacet
 * @notice Owner and administrative functions for the Diamond
 * @dev Handles ownership, fee wallets, and emergency utilities
 */
contract AdminFacet {
    /// @notice Return the current diamond owner
    /// @return Address of the owner
    function owner() external view returns (address) {
        return LibDiamond.contractOwner();
    }

    /// @notice Transfer ownership of the diamond to a new address
    /// @param _newOwner Address of the new owner
    function transferOwnership(address _newOwner) external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    /// @notice Set platform and buyback fee wallets
    /// @param _platformWallet Address that receives platform fees
    /// @param _buybackWallet Address that receives buyback fees
    function setFeeWallets(address _platformWallet, address _buybackWallet) external {
        LibDiamond.enforceIsContractOwner();
        LibFee.Layout storage fs = LibFee.layout();
        fs.platformWallet = _platformWallet;
        fs.buybackWallet = _buybackWallet;
        emit LibFee.FeeWalletsUpdated(_platformWallet, _buybackWallet);
    }

    /// @notice Configure default creator/platform/buyback fee shares
    /// @param _creatorFee Creator fee share in basis points
    /// @param _platformFee Platform fee share in basis points
    /// @param _buybackFee Buyback fee share in basis points
    function setDefaultFees(uint256 _creatorFee, uint256 _platformFee, uint256 _buybackFee) external {
        LibDiamond.enforceIsContractOwner();
        require(_creatorFee + _platformFee + _buybackFee <= 10000, "Fees exceed 100%");
        LibFee.Layout storage fs = LibFee.layout();
        fs.defaultCreatorFee = _creatorFee;
        fs.defaultPlatformFee = _platformFee;
        fs.defaultBuybackFee = _buybackFee;
    }

    /// @notice Get the current platform and buyback fee wallets
    /// @return platformWallet Address receiving platform fees
    /// @return buybackWallet Address receiving buyback fees
    function getFeeWallets() external view returns (address platformWallet, address buybackWallet) {
        LibFee.Layout storage fs = LibFee.layout();
        return (fs.platformWallet, fs.buybackWallet);
    }

    /// @notice Get the current default fee configuration
    /// @return creatorFee Creator fee share in basis points
    /// @return platformFee Platform fee share in basis points
    /// @return buybackFee Buyback fee share in basis points
    function getDefaultFees() external view returns (uint256 creatorFee, uint256 platformFee, uint256 buybackFee) {
        LibFee.Layout storage fs = LibFee.layout();
        return (fs.defaultCreatorFee, fs.defaultPlatformFee, fs.defaultBuybackFee);
    }

    /// @notice Get aggregated platform-level fee statistics
    /// @return platformFees Total platform fees accrued
    /// @return badBunnzFees Total Bad Bunnz fees accrued
    /// @return buybackFees Total buyback fees accrued
    /// @return graduationFees Total graduation fees accrued
    /// @return creatorFees Total creator fees accrued
    function getAccumulatedFees() external view returns (
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

    /// @notice Placeholder for global pause hook
    /// @dev Currently only enforces owner access; no global flag stored
    function pause() external {
        LibDiamond.enforceIsContractOwner();
    }

    /// @notice Placeholder for global unpause hook
    /// @dev Currently only enforces owner access; no global flag stored
    function unpause() external {
        LibDiamond.enforceIsContractOwner();
    }

    /// @notice Withdraw arbitrary ETH or ERC-20 tokens from the diamond
    /// @dev Restricted to the diamond owner; for last-resort recovery only
    /// @param token Token address or zero address for ETH
    /// @param amount Amount to withdraw
    function emergencyWithdraw(address token, uint256 amount) external {
        LibDiamond.enforceIsContractOwner();
        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }
    }
}

/// @title IERC20
/// @notice Minimal ERC-20 interface used for emergency withdrawals
interface IERC20 {
    /// @notice Transfer tokens to `to`
    /// @param to Recipient address
    /// @param amount Amount of tokens to transfer
    function transfer(address to, uint256 amount) external returns (bool);
}
