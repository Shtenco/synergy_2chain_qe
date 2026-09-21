// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/v2/SyntheticTokensV2.sol";
import "../contracts/v2/BridgeCoreV2.sol";
import "../contracts/v2/InternalAMMV2.sol";
import "../contracts/v2/UniswapV3VenueV2.sol";
import "../contracts/v2/ArbitrageExecutorV2.sol";
import "../contracts/v2/IExternalPriceOracleV2.sol";

interface IPoolSlot0S {
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

contract FixedOracleS is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2SmallCap - $20 bot capital, $2/trade (10%), $20 TVL internal pool.
 * @notice Tests the exact requested configuration: tiny capital vs giant
 *         $117M external pool and a $20-TVL internal pool (10 USDS / 0.004 ETHS).
 *         Expectation from math: ~20% price impact per trade vs ~1.2% edge,
 *         so the on-chain gate should refuse every round and capital stays
 *         exactly intact. Run at a dip block for max edge.
 */
contract V2SmallCap is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    uint256 internal constant BOT_CAPITAL = 20e6;
    uint256 internal constant TRADE = 2e6; // 10% of capital

    USDSV2 internal usds;
    ETHSV2 internal eths;
    BridgeCoreV2 internal bridge;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    ArbitrageExecutorV2 internal executor;

    address internal seeder;
    address internal bot;

    function _extPrice6() internal view returns (uint256 px6) {
        (uint160 sqrtP,,,,,,) = IPoolSlot0S(UNI_POOL).slot0();
        px6 = (uint256(sqrtP) * uint256(sqrtP) * 1e18) >> 192;
    }

    function setUp() public {
        seeder = makeAddr("sc.seeder");
        bot = makeAddr("sc.bot");

        usds = new USDSV2();
        eths = new ETHSV2();
        FixedOracleS oracle = new FixedOracleS();
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

        // Internal pool TVL = $20 total, backed via locks (no direct mint).
        deal(USDC, seeder, 15e6);
        deal(seeder, 0.01 ether);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, 10e6);
        bridge.lockETHAndMintETHS{value: 0.004 ether}(seeder, 0.004 ether);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10e18, 0.004 ether);
        vm.stopPrank();

        deal(USDC, bot, BOT_CAPITAL);
        vm.prank(bot);
        IERC20(USDC).approve(address(executor), type(uint256).max);
    }

    function test_SmallCap_GateProtectsCapital() public {
        uint256 px = _extPrice6();
        (uint256 rU, uint256 rE) = amm.reserves();
        uint256 tvl = rU + rE * 2500; // both legs already 18d-normalized dollars
        console.logUint(px);
        console.logUint(tvl);
        console.logUint(IERC20(USDC).balanceOf(bot));

        uint256 minWeth = ((TRADE * 1e18) / px * 97) / 100;
        uint256 minUSDS = amm.getAmountOut(minWeth, false) * 97 / 100;

        uint256 execCount;
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(bot);
            try executor.executeExternalBuyInternalSell(TRADE, minWeth, minUSDS, 0, 1, block.timestamp) {
                execCount++;
            } catch {}
        }

        (uint256 rU1, uint256 rE1) = amm.reserves();
        console.logUint(execCount);
        console.logUint(IERC20(USDC).balanceOf(bot));
        console.logUint(rU1);
        console.logUint(rE1);

        // Capital must be EXACTLY intact: all-or-nothing execution.
        assertEq(IERC20(USDC).balanceOf(bot), BOT_CAPITAL, "bot capital changed");
        assertEq(rU1, rU, "pool USDS moved without execution");
        assertEq(rE1, rE, "pool ETHS moved without execution");
    }
}
