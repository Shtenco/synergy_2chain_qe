// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Pool-bridge: converts synthetic <-> canonical by SWAP, not by vault.
/// @dev Plain x*y=k with a low stable-like fee. The pool NEVER mints: all
///      synthetics come from one-time 1:1 genesis issuance. No locks, no
///      redemptions, no health factor — LPs hold both sides and earn fees.
contract BridgePool is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tokenA; // synthetic side (USDS / ETHS), 18d
    IERC20 public immutable tokenB; // canonical side (USDC 6d / WETH 18d)
    uint256 public immutable feeBps; // e.g. 5 = 0.05%
    uint256 public immutable scaleB; // 10^(18 - decimalsB): normalizes B to 18d

    event Swap(address indexed user, bool aIn, uint256 amountIn, uint256 amountOut);
    event LiquidityAdded(address indexed lp, uint256 aIn, uint256 bIn, uint256 shares);
    event LiquidityRemoved(address indexed lp, uint256 aOut, uint256 bOut, uint256 shares);

    error ZeroAmount();
    error Slippage();
    error NoLiquidity();

    constructor(address _a, address _b, uint256 _feeBps, uint256 _scaleB, string memory name_, string memory sym_)
        ERC20(name_, sym_)
    {
        require(_a != address(0) && _b != address(0), "zero");
        tokenA = IERC20(_a);
        tokenB = IERC20(_b);
        feeBps = _feeBps;
        scaleB = _scaleB;
    }

    function reserves() public view returns (uint256 rA, uint256 rB) {
        rA = tokenA.balanceOf(address(this));
        rB = tokenB.balanceOf(address(this));
    }

    /// @dev Exact-input quote. B leg normalized to 18d via scaleB.
    function getAmountOut(uint256 amountIn, bool aIn) public view returns (uint256) {
        require(amountIn != 0, "amount=0");
        (uint256 rA, uint256 rB) = reserves();
        require(rA != 0 && rB != 0, "no liquidity");
        uint256 feeMul = 10000 - feeBps;
        if (aIn) {
            return (amountIn * feeMul * rB) / (rA * 10000 + amountIn * feeMul); // A->B, B raw units
        }
        uint256 inB18 = amountIn * scaleB;
        uint256 outA18 = (inB18 * feeMul * rA) / (rB * scaleB * 10000 + inB18 * feeMul);
        return outA18;
    }

    function swap(uint256 amountIn, bool aIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        out = getAmountOut(amountIn, aIn);
        require(out >= minOut && out != 0, "slippage");
        if (aIn) {
            tokenA.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenB.safeTransfer(msg.sender, out);
        } else {
            tokenB.safeTransferFrom(msg.sender, address(this), amountIn);
            tokenA.safeTransfer(msg.sender, out);
        }
        emit Swap(msg.sender, aIn, amountIn, out);
    }

    function addLiquidity(uint256 aAmt, uint256 bAmt) external nonReentrant returns (uint256 shares) {
        require(aAmt != 0 && bAmt != 0, "zero");
        (uint256 rA, uint256 rB) = reserves();
        uint256 supply = totalSupply();
        tokenA.safeTransferFrom(msg.sender, address(this), aAmt);
        tokenB.safeTransferFrom(msg.sender, address(this), bAmt);
        if (supply == 0) {
            shares = _sqrt(aAmt * bAmt * scaleB);
        } else {
            uint256 sa = (aAmt * supply) / rA;
            uint256 sb = (bAmt * supply) / rB;
            shares = sa < sb ? sa : sb;
        }
        require(shares != 0, "shares=0");
        _mint(msg.sender, shares);
        emit LiquidityAdded(msg.sender, aAmt, bAmt, shares);
    }

    function removeLiquidity(uint256 shares) external nonReentrant returns (uint256 aOut, uint256 bOut) {
        require(shares != 0 && balanceOf(msg.sender) >= shares, "shares");
        uint256 supply = totalSupply();
        (uint256 rA, uint256 rB) = reserves();
        aOut = (shares * rA) / supply;
        bOut = (shares * rB) / supply;
        _burn(msg.sender, shares);
        tokenA.safeTransfer(msg.sender, aOut);
        tokenB.safeTransfer(msg.sender, bOut);
        emit LiquidityRemoved(msg.sender, aOut, bOut, shares);
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }
}
