// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/v2/SyntheticTokensV2.sol";
import "../contracts/v2/BridgeCoreV2.sol";
import "../contracts/v2/InternalAMMV2.sol";
import "../contracts/v2/UniswapV3VenueV2.sol";
import "../contracts/v2/ArbitrageExecutorV2.sol";
import "../contracts/v2/OPGasCostModelV2.sol";
import "../contracts/v2/IExternalPriceOracleV2.sol";
import "../contracts/pb/BridgePool.sol";
import "../contracts/pb/ExecutorPB.sol";

contract FixedOracleU is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title UnifiedBridges - SAME conditions, two bridge designs head-to-head.
 * @notice Internal MINT pool $118M (59M USDS / 23.6k ETHS @2500, printed at
 *         start), external real pool ~$121.5M at dip block (53.06M USDC +
 *         27.39k WETH => $53.06M + $68.47M), arb capital $20.
 *         Solves: minimum capital in POOL-BRIDGE vs BRIDGE-LOCK.
 */
contract UnifiedBridges is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    USDSV2 internal usds;
    ETHSV2 internal eths;
    FixedOracleU internal oracle;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    BridgeCoreV2 internal bridge;
    ArbitrageExecutorV2 internal execL;
    BridgePool internal poolA;
    BridgePool internal poolB;
    ExecutorPB internal execP;
    OPGasCostModelV2 internal gasModel;
    address internal seeder;
    address internal bot;
    address internal lp;

    struct USnap {
        uint256 bot;
        int256 ours;
        uint256 uni;
    }

    function _base() internal {
        seeder = makeAddr("un.seeder");
        bot = makeAddr("un.bot");
        lp = makeAddr("un.lp");
        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOracleU();
        amm = new InternalAMMV2(address(usds), address(eths), address(oracle));
        venue = new UniswapV3VenueV2(UNI_POOL, USDC, WETH);
        gasModel = new OPGasCostModelV2(address(oracle));
        gasModel = new OPGasCostModelV2(address(oracle));
        usds.grantRole(usds.BRIDGE_ROLE(), address(this));
        eths.grantRole(eths.BRIDGE_ROLE(), address(this));
        // Internal MINT pool $118M, printed at start.
        usds.mint(lp, 59_000_000e18);
        eths.mint(lp, 23_600 ether);
        vm.startPrank(lp);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(59_000_000e18, 23_600 ether);
        vm.stopPrank();
        deal(USDC, bot, 20e6);
    }

    function _uniMark() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
    }

    function _ammMark() internal view returns (uint256) {
        (uint256 rU, uint256 rE) = amm.reserves();
        return rU + rE * 2500;
    }

    // ============ ROUTE L: bridge-lock, backing $1,000 ============

    function _snapLock() internal view returns (USnap memory t) {
        t.bot = IERC20(USDC).balanceOf(bot);
        int256 lnav = int256(bridge.hardAssets18()) - int256(bridge.liabilities18());
        t.ours = int256(_ammMark()) + lnav;
        t.uni = _uniMark();
    }

    function _deployLockRoute() internal {
        bridge = new BridgeCoreV2(address(usds), address(eths), USDC, address(oracle));
        execL = new ArbitrageExecutorV2(
            address(bridge), address(amm), address(venue),
            USDC, WETH, address(usds), address(eths)
        );
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        usds.revokeRole(usds.BRIDGE_ROLE(), address(this));
        eths.revokeRole(eths.BRIDGE_ROLE(), address(this));
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(execL));
        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        execL.grantRole(execL.BOT_ROLE(), bot);
        vm.prank(bot);
        IERC20(USDC).approve(address(execL), type(uint256).max);
    }

    /// @dev RULE: with a $118M minted pool, thin backing REVERTS.
    ///      Bridge-lock minimum = full minted supply (global solvency).
    function test_LockBridge_ThinBackingReverts() public {
        _base();
        _deployLockRoute();
        deal(USDC, seeder, 1000e6);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        vm.expectRevert();
        bridge.lockUSDCAndMintUSDS(seeder, 1000e6);
        vm.stopPrank();
        console.logUint(bridge.solvencyBps());
    }

    /// @dev STRONGER: even backing EQUAL to minted supply reverts.
    ///      (X)/(M+X) < 1 for every finite X: asymptotic impossibility.
    ///      Bridge-lock minimum with a minted pool = INFINITY (unboardable).
    function test_LockBridge_EvenFullBackingReverts() public {
        _base();
        _deployLockRoute();
        deal(USDC, seeder, 59_000_000e6);
        deal(seeder, 23_600 ether);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        vm.expectRevert();
        bridge.lockUSDCAndMintUSDS(seeder, 59_000_000e6);
        vm.stopPrank();
        console.logUint(bridge.solvencyBps());
        // Compatible configuration is lock-MINTED pools (proven: V2EqualPools).
    }

    // ============ ROUTE P: pool-bridge, small vs tiny pools ============

    function _buildPools(uint256 aU, uint256 aB, uint256 bU, uint256 bB) internal {
        poolA = new BridgePool(address(usds), USDC, 5, 1e12, "UnPool USDS-USDC", "UPU");
        poolB = new BridgePool(address(eths), WETH, 5, 1, "UnPool ETHS-WETH", "UPE");
        execP = new ExecutorPB(
            address(poolA), address(poolB), address(amm), address(venue),
            USDC, WETH, address(usds), address(eths)
        );
        execP.grantRole(execP.BOT_ROLE(), bot);
        deal(USDC, seeder, aB);
        deal(WETH, seeder, bB);
        usds.mint(seeder, aU);
        eths.mint(seeder, bU);
        vm.startPrank(seeder);
        usds.approve(address(poolA), type(uint256).max);
        IERC20(USDC).approve(address(poolA), type(uint256).max);
        poolA.addLiquidity(aU, aB);
        eths.approve(address(poolB), type(uint256).max);
        IERC20(WETH).approve(address(poolB), type(uint256).max);
        poolB.addLiquidity(bU, bB);
        vm.stopPrank();
        usds.revokeRole(usds.BRIDGE_ROLE(), address(this));
        eths.revokeRole(eths.BRIDGE_ROLE(), address(this));
        vm.prank(bot);
        IERC20(USDC).approve(address(execP), type(uint256).max);
    }

    function _snapPool() internal view returns (USnap memory t) {
        t.bot = IERC20(USDC).balanceOf(bot);
        (uint256 aU, uint256 aB) = poolA.reserves();
        (uint256 bU, uint256 bB) = poolB.reserves();
        t.ours = int256(_ammMark()) + int256(aU) + int256(aB * 1e12) + int256((bU + bB) * 2500);
        t.uni = _uniMark();
    }

    function _tryP(uint256 minW, uint256 minE, uint256 minU, uint256 minC, uint256 minP)
        internal
        returns (bool ok)
    {
        vm.prank(bot);
        try execP.executeExternalBuyInternalSell(20e6, minW, minE, minU, minC, minP, block.timestamp)
            returns (uint256)
        {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _runP(uint256 minW, uint256 minE, uint256 minU, uint256 minC, uint256 minP)
        internal
        returns (uint256 rounds, uint256 gasUsed)
    {
        uint256 g0 = gasleft();
        while (rounds < 25) {
            if (!_tryP(minW, minE, minU, minC, minP)) break;
            rounds++;
        }
        gasUsed = g0 - gasleft();
    }

    function _assertPool(USnap memory a, USnap memory b, uint256 gasUsed, uint256 rounds)
        internal
        returns (int256 systemNet)
    {
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 oursD = b.ours - a.ours;
        int256 uniD = int256(b.uni) - int256(a.uni);
        uint256 fee = gasModel.estimateFeeUSDC6(gasUsed, tx.gasprice, 400 * rounds);
        systemNet = botD * 1e12 + oursD - int256(fee) * 1e12;
        console.logUint(rounds);
        console.logInt(botD);
        console.logInt(oursD);
        console.logInt(uniD);
        console.logUint(fee);
        console.logInt(systemNet);
        assertApproxEqAbs(botD * 1e12 + oursD + uniD, 0, 1e16, "conservation broken");
        assertLt(uniD, 0, "external donor did not pay");
    }

    /// @dev Zero-execution accounting: nothing moved anywhere.
    function _assertPoolNoDonor(USnap memory a, USnap memory b, uint256 gasUsed, uint256 rounds)
        internal
        returns (int256 systemNet)
    {
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 oursD = b.ours - a.ours;
        int256 uniD = int256(b.uni) - int256(a.uni);
        uint256 fee = gasModel.estimateFeeUSDC6(gasUsed, tx.gasprice, 400 * (rounds == 0 ? 1 : rounds));
        systemNet = botD * 1e12 + oursD - int256(fee) * 1e12;
        console.logUint(rounds);
        console.logInt(botD);
        console.logInt(oursD);
        console.logInt(uniD);
        assertEq(botD, 0, "bot moved without execution");
        assertEq(oursD, 0, "pools moved without execution");
        assertEq(uniD, 0, "donor moved without execution");
    }

    function test_PoolBridge_SmallPools10k() public {
        _base();
        _buildPools(10_000e18, 10_000e6, 2 ether, 2 ether);
        USnap memory s0 = _snapPool();
        // Loose exit bound: failure mode must be the PROFIT GATE, not my bound.
        (uint256 rounds, uint256 gasUsed) = _runP(0.0080 ether, 0.0080 ether, 19.9e18, 19.5e6, 5_000);
        USnap memory s1 = _snapPool();
        _assertPoolNoDonor(s0, s1, gasUsed, rounds);
        console.logUint(IERC20(USDC).balanceOf(bot));
        assertEq(rounds, 0, "small pools should not execute $20 rounds");
        assertEq(IERC20(USDC).balanceOf(bot), 20e6, "capital moved without execution");
    }

    /// @dev Minimum proof: poolA 12k/12k + poolB 5/5 (sides > $10.5k).
    ///      Equation predicts marginal execution.
    function test_PoolBridge_MinPools21k() public {
        _base();
        _buildPools(12_000e18, 12_000e6, 5 ether, 5 ether);
        USnap memory s0 = _snapPool();
        (uint256 rounds, uint256 gasUsed) = _runP(0.0080 ether, 0.0080 ether, 19.9e18, 19.9e6, 5_000);
        USnap memory s1 = _snapPool();
        int256 systemNet = _assertPool(s0, s1, gasUsed, rounds);
        console.logUint(IERC20(USDC).balanceOf(bot));
        assertGe(rounds, 1, "min pools never executed");
        assertGt(systemNet, 0, "min-pool system not profitable");
    }

    function test_PoolBridge_TinyPools1k() public {
        _base();
        _buildPools(1_000e18, 1_000e6, 0.2 ether, 0.2 ether);
        uint256 b0 = IERC20(USDC).balanceOf(bot);
        (uint256 rounds,) = _runP(0.0078 ether, 0.0078 ether, 19e18, 19e6, 1);
        uint256 b1 = IERC20(USDC).balanceOf(bot);
        console.logUint(rounds);
        console.logUint(b1);
        assertGe(b1, b0, "tiny pools lost capital");
    }
}
