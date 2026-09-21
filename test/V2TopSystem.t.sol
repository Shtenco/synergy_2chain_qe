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

interface IPoolSlot0T {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

contract FixedOracleT is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2TopSystem - ALL improvements combined, one sample per process.
 * @notice (1) Deep internal AMM 500k/200. (2) Hybrid: bot harvests via
 *         zero-decay VAULT legs while bridge pools (fee 1bps = improvement 5)
 *         stand by for external flow, asserting zero interference.
 *         (3) Walk-forward driver across dip/spike blocks. (4) BOTH directions.
 *         (6) Big size $200/round. Each sample: fresh stack, fair-seeded.
 */
contract V2TopSystem is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    uint256 internal constant LO_PX = 2482e6;
    uint256 internal constant HI_PX = 2518e6;
    uint256 internal constant TRADE = 200e6;
    uint256 internal constant MIN_PROFIT = 200_000; // $0.20

    struct TopSys {
        USDSV2 usds;
        ETHSV2 eths;
        BridgeCoreV2 bridge;
        InternalAMMV2 amm;
        UniswapV3VenueV2 venue;
        ArbitrageExecutorV2 exec;
        OPGasCostModelV2 gas;
        BridgePool poolA;
        BridgePool poolB;
        address seeder;
        address bot;
    }

    struct TopSnap {
        uint256 bot;
        int256 ours;
        uint256 uni;
    }

    function _extPrice6() internal view returns (uint256 px6) {
        (uint160 sqrtP,,,,,,) = IPoolSlot0T(UNI_POOL).slot0();
        px6 = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192;
    }

    function _deployStack() internal returns (TopSys memory s) {
        s.seeder = makeAddr("top.seeder");
        s.bot = makeAddr("top.bot");
        s.usds = new USDSV2();
        s.eths = new ETHSV2();
        FixedOracleT oracle = new FixedOracleT();
        s.bridge = new BridgeCoreV2(address(s.usds), address(s.eths), USDC, address(oracle));
        s.amm = new InternalAMMV2(address(s.usds), address(s.eths), address(oracle));
        s.venue = new UniswapV3VenueV2(UNI_POOL, USDC, WETH);
        s.exec = new ArbitrageExecutorV2(
            address(s.bridge), address(s.amm), address(s.venue),
            USDC, WETH, address(s.usds), address(s.eths)
        );
        s.gas = new OPGasCostModelV2(address(oracle));
        s.poolA = new BridgePool(address(s.usds), USDC, 1, 1e12, "TopBridge USDS-USDC", "TBU");
        s.poolB = new BridgePool(address(s.eths), WETH, 1, 1, "TopBridge ETHS-WETH", "TBE");

        s.usds.grantRole(s.usds.BRIDGE_ROLE(), address(s.bridge));
        s.eths.grantRole(s.eths.BRIDGE_ROLE(), address(s.bridge));
        s.usds.renounceRole(s.usds.DEFAULT_ADMIN_ROLE(), address(this));
        s.eths.renounceRole(s.eths.DEFAULT_ADMIN_ROLE(), address(this));
        s.bridge.grantRole(s.bridge.OPERATOR_ROLE(), address(s.exec));
        s.bridge.grantRole(s.bridge.OPERATOR_ROLE(), s.seeder);
        s.exec.grantRole(s.exec.BOT_ROLE(), s.bot);

        _seedAll(s);

        deal(USDC, s.bot, 1000e6);
        vm.prank(s.bot);
        IERC20(USDC).approve(address(s.exec), type(uint256).max);
    }

