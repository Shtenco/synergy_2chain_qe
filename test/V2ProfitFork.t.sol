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

/// @notice Stub oracle: fixed 2500e6, never stale. Disclosed limitation:
///         this test proves EXECUTION profit, not oracle sourcing.
contract FixedOracleP is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2ProfitFork - does ArbitrageExecutorV2 earn real profit or is it nonsense?
 * @notice Base fork, pinned block. External leg = REAL Uniswap V3 pool swap
 *         via UniswapV3VenueV2. Internal leg = InternalAMMV2 seeded ONLY
 *         through backed bridge locks (no direct synthetic mint).
 *         Funding via deal() is test-actor funding only (disclosed).
 */
contract V2ProfitFork is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    uint256 internal constant USDC_IN = 20e6;

    USDSV2 internal usds;
    ETHSV2 internal eths;
    FixedOracleP internal oracle;
    BridgeCoreV2 internal bridge;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    ArbitrageExecutorV2 internal executor;

    address internal seeder;
    address internal bot;

    function setUp() public {
        seeder = makeAddr("v2p.seeder");
        bot = makeAddr("v2p.bot");

        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOracleP();
        bridge = new BridgeCoreV2(address(usds), address(eths), USDC, address(oracle));
        amm = new InternalAMMV2(address(usds), address(eths), address(oracle));
        venue = new UniswapV3VenueV2(UNI_POOL, USDC, WETH);
        executor = new ArbitrageExecutorV2(
            address(bridge), address(amm), address(venue),
            USDC, WETH, address(usds), address(eths)
        );

        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        usds.renounceRole(usds.DEFAULT_ADMIN_ROLE(), address(this));
        eths.renounceRole(eths.DEFAULT_ADMIN_ROLE(), address(this));
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(executor));
        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        executor.grantRole(executor.BOT_ROLE(), bot);

        _seedBackedInternalPool();
        deal(USDC, bot, 500e6);
        vm.prank(bot);
        IERC20(USDC).approve(address(executor), type(uint256).max);
    }

    /// @dev Internal AMM seeded ONLY via backed bridge locks. No direct mint.
    function _seedBackedInternalPool() internal {
        deal(USDC, seeder, 60_000e6);
        deal(seeder, 25 ether);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, 50_000e6);
        bridge.lockETHAndMintETHS{value: 20 ether}(seeder, 20 ether);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(50_000e18, 20 ether);
        vm.stopPrank();
    }

    /// @dev Fair-mark snapshot of the EXTERNAL donor (real pool) + internal AMM.
    function _extMark() internal view returns (uint256 uni18, uint256 rU, uint256 rE) {
        uni18 = IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
        (rU, rE) = amm.reserves();
    }

    /// @dev Proves the external pool donated: poolDelta < 0 and
    ///      bot + internal + external == 0 (three-way conservation).
    function _assertDonorPaid(uint256 uni0, uint256 u0, uint256 e0, int256 botDelta) internal view {
        (uint256 uni1, uint256 u1, uint256 e1) = _extMark();
        int256 poolDelta = int256(uni1) - int256(uni0);
        int256 intDelta = int256(u1) - int256(u0) + int256(e1 * 2500) - int256(e0 * 2500);
        console.logInt(poolDelta);
        console.logInt(intDelta);
        assertLt(poolDelta, 0, "external pool did not donate");
        assertApproxEqAbs(botDelta * 1e12 + intDelta + poolDelta, 0, 1e15, "venue conservation broken");
    }

    function test_V2Executor_RealProfitOrNonsense() public {
        uint256 botBefore = IERC20(USDC).balanceOf(bot);
        uint256 solvBefore = bridge.solvencyBps();
        (uint256 uni0, uint256 u0, uint256 e0) = _extMark();

        uint256 gasBefore = gasleft();
        vm.prank(bot);
        executor.executeExternalBuyInternalSell(
            USDC_IN,
            0.0078 ether,
            19e18,
            0,
            1,
            block.timestamp
        );
        uint256 gasUsed = gasBefore - gasleft();

        uint256 botAfter = IERC20(USDC).balanceOf(bot);
        int256 botDelta = int256(botAfter) - int256(botBefore);
        uint256 gasCostWei = gasUsed * tx.gasprice;
        uint256 gasCost6 = (gasCostWei * 2500e6) / 1e18;
        int256 netDelta = botDelta - int256(gasCost6);

        console.logInt(botDelta);
        console.logUint(gasUsed);
        console.logUint(gasCostWei);
        console.logUint(gasCost6);
        console.logInt(netDelta);
        console.logUint(bridge.solvencyBps());
        console.logUint(usds.balanceOf(address(executor)));
        console.logUint(eths.balanceOf(address(executor)));
        console.logUint(IERC20(USDC).balanceOf(address(executor)));

        assertGt(botDelta, 0, "V2 executor earned no real USDC: nonsense confirmed");
        _assertDonorPaid(uni0, u0, e0, botDelta);
        assertGe(bridge.solvencyBps(), solvBefore, "bridge solvency fell");
        assertGe(bridge.solvencyBps(), 10_000, "bridge insolvent");
        assertEq(usds.balanceOf(address(executor)), 0, "executor left USDS dust");
        assertEq(eths.balanceOf(address(executor)), 0, "executor left ETHS dust");
        assertEq(IERC20(USDC).balanceOf(address(executor)), 0, "executor kept USDC");
    }

    /// @dev Appoint the spread V1-style: seed a second internal pool OFF-MARKET
    ///      (8000 USDS / 2.9 ETHS ~= 2758 USDS/ETHS vs external ~2487).
    ///      Seeding is at-ratio, so the seeder takes no price-impact loss;
    ///      the subsidy is the LP holding overpriced ETHS (disclosed).
    function _deployOffMarketStack() internal returns (InternalAMMV2 amm2, ArbitrageExecutorV2 exec2) {
        amm2 = new InternalAMMV2(address(usds), address(eths), address(oracle));
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, 8_000e6);
        bridge.lockETHAndMintETHS{value: 2.9 ether}(seeder, 2.9 ether);
        usds.approve(address(amm2), type(uint256).max);
        eths.approve(address(amm2), type(uint256).max);
        amm2.addLiquidity(8_000e18, 2.9 ether);
        vm.stopPrank();

        exec2 = new ArbitrageExecutorV2(
            address(bridge), address(amm2), address(venue),
            USDC, WETH, address(usds), address(eths)
        );
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(exec2));
        exec2.grantRole(exec2.BOT_ROLE(), bot);
        vm.prank(bot);
        IERC20(USDC).approve(address(exec2), type(uint256).max);
    }

    function test_V2Executor_AppointedSpreadCoversFullBaseGas() public {
        (InternalAMMV2 amm2, ArbitrageExecutorV2 exec2) = _deployOffMarketStack();
        OPGasCostModelV2 gasModel = new OPGasCostModelV2(address(oracle));
        uint256 botBefore = IERC20(USDC).balanceOf(bot);

        uint256 gasBefore = gasleft();
        vm.prank(bot);
        exec2.executeExternalBuyInternalSell(50e6, 0.0195 ether, 52e18, 0, 1_000_000, block.timestamp);
        uint256 gasUsed = gasBefore - gasleft();

        uint256 botAfter = IERC20(USDC).balanceOf(bot);
        uint256 fullFee6 = gasModel.estimateFeeUSDC6(gasUsed, tx.gasprice, 400);
        int256 net = int256(botAfter) - int256(botBefore) - int256(fullFee6);

        console.logUint(botAfter - botBefore);
        console.logUint(gasUsed);
        console.logUint(fullFee6);
        console.logInt(net);
        console.logUint(amm2.getAmountOut(1 ether, false));

        assertGt(net, 1_000_000, "appointed spread did not cover full Base gas");
        assertEq(usds.balanceOf(address(exec2)), 0, "executor left USDS dust");
        assertEq(eths.balanceOf(address(exec2)), 0, "executor left ETHS dust");
    }

    function _tryRound() internal returns (bool ok) {
        vm.prank(bot);
        try executor.executeExternalBuyInternalSell(20e6, 0.0078 ether, 19e18, 0, 1, block.timestamp)
            returns (uint256)
        {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _lpPoolDeltas(uint256 u0, uint256 e0, uint256 uni0)
        internal
        view
        returns (int256 intDelta, int256 poolDelta)
    {
        (uint256 uni1, uint256 u1, uint256 e1) = _extMark();
        intDelta = int256(u1) - int256(u0) + int256(e1 * 2500) - int256(e0 * 2500);
        poolDelta = int256(uni1) - int256(uni0);
    }

    /// @dev System = bot + internal LP (bridge is neutral). 10-round campaign,
    ///      full Base gas deducted. Proves OUR system is net profitable.
    function test_V2SystemLPPlusBot_CumulativeProfit() public {
        uint256 b0 = IERC20(USDC).balanceOf(bot);
        (uint256 uni0, uint256 u0, uint256 e0) = _extMark();
        uint256 gasStart = gasleft();
        uint256 rounds;
        while (rounds < 10) {
            if (!_tryRound()) break;
            rounds++;
        }
        uint256 gasUsed = gasStart - gasleft();
        uint256 b1 = IERC20(USDC).balanceOf(bot);
        (int256 intDelta, int256 poolDelta) = _lpPoolDeltas(u0, e0, uni0);
        int256 botDelta = int256(b1) - int256(b0);
        uint256 fullFee6 = new OPGasCostModelV2(address(oracle)).estimateFeeUSDC6(
            gasUsed, tx.gasprice, 400 * rounds
        );
        int256 systemNet = botDelta * 1e12 + intDelta - int256(fullFee6) * 1e12;

        console.logUint(rounds);
        console.logInt(botDelta);
        console.logInt(intDelta);
        console.logInt(poolDelta);
        console.logUint(fullFee6);
        console.logInt(systemNet);

        // Decay stop is EXPECTED: after 3 rounds the cross-venue spread narrows
        // below costs and the executor refuses round 4 with NotProfitable
        // instead of trading at a loss (measured at this pin/size).
        assertEq(rounds, 3, "unexpected decay point");
        assertApproxEqAbs(botDelta * 1e12 + intDelta + poolDelta, 0, 1e16, "conservation broken");
        assertGt(systemNet, 0, "system (bot+LP) not profitable");
    }

    function test_V2Executor_WrongDirectionReverts() public {
        vm.prank(bot);
        vm.expectRevert();
        executor.executeInternalBuyExternalSell(
            USDC_IN,
            0.007 ether,
            19e6,
            0,
            1,
            block.timestamp
        );
    }
}
