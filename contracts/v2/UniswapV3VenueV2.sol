// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IExternalVenueV2.sol";

interface IUniswapV3PoolV2 {
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

interface IUniswapV3SwapCallbackV2 {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

/// @notice Direct exact-input USDC/WETH adapter for one whitelisted V3 pool.
/// @dev The caller transfers input to this adapter inside each trade.
///      The adapter pays the pool only what the callback requires and returns
///      the exact output to the caller. No oracle or reserve-ratio pricing.
contract UniswapV3VenueV2 is IExternalVenueV2, IUniswapV3SwapCallbackV2 {
    using SafeERC20 for IERC20;

    uint160 private constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_ONE =
        1461446703485210103287273052203988822378723970341;

    IUniswapV3PoolV2 public immutable pool;
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    bool public immutable usdcIsToken0;

    error InvalidPoolTokens();
    error UnauthorizedCallback();
    error Slippage();
    error BadDelta();

    constructor(address _pool, address _usdc, address _weth) {
        require(_pool != address(0) && _usdc != address(0) && _weth != address(0), "zero");
        pool = IUniswapV3PoolV2(_pool);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);

        address t0 = pool.token0();
        address t1 = pool.token1();
        if (!((t0 == _usdc && t1 == _weth) || (t0 == _weth && t1 == _usdc))) {
            revert InvalidPoolTokens();
        }
        usdcIsToken0 = t0 == _usdc;
    }

    function buyWETHExactUSDC(uint256 usdcIn, uint256 minWethOut)
        external override returns (uint256 wethOut)
    {
        require(usdcIn != 0, "input=0");
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        bool zeroForOne = usdcIsToken0;
        (int256 a0, int256 a1) = pool.swap(
            address(this),
            zeroForOne,
            int256(usdcIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encode(msg.sender)
        );

        int256 outDelta = zeroForOne ? a1 : a0;
        if (outDelta >= 0) revert BadDelta();
        wethOut = uint256(-outDelta);
        if (wethOut < minWethOut) revert Slippage();
        weth.safeTransfer(msg.sender, wethOut);
    }

    function sellWETHExactInput(uint256 wethIn, uint256 minUsdcOut)
        external override returns (uint256 usdcOut)
    {
        require(wethIn != 0, "input=0");
        weth.safeTransferFrom(msg.sender, address(this), wethIn);

        bool zeroForOne = !usdcIsToken0;
        (int256 a0, int256 a1) = pool.swap(
            address(this),
            zeroForOne,
            int256(wethIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encode(msg.sender)
        );

        int256 outDelta = zeroForOne ? a1 : a0;
        if (outDelta >= 0) revert BadDelta();
        usdcOut = uint256(-outDelta);
        if (usdcOut < minUsdcOut) revert Slippage();
        usdc.safeTransfer(msg.sender, usdcOut);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external override {
        if (msg.sender != address(pool)) revert UnauthorizedCallback();

        if (amount0Delta > 0) {
            IERC20(pool.token0()).safeTransfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(pool.token1()).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }
}
