// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/v2/SyntheticTokensV2.sol";
import "../contracts/v2/BridgeCoreV2.sol";
import "../contracts/v2/InternalAMMV2.sol";
import "../contracts/v2/EconomicLedgerV2.sol";
import "../contracts/v2/IExternalPriceOracleV2.sol";

contract MockUSDC6V2 is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWETHV2 is ERC20 {
    constructor() ERC20("Mock WETH", "mWETH") {}
}

contract FixedOracleV2 is IExternalPriceOracleV2 {
    uint256 public price = 2500e6;
    bool public stale;
    uint256 public override updatedAt = 1;
    function setStale(bool s) external { stale = s; }
    function getPrice6d() external view returns (uint256) { return price; }
    function isStale() external view returns (bool) { return stale; }
}

contract V2EconomicCoreTest is Test {
    MockUSDC6V2 usdc;
    MockWETHV2 weth;
    USDSV2 usds;
    ETHSV2 eths;
    FixedOracleV2 oracle;
    BridgeCoreV2 bridge;

    function setUp() public {
        usdc = new MockUSDC6V2();
        weth = new MockWETHV2();
        usds = new USDSV2();
        eths = new ETHSV2();
        oracle = new FixedOracleV2();
        bridge = new BridgeCoreV2(address(usds), address(eths), address(usdc), address(oracle));

        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));
        usds.renounceRole(usds.DEFAULT_ADMIN_ROLE(), address(this));
        eths.renounceRole(eths.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function test_DeployerCannotCounterfeitMint() public {
        assertFalse(usds.hasRole(usds.BRIDGE_ROLE(), address(this)));
        vm.expectRevert();
        usds.mint(address(this), 1e18);
    }

    function test_OneToOneBridgeStartsAtExactly100Percent() public {
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(bridge), 1000e6);
        bridge.lockUSDCAndMintUSDS(address(this), 1000e6);

        assertEq(usds.totalSupply(), 1000e18);
        assertEq(usdc.balanceOf(address(bridge)), 1000e6);
        assertEq(bridge.solvencyBps(), 10_000);
        assertEq(bridge.usdsLCRBps(), 10_000);
    }

    function test_150PercentSolvencyRequiresRealExtraEquity() public {
        usdc.mint(address(this), 1500e6);
        usdc.approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(address(this), 1000e6);
        assertEq(bridge.solvencyBps(), 10_000);

        bridge.depositEquityUSDC(500e6);
        assertEq(bridge.solvencyBps(), 15_000);
        assertEq(bridge.usdsLCRBps(), 15_000);
    }

    function test_HardNAVCountsCanonicalEquityNotSyntheticTVL() public {
        usdc.mint(address(this), 1500e6);
        usdc.approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(address(this), 1000e6);
        bridge.depositEquityUSDC(500e6);

        address[] memory tracked = new address[](0);
        EconomicLedgerV2 ledger = new EconomicLedgerV2(
            address(usdc), address(weth), address(usds), address(eths),
            address(oracle), address(bridge), tracked
        );

        assertEq(ledger.hardAssets18(), 1500e18);
        assertEq(ledger.liabilities18(), 1000e18);
        assertEq(ledger.hardNAV18(), int256(500e18));
    }

    function test_AMMReserveIsAlwaysActualTokenBalance() public {
        usdc.mint(address(this), 2500e6);
        usdc.approve(address(bridge), 2500e6);
        bridge.lockUSDCAndMintUSDS(address(this), 2500e6);

        vm.deal(address(this), 1 ether);
        bridge.lockETHAndMintETHS{value: 1 ether}(address(this), 1 ether);

        InternalAMMV2 amm = new InternalAMMV2(address(usds), address(eths), address(oracle));
        usds.approve(address(amm), 2500e18);
        eths.approve(address(amm), 1 ether);
        amm.addLiquidity(2500e18, 1 ether);

        (uint256 ru, uint256 re) = amm.reserves();
        assertEq(ru, usds.balanceOf(address(amm)));
        assertEq(re, eths.balanceOf(address(amm)));
        assertEq(ru, 2500e18);
        assertEq(re, 1 ether);
    }

    function test_StaleOracleStopsBridgeMutation() public {
        usdc.mint(address(this), 1e6);
        usdc.approve(address(bridge), 1e6);
        oracle.setStale(true);

        vm.expectRevert(BridgeCoreV2.StaleOracle.selector);
        bridge.lockUSDCAndMintUSDS(address(this), 1e6);
    }
}
