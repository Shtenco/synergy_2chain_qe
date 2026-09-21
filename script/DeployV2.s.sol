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

        (USDSV2 usds, ETHSV2 eths, ChainlinkExternalOracleV2 oracle) = _deployBase(chainlinkEthUsd, oracleMaxAge);
        _deployRest(usdc, weth, uniPool, bot, deployer, address(usds), address(eths), address(oracle));

        vm.stopBroadcast();

        console.log("=== HARDNAV V2 ===");
        console.log("USDSV2", address(usds));
        console.log("ETHSV2", address(eths));
        console.log("Oracle", address(oracle));
    }

    function _deployBase(address chainlinkEthUsd, uint256 oracleMaxAge)
        internal
        returns (USDSV2 usds, ETHSV2 eths, ChainlinkExternalOracleV2 oracle)
    {
        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new ChainlinkExternalOracleV2(chainlinkEthUsd, oracleMaxAge);
    }

    function _deployRest(
        address usdc,
        address weth,
        address uniPool,
        address bot,
        address deployer,
        address usds,
        address eths,
        address oracle
    ) internal {
        BridgeCoreV2 bridge = new BridgeCoreV2(usds, eths, usdc, oracle);

        USDSV2(usds).grantRole(USDSV2(usds).BRIDGE_ROLE(), address(bridge));
        ETHSV2(eths).grantRole(ETHSV2(eths).BRIDGE_ROLE(), address(bridge));
        USDSV2(usds).renounceRole(USDSV2(usds).DEFAULT_ADMIN_ROLE(), deployer);
        ETHSV2(eths).renounceRole(ETHSV2(eths).DEFAULT_ADMIN_ROLE(), deployer);

        _deployVenueStack(usdc, weth, uniPool, bot, deployer, usds, eths, oracle, address(bridge));

        console.log("BridgeCoreV2", address(bridge));
    }

    function _deployVenueStack(
        address usdc,
        address weth,
        address uniPool,
        address bot,
        address deployer,
        address usds,
        address eths,
        address oracle,
        address bridge
    ) internal {
        InternalAMMV2 amm = new InternalAMMV2(usds, eths, oracle);
        UniswapV3VenueV2 venue = new UniswapV3VenueV2(uniPool, usdc, weth);
        ArbitrageExecutorV2 executor = new ArbitrageExecutorV2(
            bridge, address(amm), address(venue),
            usdc, weth, usds, eths
        );

        BridgeCoreV2(payable(bridge)).grantRole(BridgeCoreV2(payable(bridge)).OPERATOR_ROLE(), address(executor));
        executor.grantRole(executor.BOT_ROLE(), bot);
        executor.revokeRole(executor.BOT_ROLE(), deployer);

        _deployAccounting(usdc, weth, usds, eths, oracle, bridge, address(amm), address(venue), address(executor));

        console.log("InternalAMMV2", address(amm));
        console.log("UniswapV3VenueV2", address(venue));
        console.log("ArbitrageExecutorV2", address(executor));
    }

    function _deployAccounting(
        address usdc,
        address weth,
        address usds,
        address eths,
        address oracle,
        address bridge,
        address amm,
        address venue,
        address executor
    ) internal {
        address[] memory tracked = new address[](3);
        tracked[0] = executor;
        tracked[1] = amm;
        tracked[2] = venue;

        EconomicLedgerV2 ledger = new EconomicLedgerV2(
            usdc, weth, usds, eths, oracle, bridge, tracked
        );
        OPGasCostModelV2 gasModel = new OPGasCostModelV2(oracle);
        ProfitabilityEstimatorV2 estimator = new ProfitabilityEstimatorV2();

        console.log("EconomicLedgerV2", address(ledger));
        console.log("OPGasCostModelV2", address(gasModel));
        console.log("ProfitabilityEstimatorV2", address(estimator));
    }
}
