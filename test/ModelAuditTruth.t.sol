// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./mocks/ForkMocks.sol";
import "../contracts/ArbitrageExecutor.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/ETHS.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/TreasuryDistributor.sol";
import "../contracts/USDS.sol";

/// @notice Adversarial checks separating executable value from reported value.
contract ModelAuditTruth is Test {
    uint256 internal constant ONE = 1e18;

    MockCanonicalToken internal canonical;
    USDS internal usds;
    ETHS internal eths;
    ManagedOracle internal oracle;
    BridgeCore internal bridge;
    InternalAMM internal amm;
    TreasuryDistributor internal treasury;
    ArbitrageExecutor internal executor;

    address internal honest = makeAddr("honest");
    address internal lp = makeAddr("lp");

    function setUp() public {
        canonical = new MockCanonicalToken();
        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), address(canonical), address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));
        treasury = new TreasuryDistributor(
            address(canonical), makeAddr("owner"), makeAddr("reserve"),
            makeAddr("insurance"), makeAddr("rebase")
        );
        executor = new ArbitrageExecutor(
            address(bridge), address(amm), address(treasury), address(oracle),
            address(canonical), address(eths), address(usds), address(eths)
        );

        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(executor));

        usds.mint(lp, 500_000 * ONE);
        eths.mint(lp, 200 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(500_000 * ONE, 200 * ONE);
        vm.stopPrank();
    }

    function test_QuotedCycleAProfitIsNotExecutable() public {
        oracle.setGradient(-500);
        (bool quotedProfitable, uint256 quotedProfit) = executor.isCycleAProfitable(ONE);

        assertTrue(quotedProfitable, "oracle quote should claim profit");
        assertEq(quotedProfit, 125 * ONE, "quoted spread is $125");

        vm.expectRevert(abi.encodeWithSelector(BridgeCore.IncorrectETHValue.selector, 0, ONE));
        executor.executeCycleA(ONE, 1);

        assertEq(executor.totalCyclesExecuted(), 0, "failed route must realize no cycle");
        assertEq(executor.totalProfitGenerated(), 0, "failed route must realize no profit");
    }

    function test_RebaseCreatesPhantomNAVWithoutAssets() public {
        uint256 balanceBefore = usds.balanceOf(address(amm));
        uint256 reserveBefore = amm.reserveUSDS();
        uint256 navBefore = amm.getNAVPerShare();

        amm.rebaseLP(lp, 100_000 * ONE);

        assertEq(usds.balanceOf(address(amm)), balanceBefore, "rebase transferred no USDS");
        assertEq(amm.reserveUSDS(), reserveBefore + 100_000 * ONE, "accounting reserve increased");
        assertGt(amm.getNAVPerShare(), navBefore, "reported NAV increased without assets");
        assertGt(amm.reserveUSDS(), usds.balanceOf(address(amm)), "reserve exceeds redeemable balance");
    }

    function test_RetainedRolesCanRedeemCounterfeitUSDSAgainstHonestBacking() public {
        canonical.mint(honest, 100_000 * ONE);
        bridge.grantRole(bridge.OPERATOR_ROLE(), honest);

        vm.startPrank(honest);
        canonical.approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(honest, 100_000 * ONE);
        vm.stopPrank();

        // The token deployer retained BRIDGE_ROLE and the bridge deployer retained
        // OPERATOR_ROLE, so these tokens were never backed by an additional deposit.
        usds.mint(address(this), 100_000 * ONE);
        bridge.burnUSDSAndUnlockUSDC(address(this), 100_000 * ONE);

        assertEq(canonical.balanceOf(address(this)), 100_000 * ONE, "honest backing was withdrawn");
        assertEq(canonical.balanceOf(address(bridge)), 0, "bridge reserve was drained");
        assertEq(usds.balanceOf(honest), 100_000 * ONE, "honest holder still owns claims");
        assertEq(bridge.totalMintedUSDS(), 0, "bridge forgot the honest liability");

        vm.prank(honest);
        vm.expectRevert(abi.encodeWithSelector(BridgeCore.InsufficientBalance.selector, 0, 100_000 * ONE));
        bridge.burnUSDSAndUnlockUSDC(honest, 100_000 * ONE);
    }
}
