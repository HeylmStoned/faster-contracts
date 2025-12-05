// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDiamondLoupe
/// @notice EIP-2535 loupe interface for introspecting diamond facets and selectors
interface IDiamondLoupe {
    /// @notice Facet description with address and exported selectors
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Get all facet addresses and their four-byte function selectors
    /// @return facets_ Array of facet descriptors
    function facets() external view returns (Facet[] memory facets_);

    /// @notice Get all function selectors supported by a specific facet
    /// @param _facet Facet address
    /// @return facetFunctionSelectors_ List of selectors provided by the facet
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);

    /// @notice Get all facet addresses used by a diamond
    /// @return facetAddresses_ Array of facet addresses
    function facetAddresses() external view returns (address[] memory facetAddresses_);

    /// @notice Get the facet that supports a given selector
    /// @param _functionSelector Function selector to query
    /// @return facetAddress_ Address of the facet implementing the selector
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}
