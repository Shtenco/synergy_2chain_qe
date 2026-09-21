// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/GradientControllerV2.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title V1Max500 - MAXIMUM profit on $500: blind bridge + mint pool.
 * @notice V1 BridgeCore tracks ONLY its own lock/mint counters, so the
 *         start-printed 500k/200 inventory is invisible to it (works where
 *         V2's global solvency reverts). Budget: $475 backing + $20 bot.
 *         Donor: appointed mock at 2000 (max edge). Dip block for realism.
 */
contract V1Max500 is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant GIANT = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    uint256 public constant ONE = 1e18;
    uint256 public constant TRADE = 9.9e15; // 0.0099 WETH ~= $20 all-in

    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    GradientControllerV2 public controller;
    USDS public usds;
    ETHS public eths;
    ForeignPoolMock public foreignPool;

    address public seeder;
    address public bot;
    address public lp;
    address public whale;
    address public keeper;

    function setUp() public {
        seeder = makeAddr("max.seeder");
        bot = makeAddr("max.bot");
        lp = makeAddr("max.lp");
        whale = makeAddr("max.whale");
        keeper = makeAddr("max.keeper");

        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), USDC, address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        foreignPool = new ForeignPoolMock(USDC, WETH);
        controller = new GradientControllerV2(address(oracle));

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        oracle.grantRole(oracle.ALGO_CONTROLLER(), address(controller));
        controller.grantRole(controller.KEEPER_ROLE(), keeper);

        // Backing $475 real USDC (the ONLY real money besides bot stake).
        vm.prank(GIANT);
        IERC20(USDC).transfer(seeder, 475 * 1e6);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), 475 * 1e6);
        bridge.lockUSDCAndMintUSDS(seeder, 475 * 1e6);
        vm.stopPrank();

        // Bot stake $20 real USDC.
        vm.prank(GIANT);
        IERC20(USDC).transfer(bot, 20 * 1e6);

        // MINT pool 500k/200 (blind to bridge counters).
        usds.mint(lp, 500_000 * ONE);
        eths.mint(lp, 200 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), 500_000 * ONE);
        eths.approve(address(amm), 200 * ONE);
        amm.addLiquidity(500_000 * ONE, 200 * ONE);
        vm.stopPrank();

        // Appointed donor @2000 (real tokens, mock curve).
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

    function _sysEquity() internal view returns (uint256) {
        uint256 assets = (IERC20(USDC).balanceOf(address(bridge)) + IERC20(USDC).balanceOf(seeder)
            + IERC20(USDC).balanceOf(bot) + IERC20(USDC).balanceOf(lp)) * 1e12
            + IERC20(WETH).balanceOf(bot) * 2500;
        uint256 ethAssets = (address(bridge).balance + bot.balance) * 2500;
        uint256 poolAssets = amm.reserveUSDS() + amm.reserveETHS() * 2500;
        uint256 liab = usds.totalSupply() + eths.totalSupply() * 2500;
        return assets + ethAssets + poolAssets - liab;
    }

    function _forVal() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(address(foreignPool)) * 1e12
            + IERC20(WETH).balanceOf(address(foreignPool)) * 2500;
    }

    function test_MaxProfit500() public {
        uint256 eqStart = _sysEquity();
        uint256 forStart = _forVal();
        uint256 botStart = IERC20(USDC).balanceOf(bot);
        uint256 totalProfit6;
        uint256 rounds;
        uint256 gasStart = gasleft();

        while (rounds < 25) {
            uint256 poolPx = (amm.reserveUSDS() * 1e6) / amm.reserveETHS();
            uint256 forPx = (foreignPool.reserveU() * 1e18) / foreignPool.reserveE();
            int256 spread = (int256(poolPx) - int256(forPx)) * 10000 / int256(forPx);
            vm.prank(keeper);
            (, uint8 mode) = controller.updateSpread(spread, block.timestamp);
            if (mode != 1) break;
            uint256 rU = foreignPool.reserveU();
            uint256 rE = foreignPool.reserveE();
            uint256 dx = (rU * 1000 * TRADE) / (997 * (rE - TRADE)) + 1;
            uint256 out = amm.getAmountOut(TRADE, false);
            if (out / 1e12 <= dx) break;
            if (out > bridge.totalLockedUSDC()) break;

            uint256 botB = IERC20(USDC).balanceOf(bot);
            vm.startPrank(bot);
            IERC20(USDC).approve(address(foreignPool), dx);
            uint256 got = foreignPool.swapUforE(dx);
            MockWETH9(payable(WETH)).withdraw(got);
            bridge.lockETHAndMintETHS{value: got}(bot, got);
            eths.approve(address(amm), got);
            uint256 usdsOut = amm.swap(got, false, 0);
            vm.stopPrank();
            vm.prank(bot);
            bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);
            uint256 profit6 = IERC20(USDC).balanceOf(bot) - botB;
            if (profit6 == 0) break;
            totalProfit6 += profit6;
            rounds++;
        }
        uint256 gasUsed = gasStart - gasleft();

        uint256 eqEnd = _sysEquity();
        uint256 forEnd = _forVal();
        uint256 botProfit6 = IERC20(USDC).balanceOf(bot) - botStart;
        console.logUint(rounds);
        console.logUint(totalProfit6);
        console.logUint(botProfit6);
        console.logInt(int256(eqEnd) - int256(eqStart));
        console.logInt(int256(forEnd) - int256(forStart));
        console.logUint(gasUsed);
        console.logUint(IERC20(USDC).balanceOf(bot));
        console.logUint(IERC20(USDC).balanceOf(address(bridge)));

        assertGe(rounds, 10, "max campaign stopped early");
        assertGt(botProfit6, 0, "bot did not profit");
        assertEq(totalProfit6, botProfit6, "profit accounting");
        assertGt(eqEnd, eqStart, "system did not grow");
        assertLt(forEnd, forStart, "donor did not pay");
    }
}
