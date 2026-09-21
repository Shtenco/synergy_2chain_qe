// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Unit-safe arithmetic for executable arbitrage P&L.
/// @dev Every result is expressed in raw canonical USDC units.
///      This contract never treats an oracle spread as profit.
contract ProfitabilityEstimatorV2 {
    struct Estimate {
        uint256 grossProceeds;
        uint256 tradeCost;
        uint256 gasCost;
        uint256 mevBuffer;
        int256 netProfit;
        bool profitable;
    }

    function externalBuyInternalSell(
        uint256 externalCostUSDC,
        uint256 internalUSDSOut18,
        uint256 usdcScale,
        uint256 gasCostUSDC,
        uint256 mevBufferUSDC,
        uint256 minNetProfitUSDC
    ) external pure returns (Estimate memory e) {
        require(usdcScale != 0, "scale=0");
        uint256 redemption = internalUSDSOut18 / usdcScale;
        e = _build(
            redemption,
            externalCostUSDC,
            gasCostUSDC,
            mevBufferUSDC,
            minNetProfitUSDC
        );
    }

    function internalBuyExternalSell(
        uint256 inputUSDC,
        uint256 externalUSDCOut,
        uint256 gasCostUSDC,
        uint256 mevBufferUSDC,
        uint256 minNetProfitUSDC
    ) external pure returns (Estimate memory e) {
        e = _build(
            externalUSDCOut,
            inputUSDC,
            gasCostUSDC,
            mevBufferUSDC,
            minNetProfitUSDC
        );
    }

    function _build(
        uint256 proceeds,
        uint256 cost,
        uint256 gasCost,
        uint256 mevBuffer,
        uint256 minNet
    ) internal pure returns (Estimate memory e) {
        uint256 totalCost = cost + gasCost + mevBuffer;
        int256 net = int256(proceeds) - int256(totalCost);
        e = Estimate({
            grossProceeds: proceeds,
            tradeCost: cost,
            gasCost: gasCost,
            mevBuffer: mevBuffer,
            netProfit: net,
            profitable: net >= int256(minNet)
        });
    }
}
