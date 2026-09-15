// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/ArbitrageExecutor.sol";

/**
 * @title Deploy - Deployment script for Perpetual Arbitrage Engine
 * @dev Deploy all contracts and configure roles
 * 
 * Usage:
 * forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying from:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy synthetic tokens
        USDS usds = new USDS();
        console.log("USDS deployed at:", address(usds));
        
        ETHS eths = new ETHS();
        console.log("ETHS deployed at:", address(eths));
        
        // 2. Deploy oracle
        uint256 initialEthPrice = 2500e6; // $2500 in USDC (6 decimals)
        ManagedOracle oracle = new ManagedOracle(initialEthPrice);
        console.log("ManagedOracle deployed at:", address(oracle));
        
        // 3. Deploy Bridge
        address canonicalUSDC = vm.envAddress("USDC_ADDRESS");
        BridgeCore bridge = new BridgeCore(
            address(usds),
            address(eths),
            canonicalUSDC,
            address(oracle)
        );
        console.log("BridgeCore deployed at:", address(bridge));
        
        // 4. Deploy Internal AMM
        InternalAMM amm = new InternalAMM(
            address(usds),
            address(eths),
            address(oracle)
        );
        console.log("InternalAMM deployed at:", address(amm));
        
        // 5. Deploy Treasury
        address ownerWallet = vm.envAddress("OWNER_WALLET");
        address bridgeReserve = vm.envAddress("BRIDGE_RESERVE");
        address insuranceFund = vm.envAddress("INSURANCE_FUND");
        address rebaseFund = vm.envAddress("REBASE_FUND");
        
        TreasuryDistributor treasury = new TreasuryDistributor(
            canonicalUSDC,
            ownerWallet,
            bridgeReserve,
            insuranceFund,
            rebaseFund
        );
        console.log("TreasuryDistributor deployed at:", address(treasury));
        
        // 6. Deploy Arbitrage Executor
        ArbitrageExecutor executor = new ArbitrageExecutor(
            address(bridge),
            address(amm),
            address(treasury),
            address(oracle),
            canonicalUSDC,
            vm.envAddress("WETH_ADDRESS"),
            address(usds),
            address(eths)
        );
        console.log("ArbitrageExecutor deployed at:", address(executor));
        
        // 7. Configure roles
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address bot = vm.envAddress("BOT_ADDRESS");
        
        // Bridge roles
        bridge.grantRole(bridge.OPERATOR_ROLE(), operator);
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(executor));
        
        // Token roles
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        
        // AMM roles
        amm.grantRole(amm.REBASE_ROLE(), deployer); // Can be transferred to executor
        
        // Executor roles
        executor.grantRole(executor.BOT_ROLE(), bot);
        
        console.log("Roles configured");
        
        vm.stopBroadcast();
        
        console.log("Deployment complete!");
        console.log("---");
        console.log("USDS:", address(usds));
        console.log("ETHS:", address(eths));
        console.log("Oracle:", address(oracle));
        console.log("Bridge:", address(bridge));
        console.log("AMM:", address(amm));
        console.log("Treasury:", address(treasury));
        console.log("Executor:", address(executor));
    }
}
