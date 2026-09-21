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
