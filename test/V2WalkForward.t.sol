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

interface IPoolSlot0W {
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

contract FixedOracleW is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2WalkForward - ONE historical block per process (no vm.rollFork:
 *         the pinned forge build crashes rolling Base forks across Isthmus).
 * @notice Driver launches one process per block with --fork-block-number.
 *         Each sample: read REAL pool price -> deploy FRESH fair-seeded V2
 *         system -> fire the side the market offers or skip -> log net.
 */
contract V2WalkForward is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    // Bands ~= +/-0.72% around fair: edge must clear ~0.6% two-side fees +
    // gas before the executor's $0.02 minProfit gate even matters.
    uint256 internal constant LO_PX = 2482e6;
    uint256 internal constant HI_PX = 2518e6;
    uint256 internal constant TRADE = 20e6;
    uint256 internal constant MIN_PROFIT = 20_000; // $0.02 > full gas

    struct BlockSys {
        USDSV2 usds;
        ETHSV2 eths;
        BridgeCoreV2 bridge;
        InternalAMMV2 amm;
        UniswapV3VenueV2 venue;
        ArbitrageExecutorV2 exec;
        OPGasCostModelV2 gas;
        address seeder;
        address bot;
    }

    struct ExeSnap {
        uint256 bot;
        uint256 rU;
        uint256 rE;
    }

    /// @dev P_raw = USDCraw/WETHraw per wei = sqrtP^2/2^192. 6d USDC per whole
    ///      WETH = P_raw x 1e18. (A 1e12 factor here once understated prices
    ///      by 1e6 and sent the router down the wrong branch.)
    function _extPrice6() internal view returns (uint256 px6) {
        (uint160 sqrtP,,,,,,) = IPoolSlot0W(UNI_POOL).slot0();
        px6 = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192;
    }

    function _deployStack() internal returns (BlockSys memory s) {
        s.seeder = makeAddr("wf.seeder");
        s.bot = makeAddr("wf.bot");
        s.usds = new USDSV2();
        s.eths = new ETHSV2();
        FixedOracleW oracle = new FixedOracleW();
        s.bridge = new BridgeCoreV2(address(s.usds), address(s.eths), USDC, address(oracle));
        s.amm = new InternalAMMV2(address(s.usds), address(s.eths), address(oracle));
        s.venue = new UniswapV3VenueV2(UNI_POOL, USDC, WETH);
        s.exec = new ArbitrageExecutorV2(
            address(s.bridge), address(s.amm), address(s.venue),
            USDC, WETH, address(s.usds), address(s.eths)
        );
        s.gas = new OPGasCostModelV2(address(oracle));

        s.usds.grantRole(s.usds.BRIDGE_ROLE(), address(s.bridge));
        s.eths.grantRole(s.eths.BRIDGE_ROLE(), address(s.bridge));
        s.usds.renounceRole(s.usds.DEFAULT_ADMIN_ROLE(), address(this));
        s.eths.renounceRole(s.eths.DEFAULT_ADMIN_ROLE(), address(this));
        s.bridge.grantRole(s.bridge.OPERATOR_ROLE(), address(s.exec));
        s.bridge.grantRole(s.bridge.OPERATOR_ROLE(), s.seeder);
        s.exec.grantRole(s.exec.BOT_ROLE(), s.bot);

        deal(USDC, s.seeder, 60_000e6);
        deal(s.seeder, 25 ether);
        vm.startPrank(s.seeder);
        IERC20(USDC).approve(address(s.bridge), type(uint256).max);
        s.bridge.lockUSDCAndMintUSDS(s.seeder, 50_000e6);
        s.bridge.lockETHAndMintETHS{value: 20 ether}(s.seeder, 20 ether);
        s.usds.approve(address(s.amm), type(uint256).max);
        s.eths.approve(address(s.amm), type(uint256).max);
        s.amm.addLiquidity(50_000e18, 20 ether);
        vm.stopPrank();

        deal(USDC, s.bot, 500e6);
        vm.prank(s.bot);
        IERC20(USDC).approve(address(s.exec), type(uint256).max);
    }

    function _snap(BlockSys memory s) internal view returns (ExeSnap memory t) {
        t.bot = IERC20(USDC).balanceOf(s.bot);
        (t.rU, t.rE) = s.amm.reserves();
    }

    /// @dev Settlement: bot delta + internal-LP delta - full Base gas.
    function _settle(BlockSys memory s, ExeSnap memory a, uint256 g0) internal returns (int256 netT) {
        ExeSnap memory b = _snap(s);
        uint256 used = g0 - gasleft();
        uint256 fee = s.gas.estimateFeeUSDC6(used, tx.gasprice, 400);
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 lpD = int256(b.rU) - int256(a.rU) + int256(b.rE * 2500) - int256(a.rE * 2500);
        netT = botD * 1e12 + lpD - int256(fee) * 1e12;
        console.logInt(botD);
        console.logInt(lpD);
        console.logUint(fee);
        console.logInt(netT);
    }

    function test_V2WalkForward_OneBlock() public {
        uint256 px = _extPrice6();
        console.logUint(px);

        if (px < LO_PX) {
            BlockSys memory s = _deployStack();
            uint256 minWeth = ((TRADE * 1e18) / px * 100) / 101;
            uint256 minUSDS = s.amm.getAmountOut(minWeth, false) * 99 / 100;
            ExeSnap memory a = _snap(s);
            uint256 g0 = gasleft();
            vm.prank(s.bot);
            s.exec.executeExternalBuyInternalSell(TRADE, minWeth, minUSDS, 0, MIN_PROFIT, block.timestamp);
            console.logUint(1);
            int256 netT = _settle(s, a, g0);
            assertGt(netT, 0, "ext harvest net <= 0");
        } else if (px > HI_PX) {
            BlockSys memory s = _deployStack();
            uint256 estE = s.amm.getAmountOut(20e18, true);
            uint256 minE = estE * 99 / 100;
            uint256 minU = ((minE * px) / 1e18 * 99) / 100;
            ExeSnap memory a = _snap(s);
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
