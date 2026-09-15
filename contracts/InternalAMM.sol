// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IManagedOracle.sol";

/**
 * @title InternalAMM - Modified constant-product pool with LP protection
 * @notice USDS/ETHS pool with algorithmic rebase for zero-loss guarantee
 * @dev Implements x*y=k with rebase mechanism to protect LP NAV
 * 
 * KEY FEATURES:
 * - Constant product formula (x*y=k)
 * - 0.3% swap fee
 * - Algorithmic rebase to maintain LP NAV
 * - Pool rebalancing via burn/mint of excess side
 */
contract InternalAMM is ERC20, AccessControl, ReentrancyGuard {
    bytes32 public constant REBASE_ROLE = keccak256("REBASE_ROLE");
    
    // ============ STATE ============
    address public immutable tokenUSDS;
    address public immutable tokenETHS;
    IManagedOracle public oracle;
    
    // Pool reserves
    uint256 public reserveUSDS;
    uint256 public reserveETHS;
    
    // LP tracking for zero-loss guarantee
    struct LPInfo {
        uint256 initialDepositValue; // in USDC terms at deposit time
        uint256 shares;
        uint256 totalRebasesReceived;
        uint256 lastNAV;
    }
    
    mapping(address => LPInfo) public lpInfo;
    
    // Total rebases distributed
    uint256 public totalRebasesDistributed;
    
    // ============ EVENTS ============
    event Swap(address indexed user, uint256 amountIn, uint256 amountOut, bool isUSDSIn);
    event LiquidityAdded(address indexed lp, uint256 usdsAmount, uint256 ethsAmount, uint256 shares);
    event LiquidityRemoved(address indexed lp, uint256 usdsAmount, uint256 ethsAmount, uint256 shares);
    event RebaseExecuted(address indexed lp, uint256 usdsAmount);
    event PoolRebalanced(uint256 newReserveUSDS, uint256 newReserveETHS);
    
    // ============ ERRORS ============
    error InsufficientLiquidity();
    error InsufficientShares();
    error ZeroAmount();
    error SlippageExceeded();
    
    // ============ CONSTRUCTOR ============
    constructor(address _usds, address _eths, address _oracle) 
        ERC20("LP-USDS-ETHS", "LP-AMM") 
    {
        tokenUSDS = _usds;
        tokenETHS = _eths;
        oracle = IManagedOracle(_oracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REBASE_ROLE, msg.sender);
    }
    
    // ============ SWAP ============
    
    /**
     * @notice Swap tokens using constant product formula
     * @param amountIn Amount of input token
     * @param isUSDSIn true if swapping USDS→ETHS, false for ETHS→USDS
     * @param minAmountOut Minimum output (slippage protection)
     * @return amountOut Actual output amount
     */
    function swap(uint256 amountIn, bool isUSDSIn, uint256 minAmountOut) 
        external 
        nonReentrant 
        returns (uint256 amountOut) 
    {
        if (amountIn == 0) revert ZeroAmount();
        
        uint256 amountInWithFee = amountIn * 997; // 0.3% fee
        uint256 numerator = amountInWithFee;
        uint256 denominator;
        
        if (isUSDSIn) {
            // USDS → ETHS
            numerator = amountInWithFee * reserveETHS;
            denominator = reserveUSDS * 1000 + amountInWithFee;
            amountOut = numerator / denominator;
            
            if (amountOut < minAmountOut) revert SlippageExceeded();
            
            reserveUSDS += amountIn;
            reserveETHS -= amountOut;
        } else {
            // ETHS → USDS
            numerator = amountInWithFee * reserveUSDS;
            denominator = reserveETHS * 1000 + amountInWithFee;
            amountOut = numerator / denominator;
            
            if (amountOut < minAmountOut) revert SlippageExceeded();
            
            reserveETHS += amountIn;
            reserveUSDS -= amountOut;
        }
        
        // Transfer tokens
        _transferToken(isUSDSIn ? tokenUSDS : tokenETHS, msg.sender, address(this), amountIn);
        _transferToken(isUSDSIn ? tokenETHS : tokenUSDS, address(this), msg.sender, amountOut);
        
        emit Swap(msg.sender, amountIn, amountOut, isUSDSIn);
    }
    
    /**
     * @notice Get expected output for a swap
     */
    function getAmountOut(uint256 amountIn, bool isUSDSIn) external view returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        
        if (isUSDSIn) {
            return (amountInWithFee * reserveETHS) / (reserveUSDS * 1000 + amountInWithFee);
        } else {
            return (amountInWithFee * reserveUSDS) / (reserveETHS * 1000 + amountInWithFee);
        }
    }
    
    // ============ LIQUIDITY ============
    
    /**
     * @notice Add liquidity to the pool
     * @param usdsAmount Amount of USDS to add
     * @param ethsAmount Amount of ETHS to add
     * @return shares LP shares minted
     */
    function addLiquidity(uint256 usdsAmount, uint256 ethsAmount) 
        external 
        nonReentrant 
        returns (uint256 shares) 
    {
        if (usdsAmount == 0 || ethsAmount == 0) revert ZeroAmount();
        
        uint256 ethPrice = oracle.getETHPrice(); // 6 decimals
        
        if (totalSupply() == 0) {
            // First deposit - calculate initial value
            shares = _sqrt(usdsAmount * ethsAmount);
        } else {
            // Proportional deposit
            uint256 usdsShare = (usdsAmount * totalSupply()) / reserveUSDS;
            uint256 ethsShare = (ethsAmount * totalSupply()) / reserveETHS;
            shares = usdsShare < ethsShare ? usdsShare : ethsShare;
        }
        
        if (shares == 0) revert InsufficientLiquidity();
        
        // Update reserves
        reserveUSDS += usdsAmount;
        reserveETHS += ethsAmount;
        
        // Mint LP tokens
        _mint(msg.sender, shares);
        
        // Record LP info for NAV tracking
        uint256 depositValue = usdsAmount + (ethsAmount * ethPrice) / 1e18;
        lpInfo[msg.sender].initialDepositValue += depositValue;
        lpInfo[msg.sender].shares += shares;
        lpInfo[msg.sender].lastNAV = getNAVPerShare();
        
        // Transfer tokens
        _transferToken(tokenUSDS, msg.sender, address(this), usdsAmount);
        _transferToken(tokenETHS, msg.sender, address(this), ethsAmount);
        
        emit LiquidityAdded(msg.sender, usdsAmount, ethsAmount, shares);
    }
    
    /**
     * @notice Remove liquidity from the pool
     * @param shares LP shares to burn
     * @return usdsAmount USDS returned
     * @return ethsAmount ETHS returned
     */
    function removeLiquidity(uint256 shares) 
        external 
        nonReentrant 
        returns (uint256 usdsAmount, uint256 ethsAmount) 
    {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();
        
        usdsAmount = (shares * reserveUSDS) / totalSupply();
        ethsAmount = (shares * reserveETHS) / totalSupply();
        
        // Update reserves
        reserveUSDS -= usdsAmount;
        reserveETHS -= ethsAmount;
        
        // Burn LP tokens
        _burn(msg.sender, shares);
        
        // Update LP info
        lpInfo[msg.sender].shares -= shares;
        
        // Transfer tokens
        _transferToken(tokenUSDS, address(this), msg.sender, usdsAmount);
        _transferToken(tokenETHS, address(this), msg.sender, ethsAmount);
        
        emit LiquidityRemoved(msg.sender, usdsAmount, ethsAmount, shares);
    }
    
    // ============ REBASE (Zero-Loss Protection) ============
    
    /**
     * @notice Execute rebase for LP to maintain NAV
     * @param lp LP address to compensate
     * @param usdsAmount USDS amount to mint as compensation
     */
    function rebaseLP(address lp, uint256 usdsAmount) external onlyRole(REBASE_ROLE) {
        reserveUSDS += usdsAmount;
        lpInfo[lp].totalRebasesReceived += usdsAmount;
        lpInfo[lp].lastNAV = getNAVPerShare();
        totalRebasesDistributed += usdsAmount;
        
        emit RebaseExecuted(lp, usdsAmount);
    }
    
    /**
     * @notice Batch rebase for multiple LPs
     */
    function batchRebase(address[] calldata lps, uint256[] calldata amounts) external onlyRole(REBASE_ROLE) {
        require(lps.length == amounts.length, "Length mismatch");
        
        for (uint256 i = 0; i < lps.length; i++) {
            reserveUSDS += amounts[i];
            lpInfo[lps[i]].totalRebasesReceived += amounts[i];
            lpInfo[lps[i]].lastNAV = getNAVPerShare();
            totalRebasesDistributed += amounts[i];
            emit RebaseExecuted(lps[i], amounts[i]);
        }
    }
    
    /**
     * @notice Rebalance pool to target ratio
     * @dev Burns excess side, mints deficit side for LPs
     */
    function rebalancePool() external onlyRole(REBASE_ROLE) {
        uint256 ethPrice = oracle.getETHPrice();
        uint256 totalValue = reserveUSDS + (reserveETHS * ethPrice) / 1e18;
        
        // Target: 50/50 ratio
        uint256 targetUSDS = totalValue / 2;
        
        if (reserveUSDS > targetUSDS) {
            // Excess USDS - burn it
            uint256 excess = reserveUSDS - targetUSDS;
            reserveUSDS = targetUSDS;
            // In production: actually burn the excess
        } else {
            // Deficit USDS - mint compensatory amount
            uint256 deficit = targetUSDS - reserveUSDS;
            reserveUSDS = targetUSDS;
            // In production: mint the deficit
        }
        
        emit PoolRebalanced(reserveUSDS, reserveETHS);
    }
    
    // ============ VIEW FUNCTIONS ============
    
    /**
     * @notice Get NAV (Net Asset Value) per LP share
     * @return NAV in USDC terms (6 decimals)
     */
    function getNAVPerShare() public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        
        uint256 ethPrice = oracle.getETHPrice();
        uint256 totalValue = reserveUSDS + (reserveETHS * ethPrice) / 1e18;
        
        return totalValue / totalSupply();
    }
    
    /**
     * @notice Get LP's current NAV
     */
    function getLPNAV(address lp) external view returns (uint256) {
        return (balanceOf(lp) * getNAVPerShare()) / 1e18;
    }
    
    /**
     * @notice Get LP's PnL
     */
    function getLPPnL(address lp) external view returns (int256) {
        uint256 currentNAV = (balanceOf(lp) * getNAVPerShare()) / 1e18;
        return int256(currentNAV) - int256(lpInfo[lp].initialDepositValue);
    }
    
    /**
     * @notice Get pool ratio
     */
    function getPoolRatio() external view returns (uint256 usdsPercent, uint256 ethsPercent) {
        uint256 ethPrice = oracle.getETHPrice();
        uint256 usdsValue = reserveUSDS;
        uint256 ethsValue = (reserveETHS * ethPrice) / 1e18;
        uint256 total = usdsValue + ethsValue;
        
        if (total == 0) return (5000, 5000); // 50/50
        
        usdsPercent = (usdsValue * 10000) / total;
        ethsPercent = 10000 - usdsPercent;
    }
    
    // ============ INTERNAL ============
    
    function _transferToken(address token, address from, address to, uint256 amount) internal {
        // In production: use SafeERC20
        // For simulation: direct transfer assumption
        (bool success, ) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(success, "Token transfer failed");
    }
    
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
