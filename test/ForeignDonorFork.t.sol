// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title ForeignDonorFork
 * @notice Two experiments with the boundary YOU defined:
 *         system = {bot, bridge+reserves, internal pool+LP}; foreign pool excluded.
 *
 * A) Stale foreign pool (ETH 2000) vs fair internal pool (ETH 2500).
 *    Bot extracts the mispricing. System books GROW. The test then proves:
 *    - the growth equals the foreign pool's (excluded) loss +/i fees,
 *    - a second identical cycle earns LESS (spread self-extinguishes).
 *
 * B) Internal LP is "printed whole" via rebaseLP. The test proves the print
 *    is not redeemable value: pool token balance is unchanged while NAV is
 *    inflated, and a full LP exit REVERTS on the unbacked part.
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract ForeignDonorFork -vv
 */
contract ForeignDonorFork is Test {
    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    USDS public usds;
    ETHS public eths;
    MockCanonicalToken public fUSDC;
    MockWETH9 public mWETH;
    ForeignPoolMock public foreignPool;

    address public admin;
    address public seeder;
    address public bot;
    address public lp;
    address public foreignWhale;

    uint256 public constant FAIR = 2500; // fair ETH price, plain units
    uint256 public constant ONE = 1e18;

    function setUp() public {
        admin = makeAddr("donor.admin");
        seeder = makeAddr("donor.seeder");
        bot = makeAddr("donor.bot");
        lp = makeAddr("donor.lp");
        foreignWhale = makeAddr("donor.whale");

        fUSDC = new MockCanonicalToken();
        mWETH = new MockWETH9();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), address(fUSDC), address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        foreignPool = new ForeignPoolMock(address(fUSDC), address(mWETH));

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), admin);

        // Bridge redemption reserve: disclosed external capital, counted IN system.
        fUSDC.mint(address(bridge), 200_000 * ONE);
        // Seeder capital (counted IN system).
        fUSDC.mint(seeder, 150_000 * ONE);
        vm.deal(seeder, 10 ether);
        // Bot operating capital (counted IN system).
        fUSDC.mint(bot, 100_000 * ONE);
        // Foreign whale capital (NOT counted in system books).
        fUSDC.mint(foreignWhale, 60_000_000 * ONE);
        vm.deal(foreignWhale, 25_000 ether);
    }

    /// @dev System EQUITY in consistent 18-dec units at fair price. Foreign pool excluded.
    /// @dev Critical: circulating synthetics are LIABILITIES (redeemable claims on the
    ///      bridge reserve). Counting locked collateral + minted tokens without subtracting
    ///      supply double-counts value. Previous revision had exactly this bug (+1258 phantom).
    function _systemValue() internal view returns (uint256) {
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

    /// @dev Foreign pool value at fair price (tracked only to NAME the donor).
    function _foreignValue() internal view returns (uint256) {
        return foreignPool.reserveU() + foreignPool.reserveE() * FAIR;
    }

    function _seedInternalFair() internal {
        usds.mint(lp, 500_000 * ONE);
        eths.mint(lp, 200 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), 500_000 * ONE);
        eths.approve(address(amm), 200 * ONE);
        amm.addLiquidity(500_000 * ONE, 200 * ONE);
        vm.stopPrank();
    }

    function _seedBridgeBacking() internal {
        vm.startPrank(seeder);
        fUSDC.approve(address(bridge), 100_000 * ONE);
        bridge.lockUSDCAndMintUSDS(seeder, 100_000 * ONE);
        vm.stopPrank();
    }

    /// @dev One full extraction cycle; returns bot's realized canonical profit.
    function _extractCycle(uint256 mWETHAmount) internal returns (uint256 profit) {
        uint256 botUBefore = fUSDC.balanceOf(bot);

        // 1. Buy mWETH on the FOREIGN pool with fUSDC (exact-out via inverted formula).
        vm.prank(bot);
        fUSDC.approve(address(foreignPool), type(uint256).max);
        uint256 rU = foreignPool.reserveU();
        uint256 rE = foreignPool.reserveE();
        // dx s.t. out(dx) == mWETHAmount  =>  dx = rU*1000*out / (997*(rE-out)), rounded up.
        uint256 dx = (rU * 1000 * mWETHAmount) / (997 * (rE - mWETHAmount)) + 1;
        vm.prank(bot);
        uint256 got = foreignPool.swapUforE(dx);
        assertGe(got, mWETHAmount, "foreign leg underfilled");

        // 2. Unwrap to native ETH, lock into bridge -> mint ETHS.
        vm.startPrank(bot);
        mWETH.withdraw(got);
        bridge.lockETHAndMintETHS{value: got}(bot, got);
        // 3. Sell ETHS into the fair internal pool -> USDS.
        eths.approve(address(amm), got);
        uint256 usdsOut = amm.swap(got, false, 0);
        vm.stopPrank();

        // 4. Burn USDS -> unlock fUSDC from the bridge reserve.
        vm.prank(bot);
        bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);

        // Realized gain NET of the stake: fUSDC at end minus fUSDC at start.
        profit = fUSDC.balanceOf(bot) - botUBefore;
    }

    function test_A_ExtractFromStaleForeignPool_Decays() public {
        _seedBridgeBacking();
        _seedInternalFair();

        // Foreign pool seeded STALE: 40M fUSDC / 20k mWETH => ETH = 2000 (fair = 2500).
        vm.startPrank(foreignWhale);
        fUSDC.approve(address(foreignPool), 40_000_000 * ONE);
        mWETH.approve(address(foreignPool), 20_000 * ONE);
        // whale wraps first
        mWETH.deposit{value: 20_000 ether}();
        mWETH.approve(address(foreignPool), 20_000 * ONE);
        foreignPool.seed(40_000_000 * ONE, 20_000 * ONE);
        vm.stopPrank();

        uint256 sysBefore = _systemValue();
        uint256 forBefore = _foreignValue();

        uint256 profit1 = _extractCycle(10 * ONE);

        uint256 sysAfter1 = _systemValue();
        uint256 forAfter1 = _foreignValue();

        console.logUint(profit1);
        console.logInt(int256(sysAfter1) - int256(sysBefore));
        console.logInt(int256(forAfter1) - int256(forBefore));

        // 1. Bot really extracted canonical money.
        assertGt(profit1, 0, "no extraction: foreign pool was not mispriced");
        // 2. System books GREW (foreign pool excluded by your definition).
        assertGt(sysAfter1, sysBefore, "system did not grow");
        // 3. Conservation over the SUPERSET: system growth == donor loss (within dust).
        //    Nothing is printed: every unit of growth left the foreign pool.
        uint256 supBefore = sysBefore + forBefore;
        uint256 supAfter = sysAfter1 + forAfter1;
        assertApproxEqAbs(supAfter, supBefore, 1e15, "value came from nothing");
        // 4. Exact source: donor loss equals system gain.
        assertApproxEqAbs(forBefore - forAfter1, sysAfter1 - sysBefore, 1e15, "donor != system gain");

        // 5. Perpetuity check: run the SAME size again -> must earn LESS.
        uint256 profit2 = _extractCycle(10 * ONE);
        console.logUint(profit2);
        assertLt(profit2, profit1, "second cycle did not decay: perpetual machine?");
    }

    function test_B_PrintHealingIsNotRedeemable() public {
        _seedBridgeBacking();
        _seedInternalFair();

        uint256 poolBalanceBefore = usds.balanceOf(address(amm));
        uint256 navBefore = amm.getNAVPerShare();

        // "Heal" the LP by printing 50k USDS of reserve accounting (no tokens move).
        vm.prank(admin);
        amm.rebaseLP(lp, 50_000 * ONE);

        uint256 navAfter = amm.getNAVPerShare();
        uint256 poolBalanceAfter = usds.balanceOf(address(amm));

        console.logUint(navAfter);
        console.logUint(navBefore);
        console.logUint(poolBalanceAfter);

        // NAV inflated by print...
        assertGt(navAfter, navBefore, "print did not inflate NAV");
        // ...but not a single token backs it.
        assertEq(poolBalanceAfter, poolBalanceBefore, "tokens moved without backing?");
        // Full LP exit on inflated accounting REVERTS: the printed part is unredeemable.
        uint256 shares = amm.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert("Token transfer failed");
        amm.removeLiquidity(shares);
    }
}
