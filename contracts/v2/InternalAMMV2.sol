// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./IExternalPriceOracleV2.sol";

/// @notice Plain x*y=k USDSV2/ETHSV2 AMM with no synthetic reserve mutation.
/// @dev Reserves are always the REAL ERC20 balances held by this contract.
contract InternalAMMV2 is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_6D_TO_18 = 1e12;

    IERC20 public immutable usds;
    IERC20 public immutable eths;
    IExternalPriceOracleV2 public immutable oracle;

    event Swap(address indexed user, bool usdsIn, uint256 amountIn, uint256 amountOut);
    event LiquidityAdded(address indexed lp, uint256 usdsIn, uint256 ethsIn, uint256 shares);
    event LiquidityRemoved(address indexed lp, uint256 usdsOut, uint256 ethsOut, uint256 shares);

    constructor(address _usds, address _eths, address _oracle)
        ERC20("LP-USDS2-ETHS2", "LP2")
    {
        require(_usds != address(0) && _eths != address(0) && _oracle != address(0), "zero");
        usds = IERC20(_usds);
        eths = IERC20(_eths);
        oracle = IExternalPriceOracleV2(_oracle);
    }

    function reserves() public view returns (uint256 reserveUSDS, uint256 reserveETHS) {
        reserveUSDS = usds.balanceOf(address(this));
        reserveETHS = eths.balanceOf(address(this));
    }

    function getAmountOut(uint256 amountIn, bool usdsIn) public view returns (uint256) {
        require(amountIn != 0, "amount=0");
        (uint256 u, uint256 e) = reserves();
        uint256 inWithFee = amountIn * 997;
        if (usdsIn) {
            require(u != 0 && e != 0, "no liquidity");
            return inWithFee * e / (u * 1000 + inWithFee);
        }
        require(u != 0 && e != 0, "no liquidity");
        return inWithFee * u / (e * 1000 + inWithFee);
    }

    function swap(uint256 amountIn, bool usdsIn, uint256 minOut)
        external nonReentrant returns (uint256 amountOut)
    {
        amountOut = getAmountOut(amountIn, usdsIn);
        require(amountOut >= minOut && amountOut != 0, "slippage");

        IERC20 tokenIn = usdsIn ? usds : eths;
        IERC20 tokenOut = usdsIn ? eths : usds;

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, usdsIn, amountIn, amountOut);
    }

    function addLiquidity(uint256 usdsAmount, uint256 ethsAmount)
        external nonReentrant returns (uint256 shares)
    {
        require(usdsAmount != 0 && ethsAmount != 0, "zero");
        (uint256 u0, uint256 e0) = reserves();
        uint256 supply = totalSupply();

        usds.safeTransferFrom(msg.sender, address(this), usdsAmount);
        eths.safeTransferFrom(msg.sender, address(this), ethsAmount);

        if (supply == 0) {
            shares = _sqrt(usdsAmount * ethsAmount);
        } else {
            require(u0 != 0 && e0 != 0, "bad reserves");
            uint256 su = usdsAmount * supply / u0;
            uint256 se = ethsAmount * supply / e0;
            shares = su < se ? su : se;
        }
        require(shares != 0, "shares=0");
        _mint(msg.sender, shares);
        emit LiquidityAdded(msg.sender, usdsAmount, ethsAmount, shares);
    }

    function removeLiquidity(uint256 shares)
        external nonReentrant returns (uint256 usdsOut, uint256 ethsOut)
    {
        require(shares != 0 && balanceOf(msg.sender) >= shares, "shares");
        uint256 supply = totalSupply();
        (uint256 u, uint256 e) = reserves();
        usdsOut = shares * u / supply;
        ethsOut = shares * e / supply;

        _burn(msg.sender, shares);
        usds.safeTransfer(msg.sender, usdsOut);
        eths.safeTransfer(msg.sender, ethsOut);
        emit LiquidityRemoved(msg.sender, usdsOut, ethsOut, shares);
    }

    function navPerShare18() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        (uint256 u, uint256 e) = reserves();
        uint256 p6 = oracle.getPrice6d();
        uint256 value18 = u + e * p6 * PRICE_6D_TO_18 / 1e18;
        return value18 * 1e18 / supply;
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
