// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/GradientControllerV2.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/ArbitrageExecutor.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/**
 * @title NativeUsdcHarvest - Harvest on REAL Base USDC (6d) + REAL WETH, Base fork
 * @notice Answers: "what about native USDC?" All prior tests used an 18-decimal
 *         mock as canonical. Here every canonical leg is the real token contract
 *         on fork state:
 *           USDC  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 (6 decimals, Circle docs)
 *           WETH  0x4200000000000000000000000000000000000006 (18 decimals)
 *         Funding faucet = the giant V3 pool itself
 *         (0x6c561B446416e1a00e8e93E221854d6eA4171372, ~$109.5M at pinned block):
 *         pranked transfers, no balance cheatcodes, no mints of canonical.
 *         The stale donor curve is still simulated (the experimental treatment);
 *         the TOKENS are real. Honest disclosures: Circle blacklist/pause risk
 *         applies to real USDC (not triggered here); canonical can only be
 *         locked/unlocked, never minted (system complies by construction).
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract NativeUsdcHarvest -vv
 */
contract NativeUsdcHarvest is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant GIANT = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    GradientControllerV2 public controller;
    USDS public usds;
    ETHS public eths;
    ForeignPoolMock public foreignPool;

    address public admin;
    address public keeper;
    address public seeder;
    address public bot;
    address public lp;
    address public whale;

    uint256 public constant FAIR = 2500;
    uint256 public constant ONE = 1e18;
    uint256 public constant TRADE = 8e15; // 0.008 WETH per round
    uint256 public constant ROUNDS = 3;

    /// @dev 18-dec normalized dollars: USDC6 x1e12, ETH/WETH/USDS/ETHS x price.
    function _nUsdc(uint256 raw6) internal pure returns (uint256) {
        return raw6 * 1e12;
    }

    function _sysEquity() internal view returns (uint256) {
        uint256 assets = _nUsdc(IERC20(USDC).balanceOf(address(bridge)))
            + _nUsdc(IERC20(USDC).balanceOf(seeder))
            + _nUsdc(IERC20(USDC).balanceOf(bot))
            + _nUsdc(IERC20(USDC).balanceOf(lp))
            + IERC20(WETH).balanceOf(bot) * FAIR;
        uint256 ethAssets = (address(bridge).balance + bot.balance) * FAIR;
        uint256 poolAssets = amm.reserveUSDS() + amm.reserveETHS() * FAIR;
        uint256 liabilities = usds.totalSupply() + eths.totalSupply() * FAIR;
        return assets + ethAssets + poolAssets - liabilities;
    }

    function _forVal() internal view returns (uint256) {
        return _nUsdc(IERC20(USDC).balanceOf(address(foreignPool)))
            + IERC20(WETH).balanceOf(address(foreignPool)) * FAIR;
    }

    function setUp() public {
        admin = makeAddr("nativ.admin");
        keeper = makeAddr("nativ.keeper");
        seeder = makeAddr("nativ.seeder");
        bot = makeAddr("nativ.bot");
        lp = makeAddr("nativ.lp");
        whale = makeAddr("nativ.whale");

        // Real token sanity (fail fast if the fork/addresses are wrong).
        assertEq(IERC20Decimals(USDC).decimals(), 6, "USDC must be 6-decimal");
        assertEq(IERC20Decimals(WETH).decimals(), 18, "WETH must be 18-decimal");

        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), USDC, address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        // MockWETH9-typed handle over REAL WETH: only transfer()/withdraw() used,
        // selectors identical to canonical WETH.
        foreignPool = new ForeignPoolMock(USDC, WETH);
        controller = new GradientControllerV2(address(oracle));

        // The 6-decimal path must be active (decimals audit, executed for real).
        assertEq(bridge.usdcDecimals(), 6, "bridge must detect 6 decimals");
        assertEq(bridge.usdcScale(), 1e12, "bridge scale must be 1e12");

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), admin);
        oracle.grantRole(oracle.ALGO_CONTROLLER(), address(controller));
        controller.grantRole(controller.KEEPER_ROLE(), keeper);

        // Faucet = giant pool's own balances (pranked transfers, no mints).
        // Seeder backing: 150k real USDC.
        vm.prank(GIANT);
        IERC20(USDC).transfer(seeder, 150_000 * 1e6);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), 150_000 * 1e6);
        bridge.lockUSDCAndMintUSDS(seeder, 150_000 * 1e6);
        vm.stopPrank();
        // Backing totals MUST be 18-dec normalized (150k -> 1.5e23).
        assertEq(bridge.totalLockedUSDC(), 150_000 * ONE, "locked totals normalized");
        assertEq(bridge.totalMintedUSDS(), 150_000 * ONE, "minted totals normalized");
        assertEq(usds.balanceOf(seeder), 150_000 * ONE, "seeder got 18d USDS for 6d USDC");

        // Bot stake: $500 real USDC.
        vm.prank(GIANT);
        IERC20(USDC).transfer(bot, 500 * 1e6);

        // Fair internal pool (synthetics, minted): 500k / 200 @ 2500.
        usds.mint(lp, 500_000 * ONE);
        eths.mint(lp, 200 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), 500_000 * ONE);
        eths.approve(address(amm), 200 * ONE);
        amm.addLiquidity(500_000 * ONE, 200 * ONE);
        vm.stopPrank();

        // Stale donor (real tokens!): 40M USDC + 20k WETH @ 2000, from the giant.
        vm.prank(GIANT);
        IERC20(USDC).transfer(whale, 40_000_000 * 1e6);
        vm.prank(GIANT);
        IERC20(WETH).transfer(whale, 20_000 * ONE);
        vm.startPrank(whale);
        IERC20(USDC).approve(address(foreignPool), 40_000_000 * 1e6);
        IERC20(WETH).approve(address(foreignPool), 20_000 * ONE);
        foreignPool.seed(40_000_000 * 1e6, 20_000 * ONE);
        vm.stopPrank();
    }

    /// @dev V2 gate + exact foreign cost for TRADE. Returns (mode, dx).
    /// @dev Donor quote uses x1e18: the foreign pool holds REAL 6-decimal USDC,
    ///      so (reserveU_6d x 1e18 / reserveE_18d) is the 6-dec price. The 18d
    ///      formula (x1e6) truncates to ZERO here and panics on divide-by-zero.
    function _gateQuote() internal returns (uint8 mode, uint256 dx) {
        uint256 poolPx = (amm.reserveUSDS() * 1e6) / amm.reserveETHS();
        uint256 forPx = (foreignPool.reserveU() * 1e18) / foreignPool.reserveE();
        int256 spread = (int256(poolPx) - int256(forPx)) * 10000 / int256(forPx);
        vm.prank(keeper);
        (, mode) = controller.updateSpread(spread, block.timestamp);
        uint256 rU = foreignPool.reserveU();
        uint256 rE = foreignPool.reserveE();
        dx = (rU * 1000 * TRADE) / (997 * (rE - TRADE)) + 1;
    }

    /// @dev Execute one round on real tokens. Returns realized 6-dec profit.
    function _execRound(uint256 dx, uint256 botB) internal returns (uint256 profit6) {
        vm.startPrank(bot);
        IERC20(USDC).approve(address(foreignPool), dx);
        // 1. Buy real WETH on the donor with real USDC.
        uint256 got = foreignPool.swapUforE(dx);
        // 2. Unwrap REAL WETH -> native ETH.
        MockWETH9(payable(WETH)).withdraw(got);
        // 3. Lock native ETH -> mint ETHS.
        bridge.lockETHAndMintETHS{value: got}(bot, got);
        // 4. Sell ETHS internally -> USDS.
        eths.approve(address(amm), got);
        uint256 usdsOut = amm.swap(got, false, 0);
        vm.stopPrank();
        // 5. Burn USDS -> unlock REAL 6-dec USDC (floor dust documented).
        uint256 usdcBefore = IERC20(USDC).balanceOf(bot);
        vm.prank(bot);
        bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);
        uint256 received = IERC20(USDC).balanceOf(bot) - usdcBefore;
        assertEq(received, usdsOut / 1e12, "payout must be 6-dec floor of 18d burn");
        profit6 = IERC20(USDC).balanceOf(bot) - botB;
    }

    function test_NativeUsdc_ThreeHarvestRounds() public {
        uint256 eqStart = _sysEquity();
        uint256 forStart = _forVal();
        uint256 botStart = IERC20(USDC).balanceOf(bot);
        uint256 totalProfit6;

        for (uint256 i = 0; i < ROUNDS; i++) {
            (uint8 mode, uint256 dx) = _gateQuote();
            require(mode == 1, "gate closed");
            // Preview in common units: 18d internal out vs 6d foreign cost.
            uint256 out = amm.getAmountOut(TRADE, false);
            require(out / 1e12 > dx, "spread exhausted");
            require(out <= bridge.totalLockedUSDC(), "backing exhausted");

            uint256 eqB = _sysEquity();
            uint256 profit6 = _execRound(dx, IERC20(USDC).balanceOf(bot));
            assertGt(profit6, 0, "round harvested nothing real");
            totalProfit6 += profit6;

            uint256 eqA = _sysEquity();
            assertGt(eqA, eqB, "equity fell");
            console.logUint(profit6);
            console.logInt(int256(eqA) - int256(eqB));
        }

        uint256 eqEnd = _sysEquity();
        uint256 forEnd = _forVal();
        uint256 botProfit6 = IERC20(USDC).balanceOf(bot) - botStart;
        console.logUint(totalProfit6);
        console.logUint(botProfit6);
        console.logInt(int256(eqEnd) - int256(eqStart));
        console.logInt(int256(forEnd) - int256(forStart));

        assertEq(totalProfit6, botProfit6, "profit accounting");
        assertGt(eqEnd, eqStart, "system did not grow on native USDC");
        assertApproxEqAbs(eqEnd + forEnd, eqStart + forStart, 1e16, "conservation violated");
        assertLt(forEnd, forStart, "donor did not pay");
    }

    /// @dev One fully-gated round on real tokens. Returns (executed, profit6, eqDelta).
    function _oneRound() internal returns (bool executed, uint256 profit6, int256 eqDelta) {
        (uint8 mode, uint256 dx) = _gateQuote();
        if (mode != 1) return (false, 0, 0);
        uint256 out = amm.getAmountOut(TRADE, false);
        if (out / 1e12 <= dx) return (false, 0, 0);
        if (out > bridge.totalLockedUSDC()) return (false, 0, 0);
        uint256 eqB = _sysEquity();
        profit6 = _execRound(dx, IERC20(USDC).balanceOf(bot));
        if (profit6 == 0) return (false, 0, 0);
        uint256 eqA = _sysEquity();
        eqDelta = int256(eqA) - int256(eqB);
        executed = true;
    }

    function test_NativeUsdc_TwentyRounds() public {
        uint256 eqStart = _sysEquity();
        uint256 forStart = _forVal();
        uint256 totalProfit6;
        uint256 rounds;

        for (uint256 i = 0; i < 20; i++) {
            (bool executed, uint256 profit6, int256 eqDelta) = _oneRound();
            if (!executed) break;
            require(profit6 > 0, "round harvested nothing real");
            require(eqDelta > 0, "equity fell");
            totalProfit6 += profit6;
            rounds++;
            console.logUint(profit6);
            console.logInt(eqDelta);
        }

        uint256 eqEnd = _sysEquity();
        uint256 forEnd = _forVal();
        console.logUint(rounds);
        console.logUint(totalProfit6);
        console.logInt(int256(eqEnd) - int256(eqStart));
        console.logInt(int256(forEnd) - int256(forStart));
        console.logUint(IERC20(USDC).balanceOf(bot));
        console.logUint(IERC20(USDC).balanceOf(address(bridge)));

        assertEq(rounds, 20, "did not complete 20 rounds on native USDC");
        assertGt(eqEnd, eqStart, "system did not grow on native USDC");
        assertApproxEqAbs(eqEnd + forEnd, eqStart + forStart, 1e16, "conservation violated");
        assertLt(forEnd, forStart, "donor did not pay");
    }

    function test_ExecutorScalesToSixDecimals() public {
        address oW = makeAddr("nativ.o");
        address bW = makeAddr("nativ.b");
        address iW = makeAddr("nativ.i");
        address rW = makeAddr("nativ.r");
        TreasuryDistributor treasury =
            new TreasuryDistributor(USDC, oW, bW, iW, rW);
        ArbitrageExecutor executor = new ArbitrageExecutor(
            address(bridge), address(amm), address(treasury), address(oracle),
            USDC, WETH, address(usds), address(eths)
        );
        assertEq(executor.usdcScale(), 1e12, "executor must detect 6 decimals");

        // The TEST contract holds ALGO_CONTROLLER from oracle deployment
        // (admin does not), so it sets the gradient itself.
        oracle.setGradient(-500); // UNDERPRICE, internal 2375 vs ext 2500
        (bool ok, uint256 est) = executor.isCycleAProfitable(10 * ONE);
        assertTrue(ok, "must flag profitable");
        // spread 125e6 x 10 ETH, in 6-dec USDC units: 10 * 125e6 = 1.25e9 ($1,250).
        assertEq(est, 1_250_000_000, "estimate must be 6-dec token units");
    }
}
