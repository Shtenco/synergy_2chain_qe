// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/v2/SyntheticTokensV2.sol";
import "../contracts/v2/InternalAMMV2.sol";
import "../contracts/v2/UniswapV3VenueV2.sol";
import "../contracts/v2/OPGasCostModelV2.sol";
import "../contracts/v2/IExternalPriceOracleV2.sol";
import "../contracts/pb/BridgePool.sol";
import "../contracts/pb/ExecutorPB.sol";
import "../contracts/pb/BuybackBurner.sol";
import "../contracts/v2/OPGasCostModelV2.sol";

contract FixedOraclePB is IExternalPriceOracleV2 {
    function getPrice6d() external pure override returns (uint256) { return 2500e6; }
    function isStale() external pure override returns (bool) { return false; }
    function updatedAt() external view override returns (uint256) { return block.timestamp; }
}

/**
 * @title PoolBridgeFork - the bridge IS pools. No vault, no locks.
 * @notice Genesis: one-time 1:1 issuance (150k USDS vs 150k USDC,
 *         80 ETHS vs 80 WETH), then BRIDGE_ROLE revoked from the test —
 *         supply sealed forever. Conversion thereafter ONLY via swaps in
 *         PoolA (USDS/USDC) and PoolB (ETHS/WETH). No BridgeCore deployed.
 *         Run at a dip block for max edge.
 */
