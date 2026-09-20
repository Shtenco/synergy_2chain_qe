// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/GradientController.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title MicroHarvest25
 * @notice 25 harvest rounds with micro capital, on Base fork:
 *         $50 external (Base side: bot $5 operating + seeder $45 bridge backing)
 *         $50 fork side (internal LP pool: 25 USDS + 0.01 ETHS @ 2500).
 *         Foreign $100M-scale pool is the market (excluded from books).
 *
 * Each round: live quotes -> keeper updateSpread -> mode gate ->
 *             preview-profitability gate -> execute winner direction -> measure.
 *   mode OVERPRICE (internal rich) -> FORWARD: buy foreign, sell internal.
 *   mode UNDERPRICE (internal cheap) -> REVERSE: buy internal, sell foreign.
 *   mode NEUTRAL -> spread converged: stop, report horizon.
 *
 * No real funds move; everything executes on fork state. No broadcasts.
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract MicroHarvest25 -vv
 */
contract MicroHarvest25 is Test {
    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    GradientController public controller;
    USDS public usds;
    ETHS public eths;
    MockCanonicalToken public fUSDC;
    MockWETH9 public mWETH;
    ForeignPoolMock public foreignPool;

    address public admin;
    address public keeper;
    address public seeder;
    address public bot;
    address public lp;
    address public foreignWhale;

    uint256 public constant FAIR = 2500;
    uint256 public constant ONE = 1e18;
    uint256 public constant FWD = 2e13; // ~$0.05 of mWETH per forward harvest
    uint256 public constant REV = 5e16; // ~$0.05 of USDS per reverse harvest
    uint256 public constant ROUNDS = 25;

    function setUp() public {
        admin = makeAddr("micro.admin");
        keeper = makeAddr("micro.keeper");
        seeder = makeAddr("micro.seeder");
        bot = makeAddr("micro.bot");
        lp = makeAddr("micro.lp");
        foreignWhale = makeAddr("micro.whale");

        fUSDC = new MockCanonicalToken();
        mWETH = new MockWETH9();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), address(fUSDC), address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        foreignPool = new ForeignPoolMock(address(fUSDC), address(mWETH));
        controller = new GradientController(address(oracle));

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), admin);
        oracle.grantRole(oracle.ALGO_CONTROLLER(), address(controller));
        controller.grantRole(controller.KEEPER_ROLE(), keeper);

        // $50 external: $45 bridge backing (seeder locks) + $5 bot operating capital.
        fUSDC.mint(seeder, 45 * ONE);
        fUSDC.mint(bot, 5 * ONE);
        vm.startPrank(seeder);
        fUSDC.approve(address(bridge), 45 * ONE);
        bridge.lockUSDCAndMintUSDS(seeder, 45 * ONE);
        vm.stopPrank();

        // $50 fork side: internal LP pool 25 USDS + 0.01 ETHS (50/50 @ 2500).
        usds.mint(lp, 25 * ONE);
        eths.mint(lp, 1e16);
        vm.startPrank(lp);
        usds.approve(address(amm), 25 * ONE);
        eths.approve(address(amm), 1e16);
        amm.addLiquidity(25 * ONE, 1e16);
        vm.stopPrank();

        // Foreign market (excluded): 40M / 20k => ETH 2000.
        fUSDC.mint(foreignWhale, 60_000_000 * ONE);
        vm.deal(foreignWhale, 25_000 ether);
        vm.startPrank(foreignWhale);
        mWETH.deposit{value: 20_000 ether}();
        fUSDC.approve(address(foreignPool), 40_000_000 * ONE);
        mWETH.approve(address(foreignPool), 20_000 * ONE);
        foreignPool.seed(40_000_000 * ONE, 20_000 * ONE);
        vm.stopPrank();
    }

    /// @dev System EQUITY (synthetics = liabilities). Foreign pool excluded.
    function _sysEquity() internal view returns (uint256) {
        uint256 assets = fUSDC.balanceOf(address(bridge))
            + fUSDC.balanceOf(seeder)
            + fUSDC.balanceOf(bot)
            + fUSDC.balanceOf(lp)
            + mWETH.balanceOf(bot) * FAIR
            + mWETH.balanceOf(seeder) * FAIR
            + mWETH.balanceOf(lp) * FAIR;
        uint256 ethAssets = (address(bridge).balance + seeder.balance + bot.balance + lp.balance) * FAIR;
        uint256 poolAssets = amm.reserveUSDS() + amm.reserveETHS() * FAIR;
        uint256 liabilities = usds.totalSupply() + eths.totalSupply() * FAIR;
        return assets + ethAssets + poolAssets - liabilities;
    }

    function _forPx6d() internal view returns (uint256) {
        return (foreignPool.reserveU() * 1e6) / foreignPool.reserveE();
    }

    function _poolPx6d() internal view returns (uint256) {
        return (amm.reserveUSDS() * 1e6) / amm.reserveETHS();
    }

    function _forVal() internal view returns (uint256) {
        return foreignPool.reserveU() + foreignPool.reserveE() * FAIR;
    }

    function _fwdDx(uint256 out) internal view returns (uint256) {
        uint256 rU = foreignPool.reserveU();
        uint256 rE = foreignPool.reserveE();
        return (rU * 1000 * out) / (997 * (rE - out)) + 1;
    }

    function _execFwd(uint256 amount) internal returns (uint256 received, uint256 paid) {
        uint256 dx = _fwdDx(amount);
        vm.prank(bot);
        fUSDC.approve(address(foreignPool), type(uint256).max);
        vm.prank(bot);
        uint256 got = foreignPool.swapUforE(dx);
        assertGe(got, amount, "foreign leg underfilled");
        paid = dx;

        vm.startPrank(bot);
        mWETH.withdraw(got);
        bridge.lockETHAndMintETHS{value: got}(bot, got);
        eths.approve(address(amm), got);
        received = amm.swap(got, false, 0);
        vm.stopPrank();

        vm.prank(bot);
        bridge.burnUSDSAndUnlockUSDC(bot, received);
    }

    function _execRev(uint256 x) internal returns (uint256 received, uint256 paid) {
        paid = x;
        // 1. Lock fUSDC -> mint USDS.
        vm.startPrank(bot);
        fUSDC.approve(address(bridge), x);
        bridge.lockUSDCAndMintUSDS(bot, x);
        // 2. Buy cheap internal ETHS.
        usds.approve(address(amm), x);
        uint256 outE = amm.swap(x, true, 0);
        vm.stopPrank();
        // 3. Burn ETHS -> unlock native ETH.
        vm.prank(bot);
        bridge.burnETHSAndUnlockETH(bot, outE);
        // 4. Wrap and sell rich on the foreign market.
        vm.startPrank(bot);
        mWETH.deposit{value: outE}();
        mWETH.approve(address(foreignPool), outE);
        received = foreignPool.swapEforU(outE);
        vm.stopPrank();
    }

    function test_25Rounds_MicroCapital() public {
        uint256 eqStart = _sysEquity();
        uint256 forStart = _forVal();
        uint256 totalProfit;
        uint256 rounds;

        for (uint256 i = 0; i < ROUNDS; i++) {
            uint256 poolPx = _poolPx6d();
            uint256 forPx = _forPx6d();
            int256 spread = (int256(poolPx) - int256(forPx)) * 10000 / int256(forPx);

            vm.prank(keeper);
            (int256 g, uint8 mode) = controller.updateSpread(spread, block.timestamp);
            console.logInt(g);
            console.logUint(mode);

            if (mode == 2) break; // converged

            uint256 eqBefore = _sysEquity();
            uint256 profit;

            if (mode == 1) {
                // FORWARD preview: exact internal out vs exact foreign cost.
                uint256 out = amm.getAmountOut(FWD, false);
                uint256 dx = _fwdDx(FWD);
                if (out <= dx) break; // spread exhausted
                if (out > bridge.totalLockedUSDC()) break; // backing exhausted
                if (out > fUSDC.balanceOf(address(bridge))) break; // reserve exhausted
                (uint256 received, uint256 paid) = _execFwd(FWD);
                profit = received - paid;
            } else {
                // REVERSE preview.
                uint256 outE = amm.getAmountOut(REV, true);
                uint256 dxFee = outE * 997;
                uint256 outU = (dxFee * foreignPool.reserveU()) / (foreignPool.reserveE() * 1000 + dxFee);
                if (outU <= REV) break; // spread exhausted
                if (fUSDC.balanceOf(bot) < REV) break; // bot stake exhausted
                if (address(bridge).balance < outE) break; // native reserve exhausted
                (uint256 received, uint256 paid) = _execRev(REV);
                profit = received - paid;
            }

            assertGt(profit, 0, "round harvested nothing");
            uint256 eqAfter = _sysEquity();
            assertGt(eqAfter, eqBefore, "system shrank this round");

            totalProfit += profit;
            rounds++;
            console.logUint(profit);
            console.logInt(int256(eqAfter) - int256(eqBefore));
        }

        uint256 eqEnd = _sysEquity();
        uint256 forEnd = _forVal();
        console.logUint(rounds);
        console.logUint(totalProfit);
        console.logInt(int256(eqEnd) - int256(eqStart));
        console.logInt(int256(forEnd) - int256(forStart));

        assertEq(rounds, ROUNDS, "did not complete 25 rounds");
        assertGt(eqEnd, eqStart, "system did not grow over 25 rounds");
        assertLt(forEnd, forStart, "donor did not pay");
    }
}
