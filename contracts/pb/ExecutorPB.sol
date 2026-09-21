// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BridgePool.sol";
import "../v2/InternalAMMV2.sol";
import "../v2/IExternalVenueV2.sol";

/// @notice Pure swap-router arbitrage: NO vault, NO locks, NO mint/burn.
/// @dev Route EXT_BUY_INT_SELL: USDC -> WETH (real venue) -> ETHS (poolB)
///      -> USDS (internal AMM) -> USDC (poolA). INT_BUY_EXT_SELL mirrored.
///      Profit = realized canonical balance delta, gated on-chain.
contract ExecutorPB is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");

    enum Direction {
        EXT_BUY_INT_SELL,
        INT_BUY_EXT_SELL
    }

    BridgePool public immutable poolA; // USDS/USDC
    BridgePool public immutable poolB; // ETHS/WETH
    InternalAMMV2 public immutable amm; // USDS/ETHS
    IExternalVenueV2 public immutable venue; // real Uniswap V3
    IERC20 public immutable usdc;
    IERC20 public immutable weth;
    IERC20 public immutable usds;
    IERC20 public immutable eths;

    event ArbitrageExecuted(Direction indexed direction, uint256 input, uint256 output, uint256 profit);

    error NotProfitable(uint256 output, uint256 required);
    error ResidualBalance();
    error DeadlineExpired(uint256 deadline, uint256 nowTs);

    constructor(
        address _poolA,
        address _poolB,
        address _amm,
        address _venue,
        address _usdc,
        address _weth,
        address _usds,
        address _eths
    ) {
        require(
            _poolA != address(0) && _poolB != address(0) && _amm != address(0) && _venue != address(0)
                && _usdc != address(0) && _weth != address(0) && _usds != address(0) && _eths != address(0),
            "zero"
        );
        poolA = BridgePool(_poolA);
        poolB = BridgePool(_poolB);
        amm = InternalAMMV2(_amm);
        venue = IExternalVenueV2(_venue);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        usds = IERC20(_usds);
        eths = IERC20(_eths);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BOT_ROLE, msg.sender);
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        _;
    }

    function executeExternalBuyInternalSell(
        uint256 usdcIn,
        uint256 minWethOut,
        uint256 minEthsOut,
        uint256 minUsdsOut,
        uint256 minUsdcOut,
        uint256 minProfitUSDC,
        uint256 deadline
    ) external onlyRole(BOT_ROLE) nonReentrant beforeDeadline(deadline) returns (uint256 profit) {
        require(usdcIn != 0, "input=0");
        uint256 start = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        _approveExact(usdc, address(venue), usdcIn);
        uint256 wethOut = venue.buyWETHExactUSDC(usdcIn, minWethOut, 0);

        _approveExact(weth, address(poolB), wethOut);
        uint256 ethsOut = poolB.swap(wethOut, false, minEthsOut); // WETH -> ETHS

        _approveExact(eths, address(amm), ethsOut);
        uint256 usdsOut = amm.swap(ethsOut, false, minUsdsOut); // ETHS -> USDS

        _approveExact(usds, address(poolA), usdsOut);
        poolA.swap(usdsOut, true, minUsdcOut); // USDS -> USDC, output measured by balance delta

        profit = _settle(start, usdcIn, minProfitUSDC, Direction.EXT_BUY_INT_SELL);
    }

    function executeInternalBuyExternalSell(
        uint256 usdcIn,
        uint256 minUsdsOut,
        uint256 minEthsOut,
        uint256 minWethOut,
        uint256 minUsdcOut,
        uint256 minProfitUSDC,
        uint256 deadline
    ) external onlyRole(BOT_ROLE) nonReentrant beforeDeadline(deadline) returns (uint256 profit) {
        require(usdcIn != 0, "input=0");
        uint256 start = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        _approveExact(usdc, address(poolA), usdcIn);
        uint256 usdsOut = poolA.swap(usdcIn, false, minUsdsOut); // USDC -> USDS

        _approveExact(usds, address(amm), usdsOut);
        uint256 ethsOut = amm.swap(usdsOut, true, minEthsOut); // USDS -> ETHS

        _approveExact(eths, address(poolB), ethsOut);
        uint256 wethOut = poolB.swap(ethsOut, true, minWethOut); // ETHS -> WETH

        _approveExact(weth, address(venue), wethOut);
        venue.sellWETHExactInput(wethOut, minUsdcOut, 0); // WETH -> USDC, output measured by balance delta

        profit = _settle(start, usdcIn, minProfitUSDC, Direction.INT_BUY_EXT_SELL);
    }

    function _settle(uint256 start, uint256 usdcIn, uint256 minProfitUSDC, Direction dir)
        internal
        returns (uint256 profit)
    {
        uint256 finish = usdc.balanceOf(address(this));
        uint256 output = finish - start;
        uint256 required = usdcIn + minProfitUSDC;
        if (output < required) revert NotProfitable(output, required);
        profit = output - usdcIn;
        _assertNoDust();
        usdc.safeTransfer(msg.sender, output);
        emit ArbitrageExecuted(dir, usdcIn, output, profit);
    }

    function _approveExact(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current != 0) token.safeApprove(spender, 0);
        token.safeApprove(spender, amount);
    }

    /// @dev USDC is excluded: it holds the payout before forwarding to the
    ///      caller (same as V2 executor, which checks only synthetics).
    function _assertNoDust() internal view {
        if (
            weth.balanceOf(address(this)) != 0 || usds.balanceOf(address(this)) != 0
                || eths.balanceOf(address(this)) != 0
        ) revert ResidualBalance();
    }

    receive() external payable {}
}
