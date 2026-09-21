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

contract FixedOracleZ is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title V2PoolSizing - solves: what internal TVL makes $20 capital profitable?
 * @notice Equation (EXT_BUY_INT_SELL, size s, edge e, gas g, USDS-side depth U):
 *           profit = s * (e - 0.006 - s/U) - g
 *           U > s / (e - 0.006 - g/s),   TVL = 2U
 *         At dip e ~= 1.14%, s = $20, g ~= $0.007:
 *           U > 20 / 0.00507 ~= $3,945/side  ->  TVL > ~$7,900.
 *         Verifies U=8k (expect clear profit) and U=4k (expect boundary:
 *         gate refuses or dust profit, capital never decreases).
 */
contract V2PoolSizing is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    USDSV2 internal usds;
    ETHSV2 internal eths;
    FixedOracleZ internal oracle;
    BridgeCoreV2 internal bridge;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    ArbitrageExecutorV2 internal executor;
    address internal seeder;
    address internal bot;

    function _build(uint256 usdsLock6, uint256 ethLock) internal {
        seeder = makeAddr("sz.seeder");
        bot = makeAddr("sz.bot");
        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOracleZ();
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

        deal(USDC, seeder, usdsLock6);
        deal(seeder, ethLock);
        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, usdsLock6);
        bridge.lockETHAndMintETHS{value: ethLock}(seeder, ethLock);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(usdsLock6 * 1e12, ethLock);
        vm.stopPrank();

        deal(USDC, bot, 20e6);
        vm.prank(bot);
        IERC20(USDC).approve(address(executor), type(uint256).max);
    }

    function _markPool() internal view returns (uint256 v) {
        (uint256 rU, uint256 rE) = amm.reserves();
        v = rU + rE * 2500;
    }

    function _markUni() internal view returns (uint256 v) {
        v = IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
    }

    function _try20(uint256 minProfit) internal returns (bool ok) {
        vm.prank(bot);
        try executor.executeExternalBuyInternalSell(20e6, 0.0080 ether, 19.9e18, 0, minProfit, block.timestamp)
            returns (uint256)
        {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _campaign(uint256 minProfit) internal returns (uint256 rounds, uint256 gasUsed) {
        uint256 g0 = gasleft();
        while (rounds < 25) {
            if (!_try20(minProfit)) break;
            rounds++;
        }
        gasUsed = g0 - gasleft();
    }

    function test_U8k_TVL16k_Profitable() public {
        _build(8_000e6, 3.2 ether);
        uint256 b0 = IERC20(USDC).balanceOf(bot);
        uint256 m0 = _markPool();
        uint256 u0 = _markUni();
        (uint256 rounds, uint256 gasUsed) = _campaign(5_000);
        uint256 b1 = IERC20(USDC).balanceOf(bot);
        int256 botD = int256(b1) - int256(b0);
        int256 lpD = int256(_markPool()) - int256(m0);
        int256 poolD = int256(_markUni()) - int256(u0);
        OPGasCostModelV2 gm = new OPGasCostModelV2(address(oracle));
        uint256 fee = gm.estimateFeeUSDC6(gasUsed, tx.gasprice, 400 * rounds);
        int256 net = botD * 1e12 + lpD - int256(fee) * 1e12;

        console.logUint(rounds);
        console.logInt(botD);
        console.logInt(lpD);
        console.logInt(poolD);
        console.logInt(net);

        assertGe(rounds, 1, "U=8k should execute");
        assertApproxEqAbs(botD * 1e12 + lpD + poolD, 0, 1e16, "conservation broken");
        assertGt(net, 0, "U=8k should be net profitable");
    }

    function test_U4k_TVL8k_Boundary() public {
        _build(4_000e6, 1.6 ether);
        uint256 b0 = IERC20(USDC).balanceOf(bot);
        (uint256 rounds,) = _campaign(1);
        uint256 b1 = IERC20(USDC).balanceOf(bot);

        console.logUint(rounds);
        console.logUint(b1);

        // Boundary: gate may refuse everything; capital must NEVER decrease.
        assertGe(b1, b0, "capital decreased below $20");
    }
}
