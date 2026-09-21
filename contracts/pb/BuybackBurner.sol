// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BridgePool.sol";
import "../v2/SyntheticTokensV2.sol";

/// @notice Earnings-funded buyback-and-burn. NO mint power is used here:
///      this contract only ever burns (BRIDGE_ROLE technically includes mint,
///      but no code path calls it). Funded from OUTSIDE value (harvest profit),
///      never from printing. Anti-QE: value in from donor, supply out to fire.
contract BuybackBurner {
    using SafeERC20 for IERC20;

    BridgePool public immutable poolA; // USDS/USDC
    USDSV2 public immutable usds;
    IERC20 public immutable usdc;

    event BuybackBurned(address indexed from, uint256 usdcIn, uint256 usdsBurned);

    error ZeroAmount();

    constructor(address _poolA, address _usds, address _usdc) {
        require(_poolA != address(0) && _usds != address(0) && _usdc != address(0), "zero");
        poolA = BridgePool(_poolA);
        usds = USDSV2(_usds);
        usdc = IERC20(_usdc);
    }

    function buyAndBurn(uint256 usdcIn, uint256 minUsdsOut) external returns (uint256 burned) {
        if (usdcIn == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        usdc.safeApprove(address(poolA), usdcIn);
        burned = poolA.swap(usdcIn, false, minUsdsOut); // USDC -> USDS
        usds.bridgeBurn(address(this), burned);
        emit BuybackBurned(msg.sender, usdcIn, burned);
    }
}
