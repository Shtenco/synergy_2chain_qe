// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExternalPriceOracleV2 {
    /// @notice ETH price in canonical USD units with 6 decimals.
    function getPrice6d() external view returns (uint256);

    /// @notice True when the underlying source is older than its configured freshness limit.
    function isStale() external view returns (bool);

    function updatedAt() external view returns (uint256);
}
