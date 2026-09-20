// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";
import "../contracts/ManagedOracle.sol";

/**
 * @title InternalAMMTest - Tests for the internal AMM pool
 * @dev Tests swaps, liquidity, rebase mechanism, NAV tracking
 */
contract InternalAMMTest is Test {
    InternalAMM public amm;
    USDS public usds;
    ETHS public eths;
    ManagedOracle public oracle;
    
    address public admin;
    address public lp1;
    address public lp2;
    address public trader;
    
    uint256 public constant INITIAL_ETH_PRICE = 2500e6;
    uint256 public constant ONE_ETH = 1e18;
    uint256 public constant ONE_USDS = 1e18; // USDS has 18 decimals
    
    function setUp() public {
        admin = makeAddr("synergy.amm.admin");
        lp1 = makeAddr("synergy.amm.lp1");
        lp2 = makeAddr("synergy.amm.lp2");
        trader = makeAddr("synergy.amm.trader");

        vm.startPrank(admin);
        
        // Deploy tokens
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(INITIAL_ETH_PRICE);
        
        // Deploy AMM
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        
        // Mint tokens for testing
        usds.mint(lp1, 1_000_000 * ONE_USDS);
        eths.mint(lp1, 1000 * ONE_ETH);
        
        usds.mint(lp2, 500_000 * ONE_USDS);
        eths.mint(lp2, 500 * ONE_ETH);
        
        usds.mint(trader, 100_000 * ONE_USDS);
        eths.mint(trader, 100 * ONE_ETH);
        
        vm.stopPrank();
    }
    
    // ============ LIQUIDITY TESTS ============
    
    function test_AddLiquidity() public {
        uint256 usdsAmount = 100_000 * ONE_USDS;
        uint256 ethsAmount = 40 * ONE_ETH; // 40 ETHS ≈ $100,000 at $2500
        
        // Approve tokens
        vm.prank(lp1);
        usds.approve(address(amm), usdsAmount);
        vm.prank(lp1);
        eths.approve(address(amm), ethsAmount);
        
        // Add liquidity
        vm.prank(lp1);
        uint256 shares = amm.addLiquidity(usdsAmount, ethsAmount);
        
        // Verify
        assertGt(shares, 0);
        assertEq(amm.balanceOf(lp1), shares);
        assertEq(amm.reserveUSDS(), usdsAmount);
        assertEq(amm.reserveETHS(), ethsAmount);
    }
    
    function test_RemoveLiquidity() public {
        // First add liquidity
        uint256 usdsAmount = 100_000 * ONE_USDS;
        uint256 ethsAmount = 40 * ONE_ETH;
        
        vm.startPrank(lp1);
        usds.approve(address(amm), usdsAmount);
        eths.approve(address(amm), ethsAmount);
        uint256 shares = amm.addLiquidity(usdsAmount, ethsAmount);
        
        // Remove liquidity
        uint256 balanceBeforeUSDS = usds.balanceOf(lp1);
        uint256 balanceBeforeETHS = eths.balanceOf(lp1);
        
        (uint256 usdsOut, uint256 ethsOut) = amm.removeLiquidity(shares);
        
        assertEq(usdsOut, usdsAmount);
        assertEq(ethsOut, ethsAmount);
        assertEq(amm.balanceOf(lp1), 0);
        
        vm.stopPrank();
    }
    
    function test_RevertWhen_RemoveMoreThanOwned() public {
        vm.prank(lp1);
        vm.expectRevert(InternalAMM.InsufficientShares.selector);
        amm.removeLiquidity(1000); // No shares
    }
    
    // ============ SWAP TESTS ============
    
    function test_SwapUSDSForETHS() public {
        // Setup pool
        _setupPool();
        
        uint256 swapAmount = 10_000 * ONE_USDS;
        
        vm.prank(trader);
        usds.approve(address(amm), swapAmount);
        
        // Get expected output
        uint256 expectedOut = amm.getAmountOut(swapAmount, true);
        
        // Execute swap
        vm.prank(trader);
        uint256 actualOut = amm.swap(swapAmount, true, 0);
        
        // Verify
        assertGt(actualOut, 0);
        assertApproxEqRel(actualOut, expectedOut, 0.01e18); // Within 1%
    }
    
    function test_SwapETHSForUSDS() public {
        _setupPool();
        
        uint256 swapAmount = 5 * ONE_ETH;
        
        vm.prank(trader);
        eths.approve(address(amm), swapAmount);
        
        uint256 expectedOut = amm.getAmountOut(swapAmount, false);
        
        vm.prank(trader);
        uint256 actualOut = amm.swap(swapAmount, false, 0);
        
        assertGt(actualOut, 0);
        assertApproxEqRel(actualOut, expectedOut, 0.01e18);
    }
    
    function test_SwapWithSlippage() public {
        _setupPool();
        
        uint256 swapAmount = 10_000 * ONE_USDS;
        uint256 expectedOut = amm.getAmountOut(swapAmount, true);
        
        // Set minAmountOut too high
        uint256 tooHighMin = expectedOut + 1000;
        
        vm.prank(trader);
        usds.approve(address(amm), swapAmount);
        
        vm.prank(trader);
        vm.expectRevert(InternalAMM.SlippageExceeded.selector);
        amm.swap(swapAmount, true, tooHighMin);
    }
    
    // ============ REBASE TESTS ============
    
    function test_RebaseLP() public {
        _setupPool();
        
        uint256 navBefore = amm.getNAVPerShare();
        uint256 rebaseAmount = 50_000 * ONE_USDS;
        
        // Mint USDS to AMM for rebase
        vm.prank(admin);
        usds.mint(address(amm), rebaseAmount);
        
        // Execute rebase
        vm.prank(admin);
        amm.rebaseLP(lp1, rebaseAmount);
        
        uint256 navAfter = amm.getNAVPerShare();
        
        // NAV should increase
        assertGt(navAfter, navBefore);
    }
    
    function test_BatchRebase() public {
        _setupPool();
        
        // Add second LP
        vm.startPrank(lp2);
        usds.approve(address(amm), 50_000 * ONE_USDS);
        eths.approve(address(amm), 20 * ONE_ETH);
        amm.addLiquidity(50_000 * ONE_USDS, 20 * ONE_ETH);
        vm.stopPrank();
        
        uint256 navBefore = amm.getNAVPerShare();
        
        address[] memory lps = new address[](2);
        lps[0] = lp1;
        lps[1] = lp2;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30_000 * ONE_USDS;
        amounts[1] = 20_000 * ONE_USDS;
        
        // Mint USDS for rebases
        vm.prank(admin);
        usds.mint(address(amm), 50_000 * ONE_USDS);
        
        // Execute batch rebase
        vm.prank(admin);
        amm.batchRebase(lps, amounts);
        
        uint256 navAfter = amm.getNAVPerShare();
        assertGt(navAfter, navBefore);
    }
    
    // ============ NAV TESTS ============
    
    function test_NAVCalculation() public {
        _setupPool();

        uint256 nav = amm.getNAVPerShare();

        // NAV should be positive
        assertGt(nav, 0);

        // Decimals audit: the old expectation below mixed a 6-decimal price with
        // 18-decimal reserves (the production bug) and then divided by 1e12 to
        // hide the mismatch. Correct expectation in normalized 18-dec dollars:
        // (100k USDS + 40 ETHS * $2500) / shares.
        uint256 ethPrice = 2500e6; // 6 decimals, as the oracle reports
        uint256 totalValue = 100_000 * ONE_USDS + (40 * ONE_ETH * ethPrice * 1e12) / 1e18;
        uint256 shares = amm.totalSupply();
        uint256 expectedNAV = totalValue * 1e18 / shares; // 18-dec fixed-point

        // Should be approximately equal
        assertApproxEqRel(nav, expectedNAV, 0.01e18);
    }
    
    function test_LPNAVTracking() public {
        _setupPool();
        
        uint256 lpNAV = amm.getLPNAV(lp1);
        int256 pnl = amm.getLPPnL(lp1);
        
        // Initially PnL should be ~0
        assertApproxEqAbs(pnl, 0, 1e6); // Within $1
    }
    
    // ============ POOL RATIO TESTS ============
    
    function test_PoolRatio() public {
        _setupPool();
        
        (uint256 usdsPercent, uint256 ethsPercent) = amm.getPoolRatio();
        
        // Should be approximately 50/50
        assertApproxEqAbs(int256(usdsPercent), 5000, 100); // Within 1%
        assertApproxEqAbs(int256(ethsPercent), 5000, 100);
        assertEq(usdsPercent + ethsPercent, 10000);
    }
    
    // ============ CONSTANT PRODUCT TESTS ============
    
    function test_ConstantProduct() public {
        _setupPool();
        
        uint256 kBefore = amm.reserveUSDS() * amm.reserveETHS();
        
        // Execute swap
        uint256 swapAmount = 5_000 * ONE_USDS;
        vm.prank(trader);
        usds.approve(address(amm), swapAmount);
        vm.prank(trader);
        amm.swap(swapAmount, true, 0);
        
        uint256 kAfter = amm.reserveUSDS() * amm.reserveETHS();
        
        // k should increase (due to fees)
        assertGt(kAfter, kBefore);
    }
    
    // ============ FUZZ TESTS ============
    
    function testFuzz_SwapAmount(uint256 amount) public {
        _setupPool();
        amount = bound(amount, 1e15, 10_000 * ONE_USDS);
        
        vm.prank(trader);
        usds.approve(address(amm), amount);
        
        vm.prank(trader);
        uint256 out = amm.swap(amount, true, 0);
        
        assertGt(out, 0);
        assertLt(out, amm.reserveETHS()); // Can't drain pool
    }
    
    // ============ HELPERS ============
    
    function _setupPool() internal {
        uint256 usdsAmount = 100_000 * ONE_USDS;
        uint256 ethsAmount = 40 * ONE_ETH;
        
        vm.startPrank(lp1);
        usds.approve(address(amm), usdsAmount);
        eths.approve(address(amm), ethsAmount);
        amm.addLiquidity(usdsAmount, ethsAmount);
        vm.stopPrank();
    }
}
