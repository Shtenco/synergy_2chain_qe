// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/GradientControllerV2.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title Stage2Fork - ТЗ Этап 2 acceptance on Base fork
 * @notice Covers: multi-venue routing (max |spread| wins), HALT/STANDBY automaton,
 *         depeg auto-halt, per-tx lock caps, NAV precision, and end-to-end
 *         conservation through the V2 gate.
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract Stage2Fork -vv
 */
contract Stage2Fork is Test {
    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    GradientControllerV2 public controller;
    USDS public usds;
    ETHS public eths;
    MockCanonicalToken public fUSDC;
    MockWETH9 public mWETH;
    ForeignPoolMock public donorA; // stale-low @ 2000
    ForeignPoolMock public donorB; // near-fair @ 2450

    address public admin;
    address public keeper;
    address public seeder;
    address public bot;
    address public lp;
    address public whale;

    uint256 public constant FAIR = 2500;
    uint256 public constant ONE = 1e18;

    function setUp() public {
        admin = makeAddr("s2.admin");
        keeper = makeAddr("s2.keeper");
        seeder = makeAddr("s2.seeder");
        bot = makeAddr("s2.bot");
        lp = makeAddr("s2.lp");
        whale = makeAddr("s2.whale");

        fUSDC = new MockCanonicalToken();
        mWETH = new MockWETH9();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), address(fUSDC), address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        donorA = new ForeignPoolMock(address(fUSDC), address(mWETH));
        donorB = new ForeignPoolMock(address(fUSDC), address(mWETH));
        controller = new GradientControllerV2(address(oracle));

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), admin);
        oracle.grantRole(oracle.ALGO_CONTROLLER(), address(controller));
        controller.grantRole(controller.KEEPER_ROLE(), keeper);

        fUSDC.mint(address(bridge), 3_000 * ONE);
        fUSDC.mint(seeder, 2_000 * ONE);
        fUSDC.mint(bot, 1_500 * ONE);
        vm.deal(seeder, 10 ether);

        vm.startPrank(seeder);
        fUSDC.approve(address(bridge), 1_500 * ONE);
        bridge.lockUSDCAndMintUSDS(seeder, 1_500 * ONE);
        vm.stopPrank();

        // Fair internal pool: 200k / 80 @ 2500.
        usds.mint(lp, 200_000 * ONE);
        eths.mint(lp, 80 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), 200_000 * ONE);
        eths.approve(address(amm), 80 * ONE);
        amm.addLiquidity(200_000 * ONE, 80 * ONE);
        vm.stopPrank();

        // Donor A stale-low: 4M / 2k @ 2000. Donor B near-fair: 490k / 200 @ 2450.
        fUSDC.mint(whale, 5_000_000 * ONE);
        vm.deal(whale, 3_000 ether);
        vm.startPrank(whale);
        mWETH.deposit{value: 2_200 ether}();
        fUSDC.approve(address(donorA), 4_000_000 * ONE);
        mWETH.approve(address(donorA), 2_000 * ONE);
        donorA.seed(4_000_000 * ONE, 2_000 * ONE);
        fUSDC.approve(address(donorB), 490_000 * ONE);
        mWETH.approve(address(donorB), 200 * ONE);
        donorB.seed(490_000 * ONE, 200 * ONE);
        vm.stopPrank();
    }

    /// @dev System EQUITY (synthetics = liabilities). Donors excluded.
    function _sysEquity() internal view returns (uint256) {
        uint256 assets = fUSDC.balanceOf(address(bridge))
            + fUSDC.balanceOf(seeder)
            + fUSDC.balanceOf(bot)
            + fUSDC.balanceOf(lp)
            + mWETH.balanceOf(bot) * FAIR;
        uint256 ethAssets = (address(bridge).balance + seeder.balance + bot.balance + lp.balance) * FAIR;
        uint256 poolAssets = amm.reserveUSDS() + amm.reserveETHS() * FAIR;
        uint256 liabilities = usds.totalSupply() + eths.totalSupply() * FAIR;
        return assets + ethAssets + poolAssets - liabilities;
    }

    function test_RouteSelection_MaxAbsSpreadWins() public {
        int256[] memory s = new int256[](2);

        // Internal 2500 vs A 2000 (+2500bps) vs B 2450 (+204bps): A wins, clamped +1000.
        s[0] = 2500;
        s[1] = 204;
        vm.prank(keeper);
        (int256 g, uint8 m, uint256 v) = controller.updateRoute(s, block.timestamp);
        assertEq(g, 1000, "must clamp at +1000");
        assertEq(m, 1, "must be OVERPRICE");
        assertEq(v, 0, "must route to venue A");

        // A converged (+150), B still +204: B wins unclamped.
        s[0] = 150;
        s[1] = 204;
        vm.prank(keeper);
        (g, m, v) = controller.updateRoute(s, block.timestamp);
        assertEq(g, 204, "must pass through unclamped");
        assertEq(m, 1, "204bps is OVERPRICE");
        assertEq(v, 1, "must route to venue B");

        // All inside deadband: NEUTRAL, gate closed.
        s[0] = 100;
        s[1] = -150;
        vm.prank(keeper);
        (g, m, v) = controller.updateRoute(s, block.timestamp);
        assertEq(g, -150, "max abs is -150");
        assertEq(m, 2, "must be NEUTRAL");
        assertEq(v, 1, "venue of max abs");
        (bool allowed, ) = controller.harvestAllowed();
        assertFalse(allowed, "gate must be closed in NEUTRAL");

        // Empty set reverts.
        int256[] memory empty = new int256[](0);
        vm.prank(keeper);
        vm.expectPartialRevert(GradientControllerV2.EmptySpreads.selector);
        controller.updateRoute(empty, block.timestamp);

        // Stale quote reverts.
        s[0] = 2500;
        s[1] = 204;
        vm.prank(keeper);
        vm.expectPartialRevert(GradientControllerV2.StaleQuote.selector);
        controller.updateRoute(s, 1);
    }

    function test_HaltBlocksGate_DepegAutoHalts() public {
        int256[] memory s = new int256[](1);
        s[0] = 2500;
        vm.prank(keeper);
        controller.updateRoute(s, block.timestamp);

        (bool allowed, uint8 mode) = controller.harvestAllowed();
        assertTrue(allowed, "gate must be open");
        assertEq(mode, 1, "mode must be OVERPRICE");

        controller.halt("risk review");
        (allowed, ) = controller.harvestAllowed();
        assertFalse(allowed, "halt must close the gate");
        assertEq(controller.haltReason(), "risk review", "reason recorded");

        // Unauthorized halt reverts.
        vm.prank(makeAddr("s2.stranger"));
        vm.expectRevert();
        controller.halt("evil");

        controller.resume();
        (allowed, ) = controller.harvestAllowed();
        assertTrue(allowed, "resume must reopen");

        // 10% depeg auto-halts.
        vm.prank(keeper);
        bool breached = controller.reportDepeg(900_000, block.timestamp);
        assertTrue(breached, "10% must breach");
        assertTrue(controller.halted(), "depeg must auto-halt");
        (allowed, ) = controller.harvestAllowed();
        assertFalse(allowed, "gate closed after depeg");

        // 0.5% deviation: no breach (still halted until resume).
        vm.prank(keeper);
        breached = controller.reportDepeg(1_005_000, block.timestamp);
        assertFalse(breached, "0.5% must not breach");
        assertTrue(controller.halted(), "resume is manual");

        controller.resume();
        (allowed, ) = controller.harvestAllowed();
        assertTrue(allowed, "manual resume reopens");
    }

    function test_LockCaps_Enforced() public {
        // Caps off by default (existing behavior preserved).
        assertEq(bridge.maxLockETHPerTx(), 0, "default must be unlimited");
        assertEq(bridge.maxLockUSDCPerTx(), 0, "default must be unlimited");

        bridge.setLockCaps(1 ether, 1_000 * ONE);

        // ETH leg over cap reverts (exact value sent, so only the cap trips).
        vm.expectPartialRevert(BridgeCore.LockExceedsCap.selector);
        bridge.lockETHAndMintETHS{value: 2 ether}(address(this), 2 ether);

        // ETH leg within cap works (test contract holds OPERATOR_ROLE from deploy).
        bridge.lockETHAndMintETHS{value: 0.5 ether}(address(this), 0.5 ether);

        // USDC leg over cap reverts.
        fUSDC.mint(address(this), 2_000 * ONE);
        fUSDC.approve(address(bridge), 2_000 * ONE);
        vm.expectPartialRevert(BridgeCore.LockExceedsCap.selector);
        bridge.lockUSDCAndMintUSDS(address(this), 2_000 * ONE);

        // USDC leg within cap works.
        bridge.lockUSDCAndMintUSDS(address(this), 500 * ONE);

        // Caps back off: large locks work again.
        bridge.setLockCaps(0, 0);
        bridge.lockETHAndMintETHS{value: 2 ether}(address(this), 2 ether);
    }

    function test_NAVPrecision_NoLongerTruncated() public {
        uint256 nav = amm.getNAVPerShare();
        // Pool holds ~200k + 80*2500 = ~400k value over ~126k shares (18-dec).
        // Old code floored to a small integer (3); fixed code returns 18-dec fixed-point.
        assertGt(nav, 1e18, "NAV must be 18-decimal fixed-point, not a truncated int");
        uint256 lpNav = amm.getLPNAV(lp);
        assertGt(lpNav, 0, "LP NAV positive");
        console.logUint(nav);
        console.logUint(lpNav);
    }

    function test_EndToEnd_V2Gate_Conservation() public {
        int256[] memory s = new int256[](2);
        s[0] = 2500; // donor A: internal rich by 25%
        s[1] = 204; // donor B: marginal
        vm.prank(keeper);
        (, uint8 m, uint256 v) = controller.updateRoute(s, block.timestamp);
        assertEq(m, 1, "gate must be OVERPRICE");
        assertEq(v, 0, "route must be donor A");

        (bool allowed, ) = controller.harvestAllowed();
        assertTrue(allowed, "gate open");

        uint256 sysBefore = _sysEquity();
        uint256 forBefore = donorA.reserveU() + donorA.reserveE() * FAIR;
        uint256 botUBefore = fUSDC.balanceOf(bot);

        // Forward harvest via routed venue A, size 0.5 mWETH.
        uint256 amount = 5e17;
        uint256 rU = donorA.reserveU();
        uint256 rE = donorA.reserveE();
        uint256 dx = (rU * 1000 * amount) / (997 * (rE - amount)) + 1;
        vm.prank(bot);
        fUSDC.approve(address(donorA), type(uint256).max);
        vm.prank(bot);
        uint256 got = donorA.swapUforE(dx);

        vm.startPrank(bot);
        mWETH.withdraw(got);
        bridge.lockETHAndMintETHS{value: got}(bot, got);
        eths.approve(address(amm), got);
        uint256 usdsOut = amm.swap(got, false, 0);
        vm.stopPrank();

        vm.prank(bot);
        bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);

        uint256 profit = fUSDC.balanceOf(bot) - botUBefore;
        uint256 sysAfter = _sysEquity();
        uint256 forAfter = donorA.reserveU() + donorA.reserveE() * FAIR;

        console.logUint(profit);
        console.logInt(int256(sysAfter) - int256(sysBefore));
        console.logInt(int256(forAfter) - int256(forBefore));

        assertGt(profit, 0, "harvest through V2 gate earned nothing");
        assertGt(sysAfter, sysBefore, "system did not grow");
        assertApproxEqAbs(
            sysAfter + forAfter, sysBefore + forBefore, 1e15, "conservation violated"
        );
    }
}