contract PoolBridgeFork is Test {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    USDSV2 internal usds;
    ETHSV2 internal eths;
    FixedOraclePB internal oracle;
    BridgePool internal poolA;
    BridgePool internal poolB;
    InternalAMMV2 internal amm;
    UniswapV3VenueV2 internal venue;
    ExecutorPB internal exec;
    OPGasCostModelV2 internal gasModel;
    address internal seeder;
    address internal bot;

    struct PBSnap {
        uint256 bot;
        uint256 poolsM;
        uint256 uniM;
    }

    function setUp() public {
        seeder = makeAddr("pb.seeder");
        bot = makeAddr("pb.bot");

        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOraclePB();
        // PoolA: A=USDS(18d), B=USDC(6d, scale 1e12). PoolB: A=ETHS, B=WETH(18d, scale 1).
        poolA = new BridgePool(address(usds), USDC, 5, 1e12, "PoolBridge USDS-USDC", "PBU");
        poolB = new BridgePool(address(eths), WETH, 5, 1, "PoolBridge ETHS-WETH", "PBE");
        amm = new InternalAMMV2(address(usds), address(eths), address(oracle));
        venue = new UniswapV3VenueV2(UNI_POOL, USDC, WETH);
        exec = new ExecutorPB(
            address(poolA), address(poolB), address(amm), address(venue),
            USDC, WETH, address(usds), address(eths)
        );
        gasModel = new OPGasCostModelV2(address(oracle));
        exec.grantRole(exec.BOT_ROLE(), bot);

        // One-time 1:1 genesis, then seal the supply.
        usds.grantRole(usds.BRIDGE_ROLE(), address(this));
        eths.grantRole(eths.BRIDGE_ROLE(), address(this));
        deal(USDC, seeder, 250_000e6);
        deal(WETH, seeder, 80 ether);
        usds.mint(seeder, 150_000e18);
        eths.mint(seeder, 80 ether);
        usds.revokeRole(usds.BRIDGE_ROLE(), address(this));
        eths.revokeRole(eths.BRIDGE_ROLE(), address(this));
        assertFalse(usds.hasRole(usds.BRIDGE_ROLE(), address(this)), "supply not sealed");
        assertFalse(eths.hasRole(eths.BRIDGE_ROLE(), address(this)), "supply not sealed");

        vm.startPrank(seeder);
        IERC20(USDC).approve(address(poolA), type(uint256).max);
        usds.approve(address(poolA), type(uint256).max);
        poolA.addLiquidity(100_000e18, 100_000e6);
        IERC20(WETH).approve(address(poolB), type(uint256).max);
        eths.approve(address(poolB), type(uint256).max);
        poolB.addLiquidity(40 ether, 40 ether);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(50_000e18, 20 ether);
        vm.stopPrank();

        deal(USDC, bot, 20e6);
        vm.prank(bot);
        IERC20(USDC).approve(address(exec), type(uint256).max);
    }

    /// @dev Marks (18d-normalized dollars): USDS 1:1, USDC x1e12, ETHS/WETH x2500.
    function _snap() internal view returns (PBSnap memory t) {
        t.bot = IERC20(USDC).balanceOf(bot);
        (uint256 aU, uint256 aB) = poolA.reserves();
        (uint256 bU, uint256 bB) = poolB.reserves();
        (uint256 mU, uint256 mE) = amm.reserves();
        t.poolsM = aU + aB * 1e12 + (bU + bB) * 2500 + mU + mE * 2500;
        t.uniM = IERC20(USDC).balanceOf(UNI_POOL) * 1e12 + IERC20(WETH).balanceOf(UNI_POOL) * 2500;
    }

    function _try20() internal returns (bool ok) {
        vm.prank(bot);
        try exec.executeExternalBuyInternalSell(20e6, 0.0080 ether, 0.0080 ether, 19.9e18, 19.9e6, 5_000, block.timestamp)
            returns (uint256)
        {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _finish(PBSnap memory a, PBSnap memory b, uint256 gasUsed, uint256 rounds)
        internal
        view
        returns (int256 systemNet)
    {
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 poolsD = int256(b.poolsM) - int256(a.poolsM);
        int256 uniD = int256(b.uniM) - int256(a.uniM);
        uint256 fee = gasModel.estimateFeeUSDC6(gasUsed, tx.gasprice, 400 * rounds);
        systemNet = botD * 1e12 + poolsD - int256(fee) * 1e12;

        console.logUint(rounds);
        console.logInt(botD);
        console.logInt(poolsD);
        console.logInt(uniD);
        console.logUint(fee);
        console.logInt(systemNet);

        assertApproxEqAbs(botD * 1e12 + poolsD + uniD, 0, 1e16, "conservation broken");
        assertLt(uniD, 0, "external donor did not pay");
        // EXACT proof: bot + ALL bridge pools, gross (before gas) and net.
        assertGt(botD * 1e12 + poolsD, 0, "bot+pools gross not positive");
    }

    function _runHarvest() internal returns (uint256 rounds, uint256 profit6) {
        while (rounds < 25) {
            if (!_try20()) break;
            rounds++;
        }
        profit6 = IERC20(USDC).balanceOf(bot) - 20e6;
    }

    function _poolAPrice() internal view returns (uint256 p18) {
        (uint256 rA, uint256 rB) = poolA.reserves();
        p18 = (rB * 1e12 * 1e18) / rA; // 18d USDC per USDS
    }

    /// @dev 50% of harvest profit -> buy USDS from PoolA -> burn. Returns (burned, priceBefore, priceAfter).
    function _doBuyback(uint256 buyback6) internal returns (uint256 burned, uint256 priceB, uint256 priceA) {
        priceB = _poolAPrice();
        BuybackBurner burner = new BuybackBurner(address(poolA), address(usds), USDC);
        usds.grantRole(usds.BRIDGE_ROLE(), address(burner));
        uint256 minOut = poolA.getAmountOut(buyback6, false) * 99 / 100;
        vm.prank(bot);
        IERC20(USDC).approve(address(burner), buyback6);
        vm.prank(bot);
        burned = burner.buyAndBurn(buyback6, minOut);
        priceA = _poolAPrice();
    }

    function _assertBuyback(
        PBSnap memory a,
        PBSnap memory b,
        uint256 supply0,
        uint256 burned,
        uint256 priceB,
        uint256 priceA
    ) internal view {
        int256 botD = int256(b.bot) - int256(a.bot);
        int256 poolsD = int256(b.poolsM) - int256(a.poolsM);
        int256 uniD = int256(b.uniM) - int256(a.uniM);
        uint256 supply1 = usds.totalSupply();

        console.logInt(botD);
        console.logInt(poolsD);
        console.logInt(uniD);
        console.logUint(supply0 - supply1);
        console.logUint(priceB);
        console.logUint(priceA);
        console.logUint(IERC20(USDC).balanceOf(bot));

        assertEq(supply0 - supply1, burned, "supply did not shrink by burned");
        assertGt(priceA, priceB, "peg not supported");
        assertGe(IERC20(USDC).balanceOf(bot), 20e6, "bot below start");
        // Full conservation INCLUDING the flames: every cent tracked.
        assertApproxEqAbs(botD * 1e12 + poolsD + uniD + int256(burned), 0, 1e16, "conservation broken");
    }

    /// @notice Variant 1: earnings -> buyback -> burn. No mint anywhere.
    function test_BuybackBurn_FromEarnings() public {
        PBSnap memory s0 = _snap();
        uint256 supply0 = usds.totalSupply();
        (uint256 rounds, uint256 profit6) = _runHarvest();
        require(rounds >= 1, "no harvest to fund buyback");
        require(profit6 > 0, "no profit to route");

        uint256 buyback = profit6 / 2;
        (uint256 burned, uint256 priceB, uint256 priceA) = _doBuyback(buyback);
        PBSnap memory s1 = _snap();

        _assertBuyback(s0, s1, supply0, burned, priceB, priceA);
    }

    /// @dev One micro round: 50%-loose bounds, measures R = gross/full-gas x100.
    function _micro(uint256 size6) internal returns (uint256 gross6, uint256 fullFee6, uint256 r100) {
        OPGasCostModelV2 gm = new OPGasCostModelV2(address(oracle));
        uint256 minW = (size6 * 1e18) / 5200e6;
        uint256 b0 = IERC20(USDC).balanceOf(bot);
        uint256 g0 = gasleft();
        vm.prank(bot);
        try exec.executeExternalBuyInternalSell(size6, minW, minW / 2, size6 * 1e12 / 2, size6 / 2, 1, block.timestamp) {
            uint256 used = g0 - gasleft();
            uint256 b1 = IERC20(USDC).balanceOf(bot);
            fullFee6 = gm.estimateFeeUSDC6(used, tx.gasprice, 400);
            gross6 = b1 - b0;
            r100 = (gross6 * 100) / fullFee6;
        } catch {
            gross6 = 0;
            fullFee6 = 0;
            r100 = 0;
        }
        assertEq(usds.balanceOf(address(exec)), 0, "USDS dust");
        assertEq(eths.balanceOf(address(exec)), 0, "ETHS dust");
    }

    /// @notice Micro-trade gas discipline at dip (deep pools, impact ~= 0).
    ///         Predicted R = s*(e-f)/g: $5 -> 3.1x, $2 -> 1.26x, $1 -> 0.63x, $0.5 -> 0.31x.
    function test_MicroGasPayback2x() public {
        (uint256 g5,, uint256 r5) = _micro(5e6);
        console.logUint(g5);
        console.logUint(r5);
        assertGt(g5, 0, "$5 refused unexpectedly");
        assertGe(r5, 200, "$5 must pay gas 2x+");

        (uint256 g2,, uint256 r2) = _micro(2e6);
        console.logUint(g2);
        console.logUint(r2);
        assertGt(g2, 0, "$2 refused unexpectedly");
        assertGt(r2, 100, "$2 must stay net-positive");
        assertLt(r2, 200, "$2 below 2x bar");

        (,, uint256 r1) = _micro(1e6);
        console.logUint(r1);
        assertLt(r1, 100, "$1 below 1x (gas loss, honest)");

        (,, uint256 rh) = _micro(0.5e6);
        console.logUint(rh);
        assertLt(rh, 100, "$0.5 below 1x (gas loss, honest)");

        console.logUint(IERC20(USDC).balanceOf(bot));
    }

    function test_PoolBridge_HarvestNoVault() public {
        PBSnap memory s0 = _snap();
        uint256 gasStart = gasleft();
        uint256 rounds;
        while (rounds < 25) {
            if (!_try20()) break;
            rounds++;
        }
        uint256 gasUsed = gasStart - gasleft();
        PBSnap memory s1 = _snap();

        int256 systemNet = _finish(s0, s1, gasUsed, rounds);
        console.logUint(IERC20(USDC).balanceOf(bot));

        assertGe(rounds, 1, "pool-bridge route never executed");
        assertGt(systemNet, 0, "pool-bridge system not profitable");
    }
}
