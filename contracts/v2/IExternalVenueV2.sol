// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExternalVenueV2 {
    function buyWETHExactUSDC(
        uint256 usdcIn,
        uint256 minWethOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 wethOut);

    function sellWETHExactInput(
        uint256 wethIn,
        uint256 minUsdcOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 usdcOut);
}
