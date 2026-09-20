// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/**
 * @title RealizedProfitFork
 * @notice Measures REALIZED canonical money, not estimatedProfit.
 * @dev Full-system accounting: bot + LP + bridge + pool. No minting of profit,
 *      no reserve top-ups between BEFORE and AFTER. If the bot ends positive,
 *      the test FORCES proof of where it came from (LP NAV and/or bridge reserve).
 *
 *      Run on Base fork:
 *      forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *        --match-contract RealizedProfitFork -vv
 */
contract RealizedProfitFork is Test {
    BridgeCore public bridge;
    InternalAMM public amm;
    TreasuryDistributor public treasury;
    ManagedOracle public oracle;
    USDS public usds;
    ETHS public eths;
    MockCanonicalToken public canonical;

    address public admin;
    address public seeder;
    address public bot;
    address public lp;
    address public ownerWallet;
    address public bridgeReserve;
    address public insuranceFund;
    address public rebaseFund;

    uint256 public constant EXT_PRICE = 2500e6; // oracle quote, 6 decimals
    uint256 public constant ONE = 1e18;
    // Production code applies the 6-decimal price directly to 18-decimal amounts
    // (documented decimals bug). Here, and only here in measurement code, we scale
    // by 1e12 so that 1 ETH == 2500 canonical units in consistent 18-decimal units.
    uint256 public constant DECIMALS_SCALE = 1e12;

    event RealizedResult(
        int256 botProfitCanonical,
        int256 lpNAVDelta,
        int256 bridgeReserveDelta,
        int256 systemDelta
    );

    function setUp() public {
        admin = makeAddr("realized.admin");
        seeder = makeAddr("realized.seeder");
        bot = makeAddr("realized.bot");
        lp = makeAddr("realized.lp");
        ownerWallet = makeAddr("realized.owner");
        bridgeReserve = makeAddr("realized.bridgeReserve");
        insuranceFund = makeAddr("realized.insurance");
        rebaseFund = makeAddr("realized.rebase");

        canonical = new MockCanonicalToken();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(EXT_PRICE);

        bridge = new BridgeCore(
            address(usds),
            address(eths),
            address(canonical),
            address(oracle)
        );
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        treasury = new TreasuryDistributor(
            address(canonical),
            ownerWallet,
            bridgeReserve,
            insuranceFund,
            rebaseFund
        );

        // Roles: seeder prepares the system, bot executes the measured cycle.
        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), admin);

        // --- Seed canonical reserves (disclosed external capital, NOT profit) ---
        canonical.mint(address(bridge), 500_000 * ONE); // USDC-side redemption reserve
        canonical.mint(seeder, 200_000 * ONE);
        vm.deal(seeder, 100 ether);
        vm.deal(bot, 20 ether);

        // --- Seed synthetic backing so burnUSDSAndUnlockUSDC is payable ---
        vm.startPrank(seeder);
        canonical.approve(address(bridge), 100_000 * ONE);
        bridge.lockUSDCAndMintUSDS(seeder, 100_000 * ONE);
        vm.stopPrank();

        // --- LP provides liquidity at a MISPRICED ratio (internal ETHS = 5000 vs ext 2500) ---
        // This is the only source of a positive bot leg: someone must be on the losing side.
        usds.mint(lp, 500_000 * ONE);
        eths.mint(lp, 100 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), 500_000 * ONE);
        eths.approve(address(amm), 100 * ONE);
        amm.addLiquidity(500_000 * ONE, 100 * ONE);
        vm.stopPrank();
    }

    function _systemCanonicalValue() internal view returns (uint256) {
        // Canonical value of the whole closed system in mock-USDC units (18 decimals).
        // ETH legs are valued at the external oracle quote.
        uint256 bridgeUSDC = canonical.balanceOf(address(bridge));
        uint256 seederUSDC = canonical.balanceOf(seeder);
        uint256 botUSDC = canonical.balanceOf(bot);
        uint256 lpUSDC = canonical.balanceOf(lp);
        uint256 poolUSDCeq = amm.reserveUSDS() + (amm.reserveETHS() * EXT_PRICE * DECIMALS_SCALE) / 1e18;
        uint256 ethValue = ((address(bridge).balance + seeder.balance + bot.balance + lp.balance) * EXT_PRICE * DECIMALS_SCALE) / 1e18;
        return bridgeUSDC + seederUSDC + botUSDC + lpUSDC + poolUSDCeq + ethValue;
    }

    function test_RealizedCycleA_FullAccounting() public {
        uint256 systemBefore = _systemCanonicalValue();
        uint256 lpNAVBefore = amm.getLPNAV(lp);
        uint256 bridgeUSDCBefore = canonical.balanceOf(address(bridge));
        uint256 botETHBefore = bot.balance;

        uint256 tradeETH = 10 * ONE;

        // Step 1: lock canonical ETH -> mint ETHS (bot pays real ETH).
        vm.prank(bot);
        bridge.lockETHAndMintETHS{value: tradeETH}(bot, tradeETH);

        // Step 2: sell ETHS inside the mispriced internal pool -> receive USDS.
        vm.startPrank(bot);
        eths.approve(address(amm), tradeETH);
        uint256 usdsOut = amm.swap(tradeETH, false, 0); // ETHS -> USDS
        vm.stopPrank();

        // Step 3: burn USDS -> unlock canonical USDC from the bridge reserve.
        vm.prank(bot);
        bridge.burnUSDSAndUnlockUSDC(bot, usdsOut);

        uint256 botUSDC = canonical.balanceOf(bot);
        uint256 ethCostUSDC = (tradeETH * EXT_PRICE * DECIMALS_SCALE) / 1e18;
        // Bot spent exactly tradeETH of ETH (gas ignored here, which only favors the bot).
        assertEq(botETHBefore - bot.balance, tradeETH, "unexpected bot ETH movement");
        int256 botProfit = int256(botUSDC) - int256(ethCostUSDC);

        uint256 lpNAVAfter = amm.getLPNAV(lp);
        uint256 systemAfter = _systemCanonicalValue();
        int256 bridgeDelta = int256(canonical.balanceOf(address(bridge))) - int256(bridgeUSDCBefore);

        emit RealizedResult(botProfit, int256(lpNAVAfter) - int256(lpNAVBefore), bridgeDelta, int256(systemAfter) - int256(systemBefore));
        console.logInt(botProfit);
        console.logInt(int256(lpNAVAfter) - int256(lpNAVBefore));
        console.logInt(bridgeDelta);
        console.logInt(int256(systemAfter) - int256(systemBefore));

        // 1. Bot leg really is positive ONLY because the pool was mispriced against it.
        assertGt(botUSDC, ethCostUSDC, "no realized bot profit without a counterparty loss");

        // 2. Conservation: the closed system did not print value (tolerance: dust only).
        // If this fails upward, the system minted value from nothing -> investigate.
        assertLe(systemAfter, systemBefore, "closed system gained value from nothing");

        // 3. LP paid for (part of) the bot profit.
        assertLt(lpNAVAfter, lpNAVBefore, "bot profit did not come from LP/pool value");
    }
}
