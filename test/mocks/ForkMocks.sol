// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice 18-decimal mock canonical asset (accounting unit only, NOT real Base USDC).
/// @dev Real Base USDC has 6 decimals while USDS has 18; the production bridge
///      mixes them 1:1 (separate documented accounting bug). This mock keeps fork
///      P&L math readable. Tests still execute on Base fork state.
contract MockCanonicalToken is ERC20 {
    constructor() ERC20("Mock Canonical", "mUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal WETH9: 1 mWETH == 1 native ETH, redeemable at any time.
contract MockWETH9 is ERC20 {
    constructor() ERC20("Mock WETH", "mWETH") {}
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
    }
    receive() external payable {}
}

/**
 * @notice Huge foreign pool, deliberately EXCLUDED from system books.
 * @dev Plain x*y=k, 0.3% fee. Used as the external donor counterparty.
 */
contract ForeignPoolMock {
    IERC20 public immutable fUSDC;
    MockWETH9 public immutable mWETH;
    uint256 public reserveU;
    uint256 public reserveE;

    constructor(address _u, address _w) {
        fUSDC = IERC20(_u);
        mWETH = MockWETH9(payable(_w));
    }

    function seed(uint256 amountU, uint256 amountE) external {
        fUSDC.transferFrom(msg.sender, address(this), amountU);
        mWETH.transferFrom(msg.sender, address(this), amountE);
        reserveU += amountU;
        reserveE += amountE;
    }

    /// @notice Buy mWETH with fUSDC (exact in). Returns mWETH out.
    function swapUforE(uint256 dx) external returns (uint256 out) {
        uint256 dxFee = dx * 997;
        out = (dxFee * reserveE) / (reserveU * 1000 + dxFee);
        require(out > 0 && out <= reserveE, "bad out");
        fUSDC.transferFrom(msg.sender, address(this), dx);
        reserveU += dx;
        reserveE -= out;
        mWETH.transfer(msg.sender, out);
    }

    /// @notice Sell mWETH for fUSDC (exact in). Returns fUSDC out.
    function swapEforU(uint256 dx) external returns (uint256 out) {
        uint256 dxFee = dx * 997;
        out = (dxFee * reserveU) / (reserveE * 1000 + dxFee);
        require(out > 0 && out <= reserveU, "bad out");
        mWETH.transferFrom(msg.sender, address(this), dx);
        reserveE += dx;
        reserveU -= out;
        fUSDC.transfer(msg.sender, out);
    }
}
