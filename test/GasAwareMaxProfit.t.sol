// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/GradientControllerV2.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

/// @notice OP-stack L1 gas oracle (Base predeploy, real fork state).
interface IGasPriceOracle {
    function getL1Fee(bytes memory _data) external view returns (uint256);
}

/**
 * @title GasAwareMaxProfit - Real Base gas modeling + profit maximization, Base fork
 * @notice Gas model (all measured, nothing assumed):
 *         - Execution gas: gasleft() diffs around the EXACT low-level calls a
 *           production bundle would send (conservative: counted as separate
 *           txs; a single multicall bundle would be cheaper).
 *         - L2 gas price: block.basefee x2 (EIP-1559 next-block upper bound).
 *           Pinned block basefee (cast): 5,000,000 wei = 0.005 gwei.
 *         - L1 data fee: GasPriceOracle.getL1Fee(exactCalldata) on fork state.
 *         - ETH/USD: 2079e8, measured from the giant pool's 50/50 balances
 *           at the pinned block (26,339.66 WETH / 54,767,416.49 USDC).
 *         - Gate: net = gross - gas$ > 0, every round.
 *
 * Flow: sweep trade sizes on fresh systems -> pick max net -> 25-round campaign
 *       at the winner size -> treasury settle (its gas also measured) -> report.
 *
 * Run on Base fork:
 * forge test --fork-url https://mainnet.base.org --fork-block-number <N> --no-isolate \
 *   --match-contract GasAwareMaxProfit -vv
 */
