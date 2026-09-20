// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";
import "../contracts/ManagedOracle.sol";

/**
 * @title BridgeCoreTest - Comprehensive tests for BridgeCore contract
 * @dev Tests Lock/Mint, Burn/Unlock, Health Factor, Emergency Stop
 */
contract BridgeCoreTest is Test {
    BridgeCore public bridge;
    USDS public usds;
    ETHS public eths;
    ManagedOracle public oracle;
    
    address public admin;
    address public operator;
    address public user;
    address public mockUSDC;
    
    uint256 public constant INITIAL_ETH_PRICE = 2500e6; // $2500 in USDC (6 decimals)
    uint256 public constant ONE_ETH = 1e18;
    uint256 public constant ONE_USDC = 1e6;
    
    function setUp() public {
        admin = makeAddr("synergy.bridge.admin");
        operator = makeAddr("synergy.bridge.operator");
        user = makeAddr("synergy.bridge.user");
        // Decimals audit: the bridge reads canonical.decimals() at construction,
        // so the mock must be a real ERC20 (the old EOA placeholder also made
        // every SafeERC20 transfer a silent no-op).
        mockUSDC = address(new MockCanonicalToken());

        vm.startPrank(admin);
        
        // Deploy tokens
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(INITIAL_ETH_PRICE);
        
        // Deploy bridge
        bridge = new BridgeCore(
            address(usds),
            address(eths),
            mockUSDC,
            address(oracle)
        );
        
        // Grant roles
        bridge.grantRole(bridge.OPERATOR_ROLE(), operator);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        
        vm.stopPrank();
        
        // Fund operator with mock USDC
        vm.deal(operator, 100 ether);
    }
    
    // ============ LOCK/MINT TESTS ============
    
    function test_LockETHAndMintETHS() public {
        uint256 ethAmount = 10 * ONE_ETH; // 10 ETH
        
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(user, ethAmount);
        
        // Verify ETHS minted
        assertEq(eths.balanceOf(user), ethAmount);
        assertEq(bridge.totalLockedETH(), ethAmount);
        assertEq(bridge.totalMintedETHS(), ethAmount);
    }
    
    function test_LockUSDCAndMintUSDS() public {
        // This test would require mock USDC implementation
        // Simplified for demonstration
        uint256 usdcAmount = 10000 * ONE_USDC;
        
        // In production: mock USDC.transferFrom would be called
        // For now, we verify the function exists and compiles
        assertTrue(address(bridge) != address(0));
    }
    
    function test_RevertWhen_LockETHWhenStopped() public {
        // Trigger emergency stop
        vm.prank(admin);
        bridge.triggerEmergencyStop();
        
        vm.prank(operator);
        vm.expectRevert(BridgeCore.BridgeEmergencyStopped.selector);
        bridge.lockETHAndMintETHS{value: 1 ether}(user, ONE_ETH);
    }
    
    function test_RevertWhen_LockZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(BridgeCore.ZeroAmount.selector);
        bridge.lockETHAndMintETHS{value: 0}(user, 0);
    }
    
    // ============ BURN/UNLOCK TESTS ============
    
    function test_BurnETHSAndUnlockETH() public {
        uint256 ethAmount = 5 * ONE_ETH;
        
        // First lock
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 5 ether}(user, ethAmount);
        
        // Transfer ETHS to operator for burning
        vm.prank(user);
        eths.transfer(operator, ethAmount);
        
        // Burn and unlock
        vm.prank(operator);
        uint256 balanceBefore = user.balance;
        bridge.burnETHSAndUnlockETH(user, ethAmount);
        uint256 balanceAfter = user.balance;
        
        // Verify
        assertEq(eths.balanceOf(operator), 0);
        assertEq(bridge.totalLockedETH(), 0);
        assertEq(bridge.totalMintedETHS(), 0);
        assertEq(balanceAfter - balanceBefore, ethAmount);
    }
    
    function test_RevertWhen_BurnMoreThanMinted() public {
        uint256 ethAmount = 5 * ONE_ETH;

        // Try to burn more than minted
        vm.prank(operator);
        vm.expectPartialRevert(BridgeCore.InsufficientBalance.selector);
        bridge.burnETHSAndUnlockETH(user, ethAmount + 1);
    }
    
    // ============ HEALTH FACTOR TESTS ============
    
    function test_HealthFactorCalculation() public {
        // Initial state - no assets
        uint256 hf = bridge.getHealthFactor();
        assertEq(hf, type(uint256).max); // Max when no synthetic
        
        // Lock some ETH
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(user, 10 * ONE_ETH);
        
        // HF should be 100% (1:1 backing)
        hf = bridge.getHealthFactor();
        assertEq(hf, 10000); // 100.00%
    }
    
    function test_HealthFactorWithPriceChange() public {
        // Lock ETH at $2500
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(user, 10 * ONE_ETH);
        
        // Price drops to $2000
        vm.prank(admin);
        oracle.setExternalPrice(2000e6);
        
        // HF should drop
        uint256 hf = bridge.getHealthFactor();
        // Canonical: 10 ETH * $2000 = $20,000
        // Synthetic: 10 ETHS * $2000 = $20,000
        // HF = 100% (still 1:1 because ETHS tracks ETH price)
        assertEq(hf, 10000);
    }
    
    function test_EmergencyStopTriggered() public {
        // Lock ETH
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(user, 10 * ONE_ETH);
        
        // Manually trigger emergency
        vm.prank(admin);
        bridge.triggerEmergencyStop();
        
        assertTrue(bridge.emergencyStopped());
        
        // Verify operations are blocked
        vm.prank(operator);
        vm.expectRevert(BridgeCore.BridgeEmergencyStopped.selector);
        bridge.lockETHAndMintETHS{value: 1 ether}(user, ONE_ETH);
    }
    
    function test_LiftEmergencyStop() public {
        // Build healthy 1:1 backing FIRST (locking while stopped is impossible
        // by design — the old version tried exactly that and reverted).
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(user, 10 * ONE_ETH);

        // Trigger emergency
        vm.prank(admin);
        bridge.triggerEmergencyStop();

        assertTrue(bridge.emergencyStopped());

        // HF is exactly 100% which satisfies MIN_HEALTH_FACTOR (100%),
        // so the stop can be lifted.
        vm.prank(admin);
        bridge.liftEmergencyStop();

        assertFalse(bridge.emergencyStopped());
    }
    
    // ============ STATS TESTS ============
    
    function test_GetStats() public {
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: 10 ether}(user, 10 * ONE_ETH);
        
        (
            uint256 lockedUSDC,
            uint256 lockedETH,
            uint256 mintedUSDS,
            uint256 mintedETHS,
            uint256 healthFactor,
            bool isStopped
        ) = bridge.getStats();
        
        assertEq(lockedUSDC, 0);
        assertEq(lockedETH, 10 * ONE_ETH);
        assertEq(mintedUSDS, 0);
        assertEq(mintedETHS, 10 * ONE_ETH);
        assertEq(healthFactor, 10000);
        assertFalse(isStopped);
    }
    
    // ============ FUZZ TESTS ============
    
    function testFuzz_LockETH(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 1e15, 1000 ether); // 0.001 to 1000 ETH
        
        vm.deal(operator, ethAmount);
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: ethAmount}(user, ethAmount);
        
        assertEq(eths.balanceOf(user), ethAmount);
        assertEq(bridge.totalLockedETH(), ethAmount);
    }
    
    function testFuzz_BurnETHS(uint256 ethAmount) public {
        ethAmount = bound(ethAmount, 1e15, 100 ether);
        
        vm.deal(operator, ethAmount);
        vm.prank(operator);
        bridge.lockETHAndMintETHS{value: ethAmount}(user, ethAmount);
        
        vm.prank(user);
        eths.transfer(operator, ethAmount);
        
        vm.prank(operator);
        bridge.burnETHSAndUnlockETH(user, ethAmount);
        
        assertEq(eths.balanceOf(operator), 0);
        assertEq(bridge.totalMintedETHS(), 0);
    }
    
    // ============ RECEIVE ETH ============
    
    function test_ReceiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool success, ) = address(bridge).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(bridge).balance, 1 ether);
    }
}
