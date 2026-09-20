// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/BridgeCore.sol";
import "../contracts/InternalAMM.sol";
import "../contracts/ManagedOracle.sol";
import "../contracts/USDS.sol";
import "../contracts/ETHS.sol";

interface IERC20DecimalsDirect {
    function decimals() external view returns (uint8);
}

interface IWETH9Direct is IERC20 {
    function withdraw(uint256 amount) external;
}

interface IUniswapV3PoolDirect {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface IUniswapV3SwapCallbackDirect {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Direct real Uniswap V3 external leg: no ForeignPoolMock.
contract DirectUniswapV3Harvest is Test, IUniswapV3SwapCallbackDirect {
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNI_POOL = 0x6c561B446416E1A00E8E93E221854d6eA4171372;

    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    uint256 internal constant ONE = 1e18;
    uint256 internal constant FAIR = 2500;
    uint256 internal constant USDC_IN = 20e6;

    BridgeCore public bridge;
    InternalAMM public amm;
    ManagedOracle public oracle;
    USDS public usds;
    ETHS public eths;

    address public seeder;
    address public lp;

    receive() external payable {}

    function setUp() public {
        seeder = makeAddr("direct.seeder");
        lp = makeAddr("direct.lp");

        assertEq(IERC20DecimalsDirect(USDC).decimals(), 6, "USDC decimals");
        assertEq(IERC20DecimalsDirect(WETH).decimals(), 18, "WETH decimals");
        assertEq(IUniswapV3PoolDirect(UNI_POOL).token0(), WETH, "pool token0 must be WETH");
        assertEq(IUniswapV3PoolDirect(UNI_POOL).token1(), USDC, "pool token1 must be USDC");

        usds = new USDS();
        eths = new ETHS();
        oracle = new ManagedOracle(2500e6);
        bridge = new BridgeCore(address(usds), address(eths), USDC, address(oracle));
        amm = new InternalAMM(address(usds), address(eths), address(oracle));

        bridge.grantRole(bridge.OPERATOR_ROLE(), seeder);
        bridge.grantRole(bridge.OPERATOR_ROLE(), address(this));
        usds.grantRole(usds.BRIDGE_ROLE(), address(bridge));
        eths.grantRole(eths.BRIDGE_ROLE(), address(bridge));

        // Test capital only. The external trade itself is a direct Uniswap V3 swap;
        // no pool liquidity is pranked out or moved into a mock venue.
        deal(USDC, seeder, 150_000e6);
        deal(USDC, address(this), 500e6);

        vm.startPrank(seeder);
        IERC20(USDC).approve(address(bridge), type(uint256).max);
        bridge.lockUSDCAndMintUSDS(seeder, 150_000e6);
        vm.stopPrank();

        usds.mint(lp, 500_000 * ONE);
        eths.mint(lp, 200 * ONE);
        vm.startPrank(lp);
        usds.approve(address(amm), type(uint256).max);
        eths.approve(address(amm), type(uint256).max);
        amm.addLiquidity(500_000 * ONE, 200 * ONE);
        vm.stopPrank();
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        require(msg.sender == UNI_POOL, "bad callback sender");
        require(amount0Delta < 0, "must receive WETH");
        require(amount1Delta > 0, "must pay USDC");
        IERC20(USDC).transfer(UNI_POOL, uint256(amount1Delta));
    }

    function _nUsdc(uint256 raw6) internal pure returns (uint256) {
        return raw6 * 1e12;
    }

    function _systemEquity() internal view returns (uint256) {
        uint256 canonicalAssets = _nUsdc(IERC20(USDC).balanceOf(address(bridge)))
            + _nUsdc(IERC20(USDC).balanceOf(seeder))
            + _nUsdc(IERC20(USDC).balanceOf(address(this)))
            + IERC20(WETH).balanceOf(address(this)) * FAIR;
        uint256 ethAssets = (address(bridge).balance + address(this).balance) * FAIR;
        uint256 poolAssets = amm.reserveUSDS() + amm.reserveETHS() * FAIR;
        uint256 liabilities = usds.totalSupply() + eths.totalSupply() * FAIR;
        return canonicalAssets + ethAssets + poolAssets - liabilities;
    }

    function _uniPoolValue() internal view returns (uint256) {
        return _nUsdc(IERC20(USDC).balanceOf(UNI_POOL)) + IERC20(WETH).balanceOf(UNI_POOL) * FAIR;
    }

    function _buyWethOnRealUniswapV3(uint256 usdcIn) internal returns (uint256 wethOut) {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        IUniswapV3PoolDirect(UNI_POOL).swap(
            address(this),
            false, // token1 USDC -> token0 WETH
            int256(usdcIn),
            MAX_SQRT_RATIO_MINUS_ONE,
            bytes("")
        );
        wethOut = IERC20(WETH).balanceOf(address(this)) - wethBefore;
    }

    function test_DirectUniswapV3_OneHarvestRound_SystemGrowsPoolLoses() public {
        uint256 systemBefore = _systemEquity();
        uint256 uniBefore = _uniPoolValue();
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        uint256 wethOut = _buyWethOnRealUniswapV3(USDC_IN);
        assertGt(wethOut, 0, "real pool returned no WETH");

        uint256 effectivePx6 = (USDC_IN * 1e18) / wethOut;
        console.logUint(effectivePx6);
        assertLt(effectivePx6, FAIR * 1e6, "real pool not cheaper than internal fair");

        IWETH9Direct(WETH).withdraw(wethOut);
        bridge.lockETHAndMintETHS{value: wethOut}(address(this), wethOut);
        eths.approve(address(amm), wethOut);
        uint256 usdsOut = amm.swap(wethOut, false, 0);
        bridge.burnUSDSAndUnlockUSDC(address(this), usdsOut);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        uint256 systemAfter = _systemEquity();
        uint256 uniAfter = _uniPoolValue();

        console.logUint(wethOut);
        console.logUint(usdcAfter - usdcBefore);
        console.logInt(int256(systemAfter) - int256(systemBefore));
        console.logInt(int256(uniAfter) - int256(uniBefore));
        console.logUint(IERC20(USDC).balanceOf(address(bridge)));

        assertGt(usdcAfter, usdcBefore, "bot did not profit in real USDC");
        assertGt(systemAfter, systemBefore, "system did not grow");
        assertLt(uniAfter, uniBefore, "real Uniswap pool did not lose at fair mark");
    }

    function test_DirectUniswapV3_TwentyHarvestRounds_SystemGrowsPoolLoses() public {
        uint256 systemStart = _systemEquity();
        uint256 uniStart = _uniPoolValue();
        uint256 usdcStart = IERC20(USDC).balanceOf(address(this));
        uint256 rounds;

        for (uint256 i = 0; i < 20; i++) {
            uint256 systemBefore = _systemEquity();
            uint256 uniBefore = _uniPoolValue();
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

            uint256 wethOut = _buyWethOnRealUniswapV3(USDC_IN);
            uint256 effectivePx6 = (USDC_IN * 1e18) / wethOut;
            assertLt(effectivePx6, FAIR * 1e6, "real pool not cheaper than internal fair");

            IWETH9Direct(WETH).withdraw(wethOut);
            bridge.lockETHAndMintETHS{value: wethOut}(address(this), wethOut);
            eths.approve(address(amm), wethOut);
            uint256 usdsOut = amm.swap(wethOut, false, 0);
            bridge.burnUSDSAndUnlockUSDC(address(this), usdsOut);

            uint256 systemAfter = _systemEquity();
            uint256 uniAfter = _uniPoolValue();
            assertGt(IERC20(USDC).balanceOf(address(this)), usdcBefore, "round USDC profit <= 0");
            assertGt(systemAfter, systemBefore, "round system growth <= 0");
            assertLt(uniAfter, uniBefore, "round pool loss missing");
            rounds++;
        }

        uint256 systemEnd = _systemEquity();
        uint256 uniEnd = _uniPoolValue();
        uint256 usdcEnd = IERC20(USDC).balanceOf(address(this));

        console.logUint(rounds);
        console.logUint(usdcEnd - usdcStart);
        console.logInt(int256(systemEnd) - int256(systemStart));
        console.logInt(int256(uniEnd) - int256(uniStart));
        console.logUint(usdcEnd);
        console.logUint(IERC20(USDC).balanceOf(address(bridge)));

        assertEq(rounds, 20, "not all direct Uniswap V3 rounds completed");
        assertGt(usdcEnd, usdcStart, "bot did not profit over 20 rounds");
        assertGt(systemEnd, systemStart, "system did not grow over 20 rounds");
        assertLt(uniEnd, uniStart, "real Uniswap pool did not lose over 20 rounds");
    }
}
