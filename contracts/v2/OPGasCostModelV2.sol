// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IExternalPriceOracleV2.sol";

interface IOPGasPriceOracleV2 {
    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256);
    function getOperatorFee(uint256 gasUsed) external view returns (uint256);
}

/// @notice Conservative OP-stack fee estimator.
/// @dev Uses the write-path L1 upper bound plus the chain's operator-fee getter.
///      ETH/USD comes from the external oracle, never from a V3 pool balance ratio.
contract OPGasCostModelV2 {
    address public constant GAS_PRICE_ORACLE =
        0x420000000000000000000000000000000000000F;

    IExternalPriceOracleV2 public immutable ethUsdOracle;

    constructor(address _ethUsdOracle) {
        require(_ethUsdOracle != address(0), "oracle=0");
        ethUsdOracle = IExternalPriceOracleV2(_ethUsdOracle);
    }

    function estimateFeeWei(
        uint256 gasUsed,
        uint256 maxFeePerGas,
        uint256 unsignedTxSize
    ) public view returns (uint256) {
        uint256 l2Execution = gasUsed * maxFeePerGas;
        uint256 l1Data =
            IOPGasPriceOracleV2(GAS_PRICE_ORACLE).getL1FeeUpperBound(unsignedTxSize);

        uint256 operatorFee;
        // getOperatorFee exists on Isthmus+ chains. Treat a missing method as zero
        // so the estimator remains usable on earlier fork blocks.
        try IOPGasPriceOracleV2(GAS_PRICE_ORACLE).getOperatorFee(gasUsed)
            returns (uint256 fee)
        {
            operatorFee = fee;
        } catch {
            operatorFee = 0;
        }

        return l2Execution + l1Data + operatorFee;
    }

    function estimateFeeUSDC6(
        uint256 gasUsed,
        uint256 maxFeePerGas,
        uint256 unsignedTxSize
    ) external view returns (uint256) {
        uint256 weiCost = estimateFeeWei(gasUsed, maxFeePerGas, unsignedTxSize);
        uint256 ethUsd6 = ethUsdOracle.getPrice6d();
        return (weiCost * ethUsd6) / 1e18;
    }
}
