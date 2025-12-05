// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDiamondCut
/// @notice EIP-2535 interface for managing diamond facets and selectors
interface IDiamondCut {
    /// @notice Action to perform for a facet cut
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    /// @notice Description of a single facet cut operation
    /// @param facetAddress Address of the facet being added/replaced/removed
    /// @param action Type of operation to perform
    /// @param functionSelectors List of function selectors affected by this cut
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Add, replace, or remove any number of functions and optionally execute a call
    /// @param _diamondCut Array of facet cut operations to perform
    /// @param _init Address of a contract to execute `_calldata` with delegatecall
    /// @param _calldata Encoded function call to execute after the cut
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external;

    /// @notice Emitted when a diamond cut is performed
    /// @param _diamondCut Array of facet cut operations executed
    /// @param _init Address used for initialization delegatecall
    /// @param _calldata Data passed to the initialization call
    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}
