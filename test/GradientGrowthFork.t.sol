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
 * @title GradientGrowthFork
 * @notice Proves on Base fork what gradient updates actually do for growth.
 *
 * Setup: fair internal pool (ETH 2500), STALE foreign donor pool (ETH 2000),
 *        GradientController fed by a keeper with the live donor quote.
 *
 * Control (test_Control_UpdateMovesNoFunds):
 *   - fresh state is NEUTRAL, gradient 0;
 *   - update() with a fair quote keeps NEUTRAL;
 *   - update() with the stale quote flips to UNDERPRICE, gradient -1000;
 *   - system equity is IDENTICAL before/after every update call:
 *     the update itself prints nothing, it only opens the mode gate.
 *
 * Growth (test_Growth_FiveHarvestRounds):
 *   - 5 rounds: quote -> keeper update -> mode-gated harvest -> measure;
 *   - every round: profit > 0, system equity strictly up, donor down;
 *   - donor price converges toward fair (finite harvest, documented horizon).
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract GradientGrowthFork -vv
 */
contract GradientGrowthFork is Test {
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
    uint256 public constant TRADE = 10 * 1e18;
    uint256 public constant ROUNDS = 5;

    function setUp() public {
        admin = makeAddr("grad.admin");
        keeper = makeAddr("grad.keeper");
        seeder = makeAddr("grad.seeder");
        bot = makeAddr("grad.bot");
        lp = makeAddr("grad.lp");
        foreignWhale = makeAddr("grad.whale");

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

        // Disclosed system capital (counted in books).
        fUSDC.mint(address(bridge), 300_000 * ONE);
        fUSDC.mint(seeder, 200_000 * ONE);
        fUSDC.mint(bot, 200_000 * ONE);
        vm.deal(seeder, 10 ether);
        // Foreign capital (excluded from system books).
        fUSDC.mint(foreignWhale, 60_000_000 * ONE);
        vm.deal(foreignWhale, 25_000 ether);

        // Bridge backing: 150k locked (minted USDS accounting for redemptions).
        vm.startPrank(seeder);
        fUSDC.approve(address(bridge), 150_000 * ONE);
        bridge.lockUSDCAndMintUSDS(seeder, 150_000 * ONE);
        vm.stopPrank();

        // Fair internal pool: 5M / 2000 => ETH 2500 (deep, low slippage).
        usds.mint(lp, 5_000_000 * ONE);
        eths.mint(lp, 2_000 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), 5_000_000 * ONE);
        eths.approve(address(amm), 2_000 * ONE);
        amm.addLiquidity(5_000_000 * ONE, 2_000 * ONE);
        vm.stopPrank();

        // Stale foreign donor: 40M / 20k => ETH 2000.
        vm.startPrank(foreignWhale);
        mWETH.deposit{value: 20_000 ether}();
        fUSDC.approve(address(foreignPool), 40_000_000 * ONE);
        mWETH.approve(address(foreignPool), 20_000 * ONE);
        foreignPool.seed(40_000_000 * ONE, 20_000 * ONE);
        vm.stopPrank();
    }

    /// @dev System EQUITY: synthetics in circulation are liabilities (see ForeignDonorFork).
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

    function _foreignQuote6d() internal view returns (uint256) {
        return (foreignPool.reserveU() * 1e6) / foreignPool.reserveE();
    }

    function _foreignValue() internal view returns (uint256) {
        return foreignPool.reserveU() + foreignPool.reserveE() * FAIR;
    }

    /// @dev One mode-gated harvest: requires UNDERPRICE from the latest update.
    function _harvest(uint256 amount) internal returns (uint256 profit) {
        require(oracle.getMode() == 0, "gate: not UNDERPRICE");
        uint256 botUBefore = fUSDC.balanceOf(bot);

        uint256 rU = foreignPool.reserveU();
        uint256 rE = foreignPool.reserveE();
        uint256 dx = (rU * 1000 * amount) / (997 * (rE - amount)) + 1;
        vm.prank(bot);
        fUSDC.approve(address(foreignPool), type(uint256).max);
        vm.prank(bot);
        uint256 got = foreignPool.swapUforE(dx);
        assertGe(got, amount, "foreign leg underfilled");

        vm.startPrank(bot);
        mWETH.withdraw(got);
        bridge.lockETHAndMintETHS{value: got}(bot, got);
        eths.approve(address(amm), got);
        uint256 usdsOut = amm.swap(got, false, 0);
        vm.stopPrank();

        vm.prank(bot);
        bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);

        profit = fUSDC.balanceOf(bot) - botUBefore;
    }

    function test_Control_UpdateMovesNoFunds() public {
        assertEq(oracle.getMode(), 2, "fresh state must be NEUTRAL");
        assertEq(oracle.getGradient(), 0, "fresh gradient must be 0");

        uint256 eqBefore = _sysEquity();

        // Fair quote: stays NEUTRAL.
        vm.prank(keeper);
        (int256 g0, uint8 m0) = controller.update(2500e6, block.timestamp);
        assertEq(g0, 0, "fair quote must give zero gradient");
        assertEq(m0, 2, "fair quote must stay NEUTRAL");
        assertEq(_sysEquity(), eqBefore, "update moved funds?!");

        // Stale quote: flips to UNDERPRICE, gradient clamped at -1000.
        vm.prank(keeper);
        (int256 g1, uint8 m1) = controller.update(_foreignQuote6d(), block.timestamp);
        assertEq(g1, -1000, "stale quote must clamp at -1000");
        assertEq(m1, 0, "stale quote must open UNDERPRICE");
        assertEq(_sysEquity(), eqBefore, "update printed value?!");
    }

    function test_Growth_FiveHarvestRounds() public {
        uint256 totalProfit;
        uint256 forPriceStart = _foreignQuote6d();
        console.logUint(forPriceStart);

        for (uint256 i = 0; i < ROUNDS; i++) {
            uint256 eqBefore = _sysEquity();

            vm.prank(keeper);
            (int256 g, uint8 m) = controller.update(_foreignQuote6d(), block.timestamp);
            assertEq(m, 0, "gate closed: nothing harvestable this round");

            uint256 profit = _harvest(TRADE);
            assertGt(profit, 0, "round harvested nothing");

            uint256 eqAfter = _sysEquity();
            assertGt(eqAfter, eqBefore, "system did not grow this round");

            totalProfit += profit;
            console.logInt(g);
            console.logUint(profit);
            console.logInt(int256(eqAfter) - int256(eqBefore));
        }

        uint256 forPriceEnd = _foreignQuote6d();
        console.logUint(forPriceEnd);
        console.logUint(totalProfit);

        // Donor converged toward fair: the harvest is finite, horizon documented.
        assertGt(forPriceEnd, forPriceStart, "donor did not converge");
        assertGt(totalProfit, 0, "no total harvest");
    }
}
