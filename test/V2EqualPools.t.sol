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

contract FixedOracleQ is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2EqualPools - internal TVL == external TVL (~$117M), $20 capital.
 * @notice Internal pool seeded at external scale (58.5M USDS / 23,400 ETHS,
 *         backed via locks). Hypothesis: at parity depths neither leg moves,
 *         so rounds repeat identically until the cap, not the gate.
 *         Run at a dip block for max edge.
 */
contract V2EqualPools is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    USDSV2 internal usds;
    ETHSV2 internal eths;
    FixedOracleQ internal oracle;
    BridgeCoreV2 internal bridge;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    ArbitrageExecutorV2 internal executor;
    address internal seeder;
    address internal bot;

    struct V2ESnap {
        uint256 bot;
        uint256 lpM;
        uint256 uniM;
    }

    function setUp() public {
        seeder = makeAddr("eq.seeder");
        bot = makeAddr("eq.bot");

        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOracleQ();
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

        // Equal scale: 58.5M USDS / 23,400 ETHS @2500 = ~$117M TVL, backed.
        deal(USDC, seeder, 58_500_000e6);
        deal(seeder, 23_400 ether);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, 58_500_000e6);
        bridge.lockETHAndMintETHS{value: 23_400 ether}(seeder, 23_400 ether);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(58_500_000e18, 23_400 ether);
        vm.stopPrank();

        deal(USDC, bot, 20e6);
        vm.prank(bot);
        IERC20(USDC).approve(address(executor), type(uint256).max);
    }

    function _snap() internal view returns (V2ESnap memory t) {
        t.bot = IERC20(USDC).balanceOf(bot);
        (uint256 rU, uint256 rE) = amm.reserves();
        t.lpM = rU + rE * 2500;
        t.uniM = IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
    }

    function _try20() internal returns (bool ok) {
        vm.prank(bot);
        try executor.executeExternalBuyInternalSell(20e6, 0.0080 ether, 20.0e18, 0, 5_000, block.timestamp)
            returns (uint256)
        {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _finish(V2ESnap memory a, V2ESnap memory b, uint256 gasUsed, uint256 rounds)
        internal
        returns (int256 systemNet)
    {
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 lpD = int256(b.lpM) - int256(a.lpM);
        int256 poolD = int256(b.uniM) - int256(a.uniM);
        OPGasCostModelV2 gm = new OPGasCostModelV2(address(oracle));
        uint256 fee = gm.estimateFeeUSDC6(gasUsed, tx.gasprice, 400 * rounds);
        systemNet = botD * 1e12 + lpD - int256(fee) * 1e12;

        console.logUint(rounds);
        console.logInt(botD);
        console.logInt(lpD);
        console.logInt(poolD);
        console.logUint(fee);
        console.logInt(systemNet);

        assertApproxEqAbs(botD * 1e12 + lpD + poolD, 0, 1e16, "conservation broken");
        assertLt(poolD, 0, "external donor did not pay");
        assertGe(bridge.solvencyBps(), 10_000, "bridge impaired");
    }

    function test_EqualPools_NoDecay25Rounds() public {
        V2ESnap memory s0 = _snap();
        uint256 gasStart = gasleft();
        uint256 rounds;
        while (rounds < 25) {
            if (!_try20()) break;
            rounds++;
        }
        uint256 gasUsed = gasStart - gasleft();
        V2ESnap memory s1 = _snap();

        int256 systemNet = _finish(s0, s1, gasUsed, rounds);
        console.logUint(IERC20(USDC).balanceOf(bot));

        assertGe(rounds, 20, "decay stopped the campaign early");
        assertGt(systemNet, 0, "equal-pool system not profitable");
    }
}
