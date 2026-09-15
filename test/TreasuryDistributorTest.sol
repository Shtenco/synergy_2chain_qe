// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title TreasuryDistributorTest - Tests for profit distribution
 * @dev Tests 40/30/20/10 split, tracking, admin functions
 */
contract TreasuryDistributorTest is Test {
    TreasuryDistributor public treasury;
    USDS public usds;
    
    address public owner = address(0x1);
    address public bridgeReserve = address(0x2);
    address public insuranceFund = address(0x3);
    address public rebaseFund = address(0x4);
    address public mockUSDC = address(0x5);
    
    function setUp() public {
        usds = new USDS();
        
        vm.prank(owner);
        treasury = new TreasuryDistributor(
            address(usds), // Using USDS as mock USDC for testing
            owner,
            bridgeReserve,
            insuranceFund,
            rebaseFund
        );
        
        // Fund treasury
        usds.mint(address(treasury), 1_000_000e18);
    }
    
    // ============ DISTRIBUTION TESTS ============
    
    function test_DistributeProfit() public {
        uint256 profit = 100_000e18;
        
        treasury.distribute(profit);
        
        // Check distributions (40/30/20/10)
        assertEq(usds.balanceOf(owner), 40_000e18);
        assertEq(usds.balanceOf(bridgeReserve), 30_000e18);
        assertEq(usds.balanceOf(insuranceFund), 20_000e18);
        assertEq(usds.balanceOf(rebaseFund), 10_000e18);
        
        // Check tracking
        assertEq(treasury.totalDistributed(), profit);
        assertEq(treasury.distributionCount(), 1);
    }
    
    function test_MultipleDistributions() public {
        uint256 profit1 = 50_000e18;
        uint256 profit2 = 75_000e18;
        
        treasury.distribute(profit1);
        treasury.distribute(profit2);
        
        assertEq(treasury.totalDistributed(), profit1 + profit2);
        assertEq(treasury.distributionCount(), 2);
        
        // Owner should have 40% of both
        uint256 expectedOwner = (profit1 * 4000 / 10000) + (profit2 * 4000 / 10000);
        assertEq(usds.balanceOf(owner), expectedOwner);
    }
    
    function testFail_DistributeZero() public {
        treasury.distribute(0);
    }
    
    function testFail_DistributeMoreThanBalance() public {
        treasury.distribute(2_000_000e18); // More than funded
    }
    
    // ============ PREVIEW TESTS ============
    
    function test_PreviewDistribution() public {
        uint256 amount = 100_000e18;
        
        (uint256 ownerAmt, uint256 bridgeAmt, uint256 insuranceAmt, uint256 rebaseAmt) = 
            treasury.previewDistribution(amount);
        
        assertEq(ownerAmt, 40_000e18);
        assertEq(bridgeAmt, 30_000e18);
        assertEq(insuranceAmt, 20_000e18);
        assertEq(rebaseAmt, 10_000e18);
        
        // Total should equal input
        assertEq(ownerAmt + bridgeAmt + insuranceAmt + rebaseAmt, amount);
    }
    
    // ============ ADMIN TESTS ============
    
    function test_UpdateRecipients() public {
        address newOwner = address(0x10);
        address newBridge = address(0x20);
        address newInsurance = address(0x30);
        address newRebase = address(0x40);
        
        vm.prank(owner);
        treasury.updateRecipients(newOwner, newBridge, newInsurance, newRebase);
        
        // Distribute and verify new recipients receive
        treasury.distribute(100_000e18);
        
        assertEq(usds.balanceOf(newOwner), 40_000e18);
        assertEq(usds.balanceOf(newBridge), 30_000e18);
        assertEq(usds.balanceOf(newInsurance), 20_000e18);
        assertEq(usds.balanceOf(newRebase), 10_000e18);
    }
    
    function testFail_UpdateRecipientsZeroAddress() public {
        vm.prank(owner);
        treasury.updateRecipients(address(0), bridgeReserve, insuranceFund, rebaseFund);
    }
    
    function testFail_UpdateRecipientsNotOwner() public {
        vm.prank(address(0x99));
        treasury.updateRecipients(address(0x10), bridgeReserve, insuranceFund, rebaseFund);
    }
    
    // ============ STATS TESTS ============
    
    function test_GetStats() public {
        treasury.distribute(100_000e18);
        
        (
            uint256 totalDist,
            uint256 ownerTotal,
            uint256 bridgeTotal,
            uint256 insuranceTotal,
            uint256 rebaseTotal,
            uint256 count
        ) = treasury.getStats();
        
        assertEq(totalDist, 100_000e18);
        assertEq(ownerTotal, 40_000e18);
        assertEq(bridgeTotal, 30_000e18);
        assertEq(insuranceTotal, 20_000e18);
        assertEq(rebaseTotal, 10_000e18);
        assertEq(count, 1);
    }
    
    // ============ FUZZ TESTS ============
    
    function testFuzz_Distribute(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000e18);
        
        // Ensure treasury has enough
        if (usds.balanceOf(address(treasury)) < amount) {
            usds.mint(address(treasury), amount);
        }
        
        treasury.distribute(amount);
        
        uint256 ownerAmt = (amount * 4000) / 10000;
        uint256 bridgeAmt = (amount * 3000) / 10000;
        uint256 insuranceAmt = (amount * 2000) / 10000;
        uint256 rebaseAmt = amount - ownerAmt - bridgeAmt - insuranceAmt;
        
        assertEq(usds.balanceOf(owner), ownerAmt);
        assertEq(usds.balanceOf(bridgeReserve), bridgeAmt);
        assertEq(usds.balanceOf(insuranceFund), insuranceAmt);
        assertEq(usds.balanceOf(rebaseFund), rebaseAmt);
    }
}
