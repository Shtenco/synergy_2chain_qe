// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IManagedOracle - Interface for the managed oracle system
 */
interface IManagedOracle {
    function getETHPrice() external view returns (uint256);
    function getExternalPrice() external view returns (uint256);
    function getInternalPrice() external view returns (uint256);
    function getGradient() external view returns (int256);
    function getMode() external view returns (uint8); // 0=UNDERPRICE, 1=OVERPRICE, 2=NEUTRAL
    function isStale(uint256 maxAge) external view returns (bool);
}
