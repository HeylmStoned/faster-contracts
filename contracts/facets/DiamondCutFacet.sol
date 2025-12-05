// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/**
 * @title DiamondCutFacet
 * @notice Handles adding, replacing, and removing facets
 * @dev Implements EIP-2535 Diamond Cut functionality
 */
contract DiamondCutFacet is IDiamondCut {
    /// @notice Add, replace, or remove functions and optionally execute initialization logic
    /// @param _diamondCut Array of facet cut operations to perform
    /// @param _init Address of the contract or facet to execute `_calldata`
    /// @param _calldata Initialization call data, including selector and arguments
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}
