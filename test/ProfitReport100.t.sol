// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/GradientControllerV2.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title ProfitReport100 - Full P&L statement from a $100 system seed, Base fork
 * @notice Starting capital (all counted in system books):
 *         $50 external — bot $5 operating + seeder $45 bridge backing (locked);
 *         $50 fork side — internal LP pool 25 USDS + 0.01 ETHS (50/50 @ 2500).
 *         Foreign $120M-scale pool is the market (excluded from books).
 *
 * Flow: 25 gated harvest rounds (spread gate + preview gate + backing gate),
 *       then the realized bot profit is settled through TreasuryDistributor
 *       (40/30/20/10). Every number below is measured on fork state —
 *       no estimates, no prints, no top-ups between BEFORE and AFTER.
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract ProfitReport100 -vv
 */
contract ProfitReport100 is Test {
    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    GradientControllerV2 public controller;
    TreasuryDistributor public treasury;
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
    address public whale;
    address public ownerWallet;
    address public bridgeReserve;
    address public insuranceFund;
    address public rebaseFund;

    uint256 public constant FAIR = 2500;
    uint256 public constant ONE = 1e18;
    uint256 public constant FWD = 2e13; // ~$0.05 per forward harvest
    uint256 public constant REV = 5e16; // ~$0.05 per reverse harvest
    uint256 public constant ROUNDS = 25;

    event BalanceSheet(string leg, uint256 botCash, uint256 bridgeReserveCash, uint256 poolValue, uint256 sysEquity);
    event RoundResult(uint256 indexed round, int256 gradient, uint8 mode, uint256 profit, int256 equityDelta);
    event TreasurySettled(uint256 total, uint256 ownerAmt, uint256 bridgeAmt, uint256 insuranceAmt, uint256 rebaseAmt);

    function setUp() public {
        admin = makeAddr("r100.admin");
        keeper = makeAddr("r100.keeper");
        seeder = makeAddr("r100.seeder");
        bot = makeAddr("r100.bot");
        lp = makeAddr("r100.lp");
        whale = makeAddr("r100.whale");
        ownerWallet = makeAddr("r100.owner");
        bridgeReserve = makeAddr("r100.bridgeReserve");
        insuranceFund = makeAddr("r100.insurance");
        rebaseFund = makeAddr("r100.rebase");

        fUSDC = new MockCanonicalToken();
        mWETH = new MockWETH9();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), address(fUSDC), address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        foreignPool = new ForeignPoolMock(address(fUSDC), address(mWETH));
        controller = new GradientControllerV2(address(oracle));
        treasury = new TreasuryDistributor(
            address(fUSDC), ownerWallet, bridgeReserve, insuranceFund, rebaseFund
        );

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), admin);
        oracle.grantRole(oracle.ALGO_CONTROLLER(), address(controller));
        controller.grantRole(controller.KEEPER_ROLE(), keeper);

        // $50 external leg.
        fUSDC.mint(seeder, 45 * ONE);
        fUSDC.mint(bot, 5 * ONE);
        vm.startPrank(seeder);
        fUSDC.approve(address(bridge), 45 * ONE);
        bridge.lockUSDCAndMintUSDS(seeder, 45 * ONE);
        vm.stopPrank();

        // $50 fork leg.
        usds.mint(lp, 25 * ONE);
        eths.mint(lp, 1e16);
        vm.startPrank(lp);
        usds.approve(address(amm), 25 * ONE);
        eths.approve(address(amm), 1e16);
        amm.addLiquidity(25 * ONE, 1e16);
        vm.stopPrank();

        // $120M foreign market (excluded).
        fUSDC.mint(whale, 60_000_000 * ONE);
        vm.deal(whale, 35_000 ether);
        vm.startPrank(whale);
        mWETH.deposit{value: 30_000 ether}();
        fUSDC.approve(address(foreignPool), 60_000_000 * ONE);
        mWETH.approve(address(foreignPool), 30_000 * ONE);
        foreignPool.seed(60_000_000 * ONE, 30_000 * ONE);
        vm.stopPrank();
    }

    /// @dev System EQUITY (synthetics = liabilities; treasury + recipients internal).
    function _sysEquity() internal view returns (uint256) {
        uint256 assets = fUSDC.balanceOf(address(bridge))
            + fUSDC.balanceOf(seeder)
            + fUSDC.balanceOf(bot)
            + fUSDC.balanceOf(lp)
            + fUSDC.balanceOf(address(treasury))
            + fUSDC.balanceOf(ownerWallet)
            + fUSDC.balanceOf(bridgeReserve)
            + fUSDC.balanceOf(insuranceFund)
            + fUSDC.balanceOf(rebaseFund)
            + mWETH.balanceOf(bot) * FAIR;
        uint256 ethAssets = (address(bridge).balance + bot.balance) * FAIR;
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
        vm.startPrank(bot);
        fUSDC.approve(address(bridge), x);
        bridge.lockUSDCAndMintUSDS(bot, x);
        usds.approve(address(amm), x);
        uint256 outE = amm.swap(x, true, 0);
        vm.stopPrank();
        vm.prank(bot);
        bridge.burnETHSAndUnlockETH(bot, outE);
        vm.startPrank(bot);
        mWETH.deposit{value: outE}();
        mWETH.approve(address(foreignPool), outE);
        received = foreignPool.swapEforU(outE);
        vm.stopPrank();
    }

    function test_ProfitReport_From100Dollars() public {
        uint256 eqStart = _sysEquity();
        uint256 forStart = _forVal();
        emit BalanceSheet(
            "START", fUSDC.balanceOf(bot), fUSDC.balanceOf(address(bridge)),
            amm.reserveUSDS() + amm.reserveETHS() * FAIR, eqStart
        );

        uint256 totalProfit;
        uint256 rounds;

        for (uint256 i = 0; i < ROUNDS; i++) {
            uint256 poolPx = _poolPx6d();
            uint256 forPx = _forPx6d();
            int256 spread = (int256(poolPx) - int256(forPx)) * 10000 / int256(forPx);

            vm.prank(keeper);
            (, uint8 mode) = controller.updateSpread(spread, block.timestamp);
            if (mode == 2) break; // converged

            uint256 eqBefore = _sysEquity();
            uint256 profit;

            if (mode == 1) {
                uint256 out = amm.getAmountOut(FWD, false);
                uint256 dx = _fwdDx(FWD);
                if (out <= dx) break;
                if (out > bridge.totalLockedUSDC()) break;
                if (out > fUSDC.balanceOf(address(bridge))) break;
                (uint256 received, uint256 paid) = _execFwd(FWD);
                profit = received - paid;
            } else {
                uint256 outE = amm.getAmountOut(REV, true);
                uint256 dxFee = outE * 997;
                uint256 outU = (dxFee * foreignPool.reserveU()) / (foreignPool.reserveE() * 1000 + dxFee);
                if (outU <= REV) break;
                if (fUSDC.balanceOf(bot) < REV) break;
                if (address(bridge).balance < outE) break;
                (uint256 received, uint256 paid) = _execRev(REV);
                profit = received - paid;
            }

            assertGt(profit, 0, "round harvested nothing");
            uint256 eqAfter = _sysEquity();
            assertGt(eqAfter, eqBefore, "system shrank this round");

            totalProfit += profit;
            rounds++;
            emit RoundResult(i + 1, oracle.getGradient(), mode, profit, int256(eqAfter) - int256(eqBefore));
        }

        // Treasury finale: settle the FULL realized bot profit 40/30/20/10.
        vm.prank(bot);
        fUSDC.transfer(address(treasury), totalProfit);
        treasury.distribute(totalProfit);
        (uint256 oAmt, uint256 bAmt, uint256 iAmt, uint256 rAmt) = treasury.previewDistribution(totalProfit);
        assertEq(fUSDC.balanceOf(ownerWallet), oAmt, "owner 40%");
        assertEq(fUSDC.balanceOf(bridgeReserve), bAmt, "bridge 30%");
        assertEq(fUSDC.balanceOf(insuranceFund), iAmt, "insurance 20%");
        assertEq(fUSDC.balanceOf(rebaseFund), rAmt, "rebase remainder");
        assertEq(treasury.totalDistributed(), totalProfit, "treasury books");
        emit TreasurySettled(totalProfit, oAmt, bAmt, iAmt, rAmt);

        uint256 eqEnd = _sysEquity();
        uint256 forEnd = _forVal();
        emit BalanceSheet(
            "END", fUSDC.balanceOf(bot), fUSDC.balanceOf(address(bridge)),
            amm.reserveUSDS() + amm.reserveETHS() * FAIR, eqEnd
        );

        assertEq(rounds, ROUNDS, "did not complete 25 rounds");
        assertGt(eqEnd, eqStart, "system did not grow on $100 seed");
        assertApproxEqAbs(eqEnd + forEnd, eqStart + forStart, 1e15, "conservation violated");
        assertLt(forEnd, forStart, "donor did not pay");

        console.logUint(rounds);
        console.logUint(totalProfit);
        console.logInt(int256(eqEnd) - int256(eqStart));
        console.logInt(int256(forEnd) - int256(forStart));
        console.logUint(eqStart);
        console.logUint(eqEnd);
    }
}