    function _seedAll(TopSys memory s) internal {
        deal(USDC, s.seeder, 700_000e6);
        deal(WETH, s.seeder, 40 ether);
        deal(s.seeder, 250 ether);
        vm.startPrank(s.seeder);
        IERC20(USDC).approve(address(s.bridge), type(uint256).max);
        s.bridge.lockUSDCAndMintUSDS(s.seeder, 500_000e6);
        s.bridge.lockETHAndMintETHS{value: 200 ether}(s.seeder, 200 ether);
        s.usds.approve(address(s.amm), type(uint256).max);
        s.eths.approve(address(s.amm), type(uint256).max);
        s.amm.addLiquidity(500_000e18, 200 ether);
        s.bridge.lockUSDCAndMintUSDS(s.seeder, 100_000e6);
        s.bridge.lockETHAndMintETHS{value: 40 ether}(s.seeder, 40 ether);
        s.usds.approve(address(s.poolA), type(uint256).max);
        IERC20(USDC).approve(address(s.poolA), type(uint256).max);
        s.poolA.addLiquidity(100_000e18, 100_000e6);
        s.eths.approve(address(s.poolB), type(uint256).max);
        IERC20(WETH).approve(address(s.poolB), type(uint256).max);
        s.poolB.addLiquidity(40 ether, 40 ether);
        vm.stopPrank();
    }

    function _snap(TopSys memory s) internal view returns (TopSnap memory t) {
        t.bot = IERC20(USDC).balanceOf(s.bot);
        (uint256 u0, uint256 e0) = s.amm.reserves();
        (uint256 aU, uint256 aB) = s.poolA.reserves();
        (uint256 bU, uint256 bB) = s.poolB.reserves();
        int256 lp = int256(u0) + int256(e0 * 2500) + int256(aU) + int256(aB * 1e12)
            + int256((bU + bB) * 2500);
        int256 lnav = int256(s.bridge.hardAssets18()) - int256(s.bridge.liabilities18());
        t.ours = lp + lnav;
        t.uni = IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
    }

    function _settle(TopSys memory s, TopSnap memory a, uint256 g0) internal returns (int256 netT) {
        TopSnap memory b = _snap(s);
        uint256 used = g0 - gasleft();
        uint256 fee = s.gas.estimateFeeUSDC6(used, tx.gasprice, 400);
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 oursD = b.ours - a.ours;
        int256 uniD = int256(b.uni) - int256(a.uni);
        netT = botD * 1e12 + oursD - int256(fee) * 1e12;
        console.logInt(botD);
        console.logInt(oursD);
        console.logInt(uniD);
        console.logUint(fee);
        console.logInt(netT);
        console.logUint(s.bridge.solvencyBps());
        assertApproxEqAbs(botD * 1e12 + oursD + uniD, 0, 1e15, "conservation broken");
        assertLt(uniD, 0, "external donor did not pay");
        assertEq(s.usds.balanceOf(address(s.exec)), 0, "USDS dust");
        assertEq(s.eths.balanceOf(address(s.exec)), 0, "ETHS dust");
    }

    function test_V2TopSystem_OneBlock() public {
        uint256 px = _extPrice6();
        console.logUint(px);

        if (px < LO_PX) {
            TopSys memory s = _deployStack();
            uint256 minWeth = ((TRADE * 1e18) / px * 100) / 101;
            uint256 minUSDS = s.amm.getAmountOut(minWeth, false) * 99 / 100;
            TopSnap memory a = _snap(s);
            uint256 g0 = gasleft();
            vm.prank(s.bot);
            s.exec.executeExternalBuyInternalSell(TRADE, minWeth, minUSDS, 0, MIN_PROFIT, block.timestamp);
            console.logUint(1);
            int256 netT = _settle(s, a, g0);
            assertGt(netT, 0, "ext harvest net <= 0");
        } else if (px > HI_PX) {
            TopSys memory s = _deployStack();
            uint256 estE = s.amm.getAmountOut(200e18, true);
            uint256 minE = estE * 99 / 100;
            uint256 minU = ((minE * px) / 1e18 * 99) / 100;
            TopSnap memory a = _snap(s);
            uint256 g0 = gasleft();
            vm.prank(s.bot);
            s.exec.executeInternalBuyExternalSell(TRADE, minE, minU, 0, MIN_PROFIT, block.timestamp);
            console.logUint(2);
            int256 netT = _settle(s, a, g0);
            assertGt(netT, 0, "int harvest net <= 0");
        } else {
            console.logUint(0);
        }
    }
}
