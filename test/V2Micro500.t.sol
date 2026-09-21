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

interface IPoolSlot0M {
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

contract FixedOracleM is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2Micro500 - blueprint B: $500 total, fully backed, spike block.
 * @notice AMM $90/side ($180) + backing buffer $300 + bot $20 = $500.
 *         All inventory via 1:1 locks (solvency 100% by construction).
 *         INT direction (external rich): lock $2 -> buy cheap ETHS internally
 *         -> sell WETH on real pool. Predicted +$0.014/round.
 */
contract V2Micro500 is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    USDSV2 internal usds;
    ETHSV2 internal eths;
    FixedOracleM internal oracle;
    BridgeCoreV2 internal bridge;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    ArbitrageExecutorV2 internal exec;
    OPGasCostModelV2 internal gasModel;
    address internal seeder;
    address internal bot;

    struct MSnap {
        uint256 bot;
        int256 ours;
        uint256 uni;
    }

    function _extPrice6() internal view returns (uint256 px6) {
        (uint160 sqrtP,,,,,,) = IPoolSlot0M(UNI_POOL).slot0();
        px6 = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192;
    }

    function setUp() public {
        seeder = makeAddr("mi.seeder");
        bot = makeAddr("mi.bot");
        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOracleM();
        bridge = new BridgeCoreV2(address(usds), address(eths), USDC, address(oracle));
        amm = new InternalAMMV2(address(usds), address(eths), address(oracle));
        venue = new UniswapV3VenueV2(UNI_POOL, USDC, WETH);
        exec = new ArbitrageExecutorV2(
            address(bridge), address(amm), address(venue),
            USDC, WETH, address(usds), address(eths)
        );
        gasModel = new OPGasCostModelV2(address(oracle));

        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        usds.renounceRole(usds.DEFAULT_ADMIN_ROLE(), address(this));
        eths.renounceRole(eths.DEFAULT_ADMIN_ROLE(), address(this));
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(exec));
        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        exec.grantRole(exec.BOT_ROLE(), bot);

        deal(USDC, seeder, 400e6);
        deal(seeder, 1 ether);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, 90e6);
        bridge.lockETHAndMintETHS{value: 0.036 ether}(seeder, 0.036 ether);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(90e18, 0.036 ether);
        bridge.lockUSDCAndMintUSDS(seeder, 300e6);
        vm.stopPrank();

        deal(USDC, bot, 20e6);
        vm.prank(bot);
        IERC20(USDC).approve(address(exec), type(uint256).max);
    }

    function _snap() internal view returns (MSnap memory t) {
        t.bot = IERC20(USDC).balanceOf(bot);
        (uint256 rU, uint256 rE) = amm.reserves();
        int256 lnav = int256(bridge.hardAssets18()) - int256(bridge.liabilities18());
        t.ours = int256(rU) + int256(rE * 2500) + lnav;
        t.uni = IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
    }

    function _tryInt(uint256 px) internal returns (bool ok) {
        uint256 estE = amm.getAmountOut(2e18, true);
        uint256 minE = (estE * 99) / 100;
        uint256 minU = ((minE * px) / 1e18 * 99) / 100;
        vm.prank(bot);
        try exec.executeInternalBuyExternalSell(2e6, minE, minU, 0, 5_000, block.timestamp)
            returns (uint256)
        {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function test_Micro500_SpikeHarvest() public {
        uint256 px = _extPrice6();
        console.logUint(px);
        require(px > 2518e6, "not a spike block for INT route");

        MSnap memory s0 = _snap();
        uint256 gasStart = gasleft();
        uint256 rounds;
        while (rounds < 10) {
            if (!_tryInt(px)) break;
            rounds++;
        }
        uint256 gasUsed = gasStart - gasleft();
        MSnap memory s1 = _snap();

        int256 botD = int256(s1.bot) - int256(s0.bot);
        int256 oursD = s1.ours - s0.ours;
        int256 uniD = int256(s1.uni) - int256(s0.uni);
        uint256 fee = gasModel.estimateFeeUSDC6(gasUsed, tx.gasprice, 400 * rounds);
        int256 systemNet = botD * 1e12 + oursD - int256(fee) * 1e12;

        console.logUint(rounds);
        console.logInt(botD);
        console.logInt(oursD);
        console.logInt(uniD);
        console.logUint(fee);
        console.logInt(systemNet);
        console.logUint(bridge.solvencyBps());
        console.logUint(IERC20(USDC).balanceOf(bot));

        assertGe(rounds, 1, "micro500 never executed");
        assertApproxEqAbs(botD * 1e12 + oursD + uniD, 0, 1e16, "conservation broken");
        assertLt(uniD, 0, "external donor did not pay");
        assertGe(bridge.solvencyBps(), 10_000, "bridge impaired");
        assertEq(usds.balanceOf(address(exec)), 0, "USDS dust");
        assertEq(eths.balanceOf(address(exec)), 0, "ETHS dust");
        assertGt(systemNet, 0, "micro500 system not profitable");
    }
}
