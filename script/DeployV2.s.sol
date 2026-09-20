// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/v2/SyntheticTokensV2.sol";
import "../contracts/v2/ChainlinkExternalOracleV2.sol";
import "../contracts/v2/BridgeCoreV2.sol";
import "../contracts/v2/InternalAMMV2.sol";
import "../contracts/v2/UniswapV3VenueV2.sol";
import "../contracts/v2/ArbitrageExecutorV2.sol";
import "../contracts/v2/EconomicLedgerV2.sol";
import "../contracts/v2/OPGasCostModelV2.sol";
import "../contracts/v2/ProfitabilityEstimatorV2.sol";

contract DeployV2 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address chainlinkEthUsd = vm.envAddress("CHAINLINK_ETH_USD_FEED");
        address uniPool = vm.envAddress("UNISWAP_V3_USDC_WETH_POOL");
        address bot = vm.envAddress("BOT_ADDRESS");
        uint256 oracleMaxAge = vm.envOr("ORACLE_MAX_AGE", uint256(1 hours));

        vm.startBroadcast(pk);

        USDSV2 usds = new USDSV2();
        ETHSV2 eths = new ETHSV2();
        ChainlinkExternalOracleV2 oracle =
            new ChainlinkExternalOracleV2(chainlinkEthUsd, oracleMaxAge);
        BridgeCoreV2 bridge =
            new BridgeCoreV2(address(usds), address(eths), usdc, address(oracle));

        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        usds.renounceRole(usds.DEFAULT_ADMIN_ROLE(), deployer);
        eths.renounceRole(eths.DEFAULT_ADMIN_ROLE(), deployer);

        InternalAMMV2 amm =
            new InternalAMMV2(address(usds), address(eths), address(oracle));
        UniswapV3VenueV2 venue = new UniswapV3VenueV2(uniPool, usdc, weth);
        ArbitrageExecutorV2 executor = new ArbitrageExecutorV2(
            address(bridge), address(amm), address(venue),
            usdc, weth, address(usds), address(eths)
        );

        bridge.grantRole(bridge.OPERATOR_ROLE(), address(executor));
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.revokeRole(executor.BOT_ROLE(), deployer);

        address[] memory tracked = new address[](3);
        tracked[0] = address(executor);
        tracked[1] = address(amm);
        tracked[2] = address(venue);

        EconomicLedgerV2 ledger = new EconomicLedgerV2(
            usdc, weth, address(usds), address(eths),
            address(oracle), address(bridge), tracked
        );
        OPGasCostModelV2 gasModel = new OPGasCostModelV2(address(oracle));
        ProfitabilityEstimatorV2 estimator = new ProfitabilityEstimatorV2();

        vm.stopBroadcast();

        console.log("=== HARDNAV V2 ===");
        console.log("USDSV2", address(usds));
        console.log("ETHSV2", address(eths));
        console.log("Oracle", address(oracle));
        console.log("BridgeCoreV2", address(bridge));
        console.log("InternalAMMV2", address(amm));
        console.log("UniswapV3VenueV2", address(venue));
        console.log("ArbitrageExecutorV2", address(executor));
        console.log("EconomicLedgerV2", address(ledger));
        console.log("OPGasCostModelV2", address(gasModel));
        console.log("ProfitabilityEstimatorV2", address(estimator));
    }
}
