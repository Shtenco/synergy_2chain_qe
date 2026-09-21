// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BridgeCoreV2.sol";
import "./InternalAMMV2.sol";
import "./IExternalVenueV2.sol";

interface IWETH9V2 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Atomic two-way arbitrage executor.
/// @dev Route names describe the actual direction. Oracle spread is never booked as profit.
contract ArbitrageExecutorV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");

    enum Direction {
        EXT_BUY_INT_SELL,
        INT_BUY_EXT_SELL
    }

    BridgeCoreV2 public immutable bridge;
    InternalAMMV2 public immutable amm;
    IExternalVenueV2 public immutable venue;
    IERC20 public immutable usdc;
    IWETH9V2 public immutable weth;
    IERC20 public immutable usds;
    IERC20 public immutable eths;

    event ArbitrageExecuted(
        Direction indexed direction,
        uint256 canonicalInput,
        uint256 canonicalOutput,
        uint256 realizedProfit
    );

    error NotProfitable(uint256 output, uint256 required);
    error ResidualSyntheticBalance();
    error DeadlineExpired(uint256 deadline, uint256 nowTs);

    constructor(
        address _bridge,
        address _amm,
        address _venue,
        address _usdc,
        address _weth,
        address _usds,
        address _eths
    ) {
        require(
            _bridge != address(0) && _amm != address(0) && _venue != address(0) &&
            _usdc != address(0) && _weth != address(0) &&
            _usds != address(0) && _eths != address(0),
            "zero"
        );
        bridge = BridgeCoreV2(payable(_bridge));
        amm = InternalAMMV2(_amm);
        venue = IExternalVenueV2(_venue);
        usdc = IERC20(_usdc);
        weth = IWETH9V2(_weth);
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
        uint256 minInternalUSDSOut18,
        uint160 sqrtPriceLimitX96,
        uint256 minProfitUSDC,
        uint256 deadline
    )
        external
        onlyRole(BOT_ROLE)
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 profit)
    {
        require(usdcIn != 0, "input=0");

        uint256 start = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        _approveExact(usdc, address(venue), usdcIn);
        uint256 wethOut =
            venue.buyWETHExactUSDC(usdcIn, minWethOut, sqrtPriceLimitX96);

        weth.withdraw(wethOut);
        bridge.lockETHAndMintETHS{value: wethOut}(address(this), wethOut);

        _approveExact(eths, address(amm), wethOut);
        uint256 usdsOut = amm.swap(wethOut, false, minInternalUSDSOut18);

        bridge.burnUSDSAndUnlockUSDC(address(this), usdsOut);

        (, uint256 realized) = _settleBuy(start, usdcIn, minProfitUSDC);
        profit = realized;
    }

    function executeInternalBuyExternalSell(
        uint256 usdcIn,
        uint256 minInternalETHSOut,
        uint256 minExternalUSDCOut,
        uint160 sqrtPriceLimitX96,
        uint256 minProfitUSDC,
        uint256 deadline
    )
        external
        onlyRole(BOT_ROLE)
        nonReentrant
        beforeDeadline(deadline)
        returns (uint256 profit)
    {
        require(usdcIn != 0, "input=0");

        uint256 start = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        uint256 usdcOut = _routeInternalBuy(
            usdcIn,
            minInternalETHSOut,
            minExternalUSDCOut,
            sqrtPriceLimitX96
        );

        (, uint256 realized) =
            _settleSell(start, usdcIn, minProfitUSDC, usdcOut, minExternalUSDCOut);
        profit = realized;
    }

    function _routeInternalBuy(
        uint256 usdcIn,
        uint256 minInternalETHSOut,
        uint256 minExternalUSDCOut,
        uint160 sqrtPriceLimitX96
    ) internal returns (uint256 usdcOut) {
        _approveExact(usdc, address(bridge), usdcIn);
        bridge.lockUSDCAndMintUSDS(address(this), usdcIn);

        uint256 usdsAmount = usdcIn * bridge.usdcScale();
        _approveExact(usds, address(amm), usdsAmount);
        uint256 ethsOut = amm.swap(usdsAmount, true, minInternalETHSOut);

        uint256 nativeBefore = address(this).balance;
        bridge.burnETHSAndUnlockETH(address(this), ethsOut);
        uint256 nativeReceived = address(this).balance - nativeBefore;

        weth.deposit{value: nativeReceived}();
        _approveExact(IERC20(address(weth)), address(venue), nativeReceived);
        usdcOut = venue.sellWETHExactInput(
            nativeReceived,
            minExternalUSDCOut,
            sqrtPriceLimitX96
        );
    }

    function _settleBuy(
        uint256 start,
        uint256 usdcIn,
        uint256 minProfitUSDC
    ) internal returns (uint256 canonicalOutput, uint256 profit) {
        uint256 finish = usdc.balanceOf(address(this));
        canonicalOutput = finish - start;
        uint256 required = usdcIn + minProfitUSDC;
        if (canonicalOutput < required) revert NotProfitable(canonicalOutput, required);

        profit = canonicalOutput - usdcIn;
        _assertNoSyntheticDust();

        usdc.safeTransfer(msg.sender, canonicalOutput);
        emit ArbitrageExecuted(
            Direction.EXT_BUY_INT_SELL,
            usdcIn,
            canonicalOutput,
            profit
        );
    }

    function _settleSell(
        uint256 start,
        uint256 usdcIn,
        uint256 minProfitUSDC,
        uint256 usdcOut,
        uint256 minExternalUSDCOut
    ) internal returns (uint256 canonicalOutput, uint256 profit) {
        uint256 finish = usdc.balanceOf(address(this));
        canonicalOutput = finish - start;
        uint256 required = usdcIn + minProfitUSDC;
        if (canonicalOutput < required || usdcOut < minExternalUSDCOut) {
            revert NotProfitable(canonicalOutput, required);
        }

        profit = canonicalOutput - usdcIn;
        _assertNoSyntheticDust();

        usdc.safeTransfer(msg.sender, canonicalOutput);
        emit ArbitrageExecuted(
            Direction.INT_BUY_EXT_SELL,
            usdcIn,
            canonicalOutput,
            profit
        );
    }

    function _approveExact(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current != 0) token.safeApprove(spender, 0);
        token.safeApprove(spender, amount);
    }

    function _assertNoSyntheticDust() internal view {
        if (usds.balanceOf(address(this)) != 0 || eths.balanceOf(address(this)) != 0) {
            revert ResidualSyntheticBalance();
        }
    }

    receive() external payable {}
}