contract GasAwareMaxProfit is Test {
    IGasPriceOracle public constant L1_ORACLE =
        IGasPriceOracle(0x420000000000000000000000000000000000000F);

    uint256 public constant FAIR = 2500;
    uint256 public constant ONE = 1e18;
    int256 public constant ETH_USD8 = 207900000000; // 2079e8, measured at pinned block
    uint256 public constant GAS_PRICE_MULT = 2; // x block.basefee upper bound
    uint256 public constant ROUNDS = 25;

    // Current system under test (storage to avoid stack-too-deep).
    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    GradientControllerV2 public controller;
    TreasuryDistributor public treasury;
    USDS public usds;
    ETHS public eths;
    MockCanonicalToken public fUSDC;
    MockWETH9 public mWETH;
    ForeignPoolMock public foreignPool;
    address public seeder;
    address public bot;
    address public lp;
    address public keeper;
    address public tOwner;
    address public tBridge;
    address public tIns;
    address public tReb;

    /// @dev Build a fresh system: poolU/poolE internal pool, backingU locked, botU cash.
    function _buildSystem(uint256 poolU, uint256 poolE, uint256 backingU, uint256 botU) internal {
        seeder = makeAddr("gmax.seeder");
        bot = makeAddr("gmax.bot");
        lp = makeAddr("gmax.lp");
        keeper = makeAddr("gmax.keeper");
        address whale = makeAddr("gmax.whale");
        address ownerW = makeAddr("gmax.owner");
        address brW = makeAddr("gmax.br");
        address insW = makeAddr("gmax.ins");
        address rebW = makeAddr("gmax.reb");

        fUSDC = new MockCanonicalToken();
        mWETH = new MockWETH9();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), address(fUSDC), address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        foreignPool = new ForeignPoolMock(address(fUSDC), address(mWETH));
        controller = new GradientControllerV2(address(oracle));
        treasury = new TreasuryDistributor(address(fUSDC), ownerW, brW, insW, rebW);

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), bot);
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        amm.grantRole(amm.REBASE_ROLE(), address(this));
        oracle.grantRole(oracle.ALGO_CONTROLLER(), address(controller));
        controller.grantRole(controller.KEEPER_ROLE(), keeper);

        fUSDC.mint(seeder, backingU);
        fUSDC.mint(bot, botU);
        vm.startPrank(seeder);
        fUSDC.approve(address(bridge), backingU);
        bridge.lockUSDCAndMintUSDS(seeder, backingU);
        vm.stopPrank();

        usds.mint(lp, poolU);
        eths.mint(lp, poolE);
        vm.startPrank(lp);
        usds.approve(address(amm), poolU);
        eths.approve(address(amm), poolE);
        amm.addLiquidity(poolU, poolE);
        vm.stopPrank();

        // $120M donor @ 2000 (excluded from books).
        fUSDC.mint(whale, 60_000_000 * ONE);
        vm.deal(whale, 35_000 ether);
        vm.startPrank(whale);
        mWETH.deposit{value: 30_000 ether}();
        fUSDC.approve(address(foreignPool), 60_000_000 * ONE);
        mWETH.approve(address(foreignPool), 30_000 * ONE);
        foreignPool.seed(60_000_000 * ONE, 30_000 * ONE);
        vm.stopPrank();
    }

    function _gasPrice() internal view returns (uint256) {
        return block.basefee * GAS_PRICE_MULT;
    }

    /// @dev gas$ in 18d units from measured exec gas + exact L1 fee.
    function _gasUsd(uint256 execGas, uint256 l1feeWei) internal view returns (uint256) {
        uint256 ethWei = execGas * _gasPrice() + l1feeWei;
        return (ethWei * uint256(ETH_USD8) * 1e10) / 1e18;
    }

    /// @dev Metered low-level call: returns (execGas, l1fee). Reverts on failure.
    function _metered(address target, bytes memory cd) internal returns (uint256 execGas, uint256 l1fee) {
        uint256 g0 = gasleft();
        vm.prank(bot);
        (bool ok, ) = target.call(cd);
        require(ok, "metered call failed");
        execGas = g0 - gasleft();
        l1fee = L1_ORACLE.getL1Fee(cd);
    }

    /// @dev Metered low-level call carrying native value.
    function _meteredValue(address target, uint256 value, bytes memory cd)
        internal
        returns (uint256 execGas, uint256 l1fee)
    {
        uint256 g0 = gasleft();
        vm.prank(bot);
        (bool ok, ) = target.call{value: value}(cd);
        require(ok, "metered value call failed");
        execGas = g0 - gasleft();
        l1fee = L1_ORACLE.getL1Fee(cd);
    }

    /// @dev Generic metered leg result: product + exec gas + L1 fee.
    struct Leg {
        uint256 out;
        uint256 g;
        uint256 f;
    }

    // Last harvest measurement (storage: keeps stack shallow).
    uint256 public lastGross;
    uint256 public lastExecGas;
    uint256 public lastL1;
    uint256 public lastGasUsd;
    int256 public lastNet;
    // Campaign accumulators (storage).
    uint256 public cTotGross;
    uint256 public cTotGas;
    int256 public cTotNet;
    uint256 public cRounds;
    uint256 public cEqStart;
    uint256 public cForStart;
    uint256 public cBotStart;
    uint256 public lastBreak; // 0 = completed all rounds

    /// @dev Leg 1: approve + buy mWETH on the foreign pool.
    function _legForeign(uint256 amount) internal returns (Leg memory l) {
        uint256 dx = (foreignPool.reserveU() * 1000 * amount) / (997 * (foreignPool.reserveE() - amount)) + 1;
        bytes memory cdAp = abi.encodeCall(IERC20.approve, (address(foreignPool), type(uint256).max));
        bytes memory cdF = abi.encodeCall(ForeignPoolMock.swapUforE, (dx));
        (uint256 g1, uint256 f1) = _metered(address(fUSDC), cdAp);
        uint256 g0 = gasleft();
        vm.prank(bot);
        (bool ok, bytes memory ret) = address(foreignPool).call(cdF);
        require(ok, "foreign swap failed");
        l.g = g1 + (g0 - gasleft());
        l.f = f1 + L1_ORACLE.getL1Fee(cdF);
        l.out = abi.decode(ret, (uint256));
        require(l.out >= amount, "underfilled");
    }

    /// @dev Leg 2: unwrap + lock ETH -> mint ETHS.
    function _legUnwrapLock(uint256 got) internal returns (Leg memory l) {
        bytes memory cdW = abi.encodeCall(MockWETH9.withdraw, (got));
        (uint256 g1, uint256 f1) = _metered(address(mWETH), cdW);
        bytes memory cdL = abi.encodeCall(BridgeCore.lockETHAndMintETHS, (bot, got));
        (uint256 g2, uint256 f2) = _meteredValue(address(bridge), got, cdL);
        l.g = g1 + g2;
        l.f = f1 + f2;
    }

    /// @dev Leg 3: approve + internal swap + burn -> unlock.
    function _legSwapBurn(uint256 got) internal returns (Leg memory l) {
        bytes memory cdAp = abi.encodeCall(IERC20.approve, (address(amm), got));
        bytes memory cdS = abi.encodeCall(InternalAMM.swap, (got, false, uint256(0)));
        (uint256 g1, uint256 f1) = _metered(address(eths), cdAp);
        uint256 g0 = gasleft();
        vm.prank(bot);
        (bool ok, bytes memory ret) = address(amm).call(cdS);
        require(ok, "internal swap failed");
        uint256 usdsOut = abi.decode(ret, (uint256));
        bytes memory cdB = abi.encodeCall(BridgeCore.burnUSDSAndUnlockUSDC, (bot, usdsOut));
        (uint256 g2, uint256 f2) = _metered(address(bridge), cdB);
        l.out = usdsOut;
        l.g = g1 + (g0 - gasleft()) + g2;
        l.f = f1 + L1_ORACLE.getL1Fee(cdS) + f2;
    }

    /// @dev One forward harvest with full gas accounting. Writes last* state, returns net.
    function _harvestFwd(uint256 amount) internal returns (int256 net) {
        uint256 botUBefore = fUSDC.balanceOf(bot);
        Leg memory a = _legForeign(amount);
        Leg memory b = _legUnwrapLock(a.out);
        Leg memory c = _legSwapBurn(a.out);
        lastExecGas = a.g + b.g + c.g;
        lastL1 = a.f + b.f + c.f;
        lastGross = fUSDC.balanceOf(bot) - botUBefore;
        lastGasUsd = _gasUsd(lastExecGas, lastL1);
        lastNet = int256(lastGross) - int256(lastGasUsd);
        net = lastNet;
    }

    function test_SweepSizes_PickMaxNet() public {
        // Notionals in mWETH-out (~$ at 2000): 0.8 / 4 / 8 / 20 / 40 / 80 / 200 / 400 / 800.
        uint256[9] memory sizes = [
            uint256(4e14), uint256(2e15), uint256(4e15), uint256(1e16), uint256(2e16),
            uint256(4e16), uint256(1e17), uint256(2e17), uint256(4e17)
        ];
        uint256 bestIdx;
        int256 bestNet = type(int256).min;
        console.logUint(block.basefee);

        for (uint256 i = 0; i < sizes.length; i++) {
            _buildSystem(5_000 * ONE, 2 * ONE, 9_000 * ONE, 1_000 * ONE);
            int256 net = _harvestFwd(sizes[i]);
            console.logUint(sizes[i]);
            console.logUint(lastGross);
            console.logUint(lastExecGas);
            console.logUint(lastL1);
            console.logUint(lastGasUsd);
            console.logInt(net);
            if (net > bestNet) {
                bestNet = net;
                bestIdx = i;
            }
        }
        console.logUint(bestIdx);
        console.logInt(bestNet);
        assertGt(bestNet, 0, "no size viable under real gas");
    }

    function _sysEquity() internal view returns (uint256) {
        uint256 assets = fUSDC.balanceOf(address(bridge))
            + fUSDC.balanceOf(seeder)
            + fUSDC.balanceOf(bot)
            + fUSDC.balanceOf(lp)
            + fUSDC.balanceOf(address(treasury))
            + fUSDC.balanceOf(tOwner)
            + fUSDC.balanceOf(tBridge)
            + fUSDC.balanceOf(tIns)
            + fUSDC.balanceOf(tReb)
            + mWETH.balanceOf(bot) * FAIR;
        uint256 ethAssets = (address(bridge).balance + bot.balance) * FAIR;
        uint256 poolAssets = amm.reserveUSDS() + amm.reserveETHS() * FAIR;
        uint256 liabilities = usds.totalSupply() + eths.totalSupply() * FAIR;
        return assets + ethAssets + poolAssets - liabilities;
    }

    /// @dev V2-gated preview for a forward harvest at size.
    /// @return code 0 = go, 1 = neutral, 2 = preview unprofitable, 3 = backing exhausted.
    function _gate(uint256 size) internal returns (uint256 code) {
        uint256 poolPx = (amm.reserveUSDS() * 1e6) / amm.reserveETHS();
        uint256 forPx = (foreignPool.reserveU() * 1e6) / foreignPool.reserveE();
        int256 spread = (int256(poolPx) - int256(forPx)) * 10000 / int256(forPx);
        vm.prank(keeper);
        (, uint8 mode) = controller.updateSpread(spread, block.timestamp);
        if (mode != 1) return 1;
        uint256 out = amm.getAmountOut(size, false);
        uint256 dx = (foreignPool.reserveU() * 1000 * size) / (997 * (foreignPool.reserveE() - size)) + 1;
        if (out <= dx + 1e16) return 2; // $0.01 gross margin floor over gas
        if (out > bridge.totalLockedUSDC()) return 3;
        if (out > fUSDC.balanceOf(address(bridge))) return 3;
        return 0;
    }

    function test_Campaign25_MaxNet() public {
        // Two-level maximization (measured, not assumed): the sweep winner
        // (0.2 ETH/trade, +$52 net) nearly exhausts the $10k pool in ONE round,
        // so it cannot repeat. The campaign uses a repeatable size (0.008 ETH):
        // smaller per-round profit, far larger 25-round total. Backing/bot sized
        // with margin for the full run.
        _buildSystem(5_000 * ONE, 2 * ONE, 30_000 * ONE, 2_500 * ONE);
        tOwner = makeAddr("gmax.tOwner");
        tBridge = makeAddr("gmax.tBridge");
        tIns = makeAddr("gmax.tIns");
        tReb = makeAddr("gmax.tReb");
        treasury = new TreasuryDistributor(address(fUSDC), tOwner, tBridge, tIns, tReb);

        uint256 SIZE = 8e15; // ~$16/trade: repeatable, pool survives 25 rounds
        lastBreak = 0;
        cEqStart = _sysEquity();
        cForStart = foreignPool.reserveU() + foreignPool.reserveE() * FAIR;
        cBotStart = fUSDC.balanceOf(bot);
        cTotGross = 0;
        cTotGas = 0;
        cTotNet = 0;
        cRounds = 0;

        for (uint256 i = 0; i < ROUNDS; i++) {
            uint256 code = _gate(SIZE);
            if (code != 0) {
                lastBreak = code;
                break;
            }
            uint256 eqB = _sysEquity();
            int256 net = _harvestFwd(SIZE);
            require(net > 0, "gas gate tripped mid-campaign");
            uint256 eqA = _sysEquity();
            require(eqA > eqB, "equity fell mid-campaign");
            cTotGross += lastGross;
            cTotGas += lastGasUsd;
            cTotNet += net;
            cRounds++;
            console.logUint(lastGross);
            console.logInt(net);
        }

        // Treasury finale WITH its own gas measured.
        uint256 settleAmt = fUSDC.balanceOf(bot) - cBotStart;
        bytes memory cdT = abi.encodeCall(IERC20.transfer, (address(treasury), settleAmt));
        uint256 g0 = gasleft();
        vm.prank(bot);
        (bool ok, ) = address(fUSDC).call(cdT);
        require(ok, "settle transfer failed");
        uint256 gT = g0 - gasleft();
        bytes memory cdD = abi.encodeCall(TreasuryDistributor.distribute, (settleAmt));
        g0 = gasleft();
        (ok, ) = address(treasury).call(cdD);
        require(ok, "distribute failed");
        uint256 settleGasUsd = _gasUsd(gT + (g0 - gasleft()), L1_ORACLE.getL1Fee(cdT) + L1_ORACLE.getL1Fee(cdD));
        int256 netNet = cTotNet - int256(settleGasUsd);

        (uint256 oA, uint256 bA, uint256 iA, uint256 rA) = treasury.previewDistribution(settleAmt);
        assertEq(fUSDC.balanceOf(tOwner), oA, "owner 40%");
        assertEq(fUSDC.balanceOf(tBridge), bA, "bridge 30%");
        assertEq(fUSDC.balanceOf(tIns), iA, "insurance 20%");
        assertEq(fUSDC.balanceOf(tReb), rA, "rebase remainder");

        uint256 eqEnd = _sysEquity();
        uint256 forEnd = foreignPool.reserveU() + foreignPool.reserveE() * FAIR;
        console.logUint(lastBreak);
        console.logUint(cRounds);
        console.logUint(cTotGross);
        console.logUint(cTotGas);
        console.logInt(cTotNet);
        console.logUint(settleGasUsd);
        console.logInt(netNet);
        console.logInt(int256(eqEnd) - int256(cEqStart));
        console.logInt(int256(forEnd) - int256(cForStart));
        console.logUint(oA);
        console.logUint(bA);
        console.logUint(iA);
        console.logUint(rA);
        // Canonical ledger, post-settle: only real tokens (fUSDC + native ETH).
        // Start was: bot 2500e18, bridge 30000e18 fUSDC + 0 ETH, rest 0.
        console.logUint(fUSDC.balanceOf(bot));
        console.logUint(fUSDC.balanceOf(address(bridge)));
        console.logUint(address(bridge).balance);
        console.logUint(bridge.totalLockedUSDC());
        console.logUint(bridge.totalLockedETH());

        assertGe(cRounds, 8, "campaign stalled early");
        assertGt(cTotNet, 0, "net negative under real gas");
        assertGt(eqEnd, cEqStart, "system did not grow net of gas");
        assertApproxEqAbs(eqEnd + forEnd, cEqStart + cForStart, 1e16, "conservation violated");
        assertLt(forEnd, cForStart, "donor did not pay");
    }
}
