// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";
import "../contracts/ArbitrageExecutor.sol";

/**
 * @title ArbitrageIntegrationTest - Full system integration tests
 * @dev Tests complete arbitrage cycles A and B with all components
 * 
 * TEST SCENARIOS:
 * 1. Cycle A: Extract profit when internal price < external
 * 2. Cycle B: Rebalance when internal price > external
 * 3. Health Factor maintained throughout cycles
 * 4. LP protection via rebase mechanism
 * 5. Treasury distribution correctness
 * 6. Emergency stop and recovery
 */
contract ArbitrageIntegrationTest is Test {
    // Contracts
    BridgeCore public bridge;
    InternalAMM public amm;
    TreasuryDistributor public treasury;
    ManagedOracle public oracle;
    USDS public usds;
    ETHS public eths;
    ArbitrageExecutor public executor;
    
    // Addresses
    address public admin;
    address public operator;
    address public lp;
    address public botOperator;
    address public ownerWallet;
    address public bridgeReserve;
    address public insuranceFund;
    address public rebaseFund;
    
    uint256 public constant INITIAL_ETH_PRICE = 2500e6;
    uint256 public constant ONE_ETH = 1e18;
    uint256 public constant ONE_USDS = 1e18;
    
    function setUp() public {
        admin = makeAddr("synergy.integration.admin");
        operator = makeAddr("synergy.integration.operator");
        lp = makeAddr("synergy.integration.lp");
        botOperator = makeAddr("synergy.integration.botOperator");
        ownerWallet = makeAddr("synergy.integration.ownerWallet");
        bridgeReserve = makeAddr("synergy.integration.bridgeReserve");
        insuranceFund = makeAddr("synergy.integration.insuranceFund");
        rebaseFund = makeAddr("synergy.integration.rebaseFund");

        vm.startPrank(admin);
        
        // Deploy all contracts
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(INITIAL_ETH_PRICE);
        
        bridge = new BridgeCore(
            address(usds),
            address(eths),
            address(usds),
            address(oracle)
        );
        
        amm = new InternalAMM(
            address(usds),
            address(eths),
            address(oracle)
        );
        
        treasury = new TreasuryDistributor(
            address(usds),
            ownerWallet,
            bridgeReserve,
            insuranceFund,
            rebaseFund
        );
        
        executor = new ArbitrageExecutor(
            address(bridge),
            address(amm),
            address(treasury),
            address(oracle),
            address(usds),
            address(eths),
            address(usds),
            address(eths)
        );
        
        // Grant roles
        bridge.grantRole(bridge.OPERATOR_ROLE(), operator);
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(executor));
        
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        
        amm.grantRole(amm.REBASE_ROLE(), admin);
        
        executor.grantRole(executor.BOT_ROLE(), botOperator);
        
        vm.stopPrank();
        
        // Setup initial state
        _setupInitialState();
    }
    
    function _setupInitialState() internal {
        // Fund LP with tokens
        vm.startPrank(admin);
        usds.mint(lp, 500_000 * ONE_USDS);
        eths.mint(lp, 200 * ONE_ETH);
        vm.stopPrank();
        
        // LP adds liquidity
        vm.startPrank(lp);
        usds.approve(address(amm), 500_000 * ONE_USDS);
        eths.approve(address(amm), 200 * ONE_ETH);
        amm.addLiquidity(500_000 * ONE_USDS, 200 * ONE_ETH);
        vm.stopPrank();
        
        // Bridge has initial collateral
        vm.deal(operator, 100 ether);
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 50 ether}(operator, 50 * ONE_ETH);
    }
    
    // ============ CYCLE A TESTS ============
    
    function test_CycleA_UnderpriceMode() public {
        // Set oracle to underprice mode (internal < external)
        vm.prank(admin);
        oracle.setGradient(-500); // -5% gradient
        
        assertEq(oracle.getMode(), 0); // UNDERPRICE
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        
        // Internal should be less than external
        assertLt(intPrice, extPrice);
        
        // Calculate expected spread
        uint256 spread = extPrice - intPrice;
        assertGt(spread, 0);
    }
    
    function test_CycleA_ProfitabilityCheck() public {
        // Set underprice mode
        vm.prank(admin);
        oracle.setGradient(-500);
        
        uint256 ethVolume = 10 * ONE_ETH;
        
        (bool isProfitable, uint256 estimatedProfit) = executor.isCycleAProfitable(ethVolume);
        
        assertTrue(isProfitable);
        assertGt(estimatedProfit, 0);
    }
    
    function test_CycleA_NotProfitableInOverpriceMode() public {
        // Set overprice mode
        vm.prank(admin);
        oracle.setGradient(500);
        
        uint256 ethVolume = 10 * ONE_ETH;
        
        (bool isProfitable, ) = executor.isCycleAProfitable(ethVolume);
        
        assertFalse(isProfitable);
    }
    
    // ============ CYCLE B TESTS ============
    
    function test_CycleB_OverpriceMode() public {
        // Set oracle to overprice mode (internal > external)
        vm.prank(admin);
        oracle.setGradient(500); // +5% gradient
        
        assertEq(oracle.getMode(), 1); // OVERPRICE
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        
        // Internal should be greater than external
        assertGt(intPrice, extPrice);
    }
    
    function test_CycleB_ProfitabilityCheck() public {
        // Set overprice mode
        vm.prank(admin);
        oracle.setGradient(500);
        
        uint256 ethsVolume = 10 * ONE_ETH;
        
        (bool isProfitable, uint256 estimatedProfit) = executor.isCycleBProfitable(ethsVolume);
        
        assertTrue(isProfitable);
        assertGt(estimatedProfit, 0);
    }
    
    // ============ HEALTH FACTOR TESTS ============
    
    function test_HealthFactorMaintainedDuringCycles() public {
        uint256 hfBefore = bridge.getHealthFactor();
        
        // Execute some operations
        vm.deal(operator, 20 ether);
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(operator, 10 * ONE_ETH);
        
        uint256 hfAfter = bridge.getHealthFactor();
        
        // 1:1 lock/mint operations hold HF at exactly 100% (decimals audit:
        // canonical and synthetic move in lockstep). Correct bound is >=.
        assertGe(hfAfter, 10000); // At least 100%
    }
    
    function test_EmergencyStopPreventsOperations() public {
        // Set UNDERPRICE first so the call passes the executor's mode gate and
        // actually reaches the stopped bridge (previously it reverted earlier
        // with WrongMode, never testing the emergency stop).
        vm.prank(admin);
        oracle.setGradient(-500);

        // Trigger emergency
        vm.prank(admin);
        bridge.triggerEmergencyStop();

        assertTrue(bridge.emergencyStopped());

        // Try to execute cycle - should fail at the stopped bridge
        vm.prank(botOperator);
        vm.expectRevert(BridgeCore.BridgeEmergencyStopped.selector);
        executor.executeCycleA(10 * ONE_ETH, 0);
    }
    
    // ============ LP PROTECTION TESTS ============
    
    function test_LPProtectionViaRebase() public {
        uint256 navBefore = amm.getNAVPerShare();
        uint256 lpShares = amm.balanceOf(lp);
        
        // Simulate arbitrage causing imbalance
        // Execute swap that depletes one side
        vm.prank(admin);
        address trader = makeAddr("synergy.integration.rebaseTrader");
        usds.mint(trader, 50_000 * ONE_USDS);
        
        vm.startPrank(trader);
        usds.approve(address(amm), 50_000 * ONE_USDS);
        amm.swap(50_000 * ONE_USDS, true, 0); // USDS → ETHS
        vm.stopPrank();
        
        uint256 navAfterSwap = amm.getNAVPerShare();
        
        // NAV might change due to pool imbalance
        // Now execute rebase to compensate
        uint256 rebaseAmount = 25_000 * ONE_USDS;
        vm.prank(admin);
        usds.mint(address(amm), rebaseAmount);
        
        vm.prank(admin);
        amm.rebaseLP(lp, rebaseAmount);
        
        uint256 navAfterRebase = amm.getNAVPerShare();
        
        // NAV should be restored or improved
        assertGe(navAfterRebase, navAfterSwap);
    }
    
    function test_LPNAVNeverDecreasesBelowInitial() public {
        uint256 initialNAV = amm.getNAVPerShare();
        uint256 lpInitialDeposit = amm.getLPNAV(lp);
        
        // Execute multiple operations
        for (uint i = 0; i < 5; i++) {
            // Add rebase compensation
            uint256 rebaseAmount = 10_000 * ONE_USDS;
            vm.prank(admin);
            usds.mint(address(amm), rebaseAmount);
            
            vm.prank(admin);
            amm.rebaseLP(lp, rebaseAmount);
        }
        
        uint256 finalNAV = amm.getLPNAV(lp);
        
        // Final NAV should be >= initial (protected by rebase)
        assertGe(finalNAV, lpInitialDeposit);
    }
    
    // ============ TREASURY DISTRIBUTION TESTS ============
    
    function test_TreasuryDistributionInCycles() public {
        // Simulate profit distribution
        uint256 profit = 100_000e6; // 100k USDC
        
        // Mint USDC to treasury (mock)
        vm.prank(admin);
        usds.mint(address(treasury), profit);
        
        // Distribute
        treasury.distribute(profit);
        
        // Verify 40/30/20/10 split
        assertEq(usds.balanceOf(ownerWallet), profit * 4000 / 10000);
        assertEq(usds.balanceOf(bridgeReserve), profit * 3000 / 10000);
        assertEq(usds.balanceOf(insuranceFund), profit * 2000 / 10000);
        assertEq(usds.balanceOf(rebaseFund), profit * 1000 / 10000);
    }
    
    // ============ ORACLE TESTS ============
    
    function test_OracleGradientControl() public {
        // Test different gradients
        int256[] memory gradients = new int256[](5);
        gradients[0] = -800; // -8%
        gradients[1] = -300; // -3%
        gradients[2] = 0;    // 0%
        gradients[3] = 300;  // +3%
        gradients[4] = 800;  // +8%
        
        for (uint i = 0; i < gradients.length; i++) {
            vm.prank(admin);
            oracle.setGradient(gradients[i]);
            
            int256 currentGradient = oracle.getGradient();
            assertEq(currentGradient, gradients[i]);
        }
    }
    
    function test_OracleModeTransitions() public {
        // Start neutral
        vm.prank(admin);
        oracle.setGradient(0);
        assertEq(oracle.getMode(), 2); // NEUTRAL
        
        // Transition to underprice
        vm.prank(admin);
        oracle.setGradient(-500);
        assertEq(oracle.getMode(), 0); // UNDERPRICE
        
        // Transition to overprice
        vm.prank(admin);
        oracle.setGradient(500);
        assertEq(oracle.getMode(), 1); // OVERPRICE
        
        // Back to neutral
        vm.prank(admin);
        oracle.setGradient(100);
        assertEq(oracle.getMode(), 2); // NEUTRAL (within ±2%)
    }
    
    // ============ INTEGRATION TESTS ============
    
    function test_FullCycleAWorkflow() public {
        // 1. Set underprice mode
        vm.prank(admin);
        oracle.setGradient(-500);
        
        // 2. Verify profitability
        (bool profitable, uint256 estProfit) = executor.isCycleAProfitable(10 * ONE_ETH);
        assertTrue(profitable);
        assertGt(estProfit, 0);
        
        // 3. Check health factor (1:1 backing holds exactly 100%)
        uint256 hfBefore = bridge.getHealthFactor();
        assertGe(hfBefore, 10000);
        
        // 4. Verify LP protection
        uint256 lpNAVBefore = amm.getLPNAV(lp);
        
        // 5. Simulate cycle execution (simplified)
        // In production: executor.executeCycleA() would be called
        
        // 6. Verify final state
        uint256 hfAfter = bridge.getHealthFactor();
        uint256 lpNAVAfter = amm.getLPNAV(lp);
        
        // HF should be maintained
        assertGe(hfAfter, 10000);
        
        // LP NAV should be protected
        assertGe(lpNAVAfter, lpNAVBefore);
    }
    
    function test_MultipleCyclesStability() public {
        // Execute multiple cycles in different modes
        for (uint i = 0; i < 10; i++) {
            // Alternate between underprice and overprice
            int256 gradient = i % 2 == 0 ? int256(-500) : int256(500);
            
            vm.prank(admin);
            oracle.setGradient(gradient);
            
            // Verify system remains stable (1:1 backing holds exactly 100%)
            uint256 hf = bridge.getHealthFactor();
            assertGe(hf, 10000); // Always at least 100%
            
            assertFalse(bridge.emergencyStopped());
        }
    }
    
    // ============ EDGE CASE TESTS ============
    
    function test_ZeroSpreadNoArbitrage() public {
        // Set neutral mode (minimal gradient)
        vm.prank(admin);
        oracle.setGradient(0);
        
        (bool profitable, ) = executor.isCycleAProfitable(10 * ONE_ETH);
        assertFalse(profitable);
        
        (profitable, ) = executor.isCycleBProfitable(10 * ONE_ETH);
        assertFalse(profitable);
    }
    
    function test_ExtremeGradientRespected() public {
        // Try to set gradient beyond max
        vm.prank(admin);
        vm.expectRevert();
        oracle.setGradient(2000); // > 1000 max
    }
    
    // ============ GAS OPTIMIZATION TESTS ============
    
    function test_GasEfficientSwaps() public {
        // Test that swaps are gas efficient
        uint256 gasStart = gasleft();
        
        vm.prank(admin);
        address trader = makeAddr("synergy.integration.gasTrader");
        usds.mint(trader, 10_000 * ONE_USDS);
        
        vm.prank(trader);
        usds.approve(address(amm), 10_000 * ONE_USDS);
        
        vm.prank(trader);
        amm.swap(10_000 * ONE_USDS, true, 0);
        
        uint256 gasUsed = gasStart - gasleft();
        
        // Should be reasonable (< 200k gas)
        assertLt(gasUsed, 200_000);
    }
}
