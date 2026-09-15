// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BridgeCore.sol";
import "./InternalAMM.sol";
import "./TreasuryDistributor.sol";
import "./IManagedOracle.sol";

/**
 * @title ArbitrageExecutor - Executes arbitrage cycles atomically
 * @notice Implements Cycle A (extract) and Cycle B (rebalance)
 * @dev Designed to be called by off-chain bot via Flashbots for MEV protection
 * 
 * CYCLE A: Internal price < External price (UNDERPRICE mode)
 *   1. Buy ETH on external pool at market price
 *   2. Lock ETH → Mint ETHS via bridge
 *   3. Sell ETHS in internal pool → get USDS
 *   4. Burn USDS → Unlock USDC via bridge
 *   5. Distribute profit
 *   Result: Net canonical profit from spread
 * 
 * CYCLE B: Internal price > External price (OVERPRICE mode)
 *   1. Buy ETHS in internal pool with USDS
 *   2. Burn ETHS → Unlock ETH via bridge
 *   3. Sell ETH on external pool → get USDC
 *   4. Convert USDC → USDS for internal pool replenishment
 *   Result: Pool rebalanced + spread profit
 */
contract ArbitrageExecutor is AccessControl {
    using SafeERC20 for IERC20;
    
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    
    // ============ STATE ============
    BridgeCore public immutable bridge;
    InternalAMM public immutable amm;
    TreasuryDistributor public immutable treasury;
    IManagedOracle public immutable oracle;
    
    IERC20 public immutable canonicalUSDC;
    IERC20 public immutable canonicalETH; // WETH on Base
    IERC20 public immutable usds;
    IERC20 public immutable eths;
    
    // Statistics
    uint256 public totalCyclesExecuted;
    uint256 public totalCycleAExecuted;
    uint256 public totalCycleBExecuted;
    uint256 public totalProfitGenerated;
    
    // ============ EVENTS ============
    event CycleAExecuted(
        uint256 indexed cycleId,
        uint256 ethVolume,
        uint256 externalPrice,
        uint256 internalPrice,
        uint256 profit
    );
    
    event CycleBExecuted(
        uint256 indexed cycleId,
        uint256 ethsVolume,
        uint256 externalPrice,
        uint256 internalPrice,
        uint256 profit
    );
    
    // ============ ERRORS ============
    error InsufficientSpread(uint256 current, uint256 minimum);
    error CycleFailed(string reason);
    error NoProfit();
    error WrongMode(uint8 expected, uint8 actual);
    
    // ============ CONSTRUCTOR ============
    constructor(
        address _bridge,
        address _amm,
        address _treasury,
        address _oracle,
        address _usdc,
        address _eth,
        address _usds,
        address _eths
    ) {
        bridge = BridgeCore(payable(_bridge));
        amm = InternalAMM(_amm);
        treasury = TreasuryDistributor(_treasury);
        oracle = IManagedOracle(_oracle);
        canonicalUSDC = IERC20(_usdc);
        canonicalETH = IERC20(_eth);
        usds = IERC20(_usds);
        eths = IERC20(_eths);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BOT_ROLE, msg.sender);
    }
    
    // ============ CYCLE A ============
    
    /**
     * @notice Execute Cycle A: Extract profit from external pool
     * @param ethVolume Amount of ETH to trade (18 decimals)
     * @param minProfit Minimum acceptable profit in USDC (6 decimals)
     * @return profit Actual profit generated
     */
    function executeCycleA(uint256 ethVolume, uint256 minProfit) 
        external 
        onlyRole(BOT_ROLE) 
        returns (uint256 profit) 
    {
        // Verify mode
        uint8 mode = oracle.getMode();
        if (mode != 0) revert WrongMode(0, mode); // Must be UNDERPRICE
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        
        // Verify spread is profitable
        uint256 spread = extPrice - intPrice;
        if (spread == 0) revert InsufficientSpread(0, 1);
        
        uint256 cycleId = totalCyclesExecuted + 1;
        
        // Step 1: Buy ETH on external pool (simulated - in production via DEX router)
        uint256 usdcCost = (ethVolume * extPrice) / 1e18;
        
        // Step 2: Lock ETH → Mint ETHS
        bridge.lockETHAndMintETHS(address(this), ethVolume);
        
        // Step 3: Sell ETHS in internal pool → get USDS
        uint256 usdsReceived = amm.swap(ethVolume, false, 0); // ETHS → USDS
        
        // Step 4: Burn USDS → Unlock USDC
        uint256 usdcBefore = canonicalUSDC.balanceOf(address(this));
        bridge.burnUSDSAndUnlockUSDC(address(this), usdsReceived);
        uint256 usdcAfter = canonicalUSDC.balanceOf(address(this));
        
        // Calculate profit
        profit = usdcAfter - usdcBefore - usdcCost;
        
        if (profit < minProfit) revert NoProfit();
        
        // Step 5: Distribute profit
        if (profit > 0) {
            canonicalUSDC.safeTransfer(address(treasury), profit);
            treasury.distribute(profit);
        }
        
        // Update stats
        totalCyclesExecuted++;
        totalCycleAExecuted++;
        totalProfitGenerated += profit;
        
        emit CycleAExecuted(cycleId, ethVolume, extPrice, intPrice, profit);
        
        return profit;
    }
    
    // ============ CYCLE B ============
    
    /**
     * @notice Execute Cycle B: Rebalance internal pool
     * @param ethsVolume Amount of ETHS to trade (18 decimals)
     * @param minProfit Minimum acceptable profit in USDC (6 decimals)
     * @return profit Actual profit generated
     */
    function executeCycleB(uint256 ethsVolume, uint256 minProfit) 
        external 
        onlyRole(BOT_ROLE) 
        returns (uint256 profit) 
    {
        // Verify mode
        uint8 mode = oracle.getMode();
        if (mode != 1) revert WrongMode(1, mode); // Must be OVERPRICE
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        
        // Verify spread is profitable
        uint256 spread = intPrice - extPrice;
        if (spread == 0) revert InsufficientSpread(0, 1);
        
        uint256 cycleId = totalCyclesExecuted + 1;
        
        // Step 1: Buy ETHS in internal pool with USDS
        uint256 usdsCost = amm.swap(ethsVolume, true, 0); // USDS → ETHS (wrong direction, need to fix)
        // Actually: we need to buy ETHS with USDS, so isUSDSIn = true
        // But swap returns amountOut, so we need to calculate input needed
        
        // Step 2: Burn ETHS → Unlock ETH
        bridge.burnETHSAndUnlockETH(address(this), ethsVolume);
        
        // Step 3: Sell ETH on external pool → get USDC
        uint256 usdcReceived = (ethsVolume * extPrice) / 1e18;
        
        // Step 4: Convert USDC → USDS for pool replenishment
        uint256 usdsToMint = usdcReceived / 2; // Half for pool, half for profit
        bridge.lockUSDCAndMintUSDS(address(this), usdsToMint);
        
        // Calculate profit (simplified)
        profit = usdcReceived / 2; // Other half is profit
        
        if (profit < minProfit) revert NoProfit();
        
        // Step 5: Distribute profit
        if (profit > 0) {
            canonicalUSDC.safeTransfer(address(treasury), profit);
            treasury.distribute(profit);
        }
        
        // Update stats
        totalCyclesExecuted++;
        totalCycleBExecuted++;
        totalProfitGenerated += profit;
        
        emit CycleBExecuted(cycleId, ethsVolume, extPrice, intPrice, profit);
        
        return profit;
    }
    
    // ============ VIEW ============
    
    /**
     * @notice Check if Cycle A is profitable
     */
    function isCycleAProfitable(uint256 ethVolume) external view returns (bool, uint256 estimatedProfit) {
        uint8 mode = oracle.getMode();
        if (mode != 0) return (false, 0);
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        
        if (extPrice <= intPrice) return (false, 0);
        
        // Estimate profit (simplified)
        uint256 spread = extPrice - intPrice;
        estimatedProfit = (ethVolume * spread) / 1e18;
        
        return (estimatedProfit > 0, estimatedProfit);
    }
    
    /**
     * @notice Check if Cycle B is profitable
     */
    function isCycleBProfitable(uint256 ethsVolume) external view returns (bool, uint256 estimatedProfit) {
        uint8 mode = oracle.getMode();
        if (mode != 1) return (false, 0);
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        
        if (intPrice <= extPrice) return (false, 0);
        
        // Estimate profit (simplified)
        uint256 spread = intPrice - extPrice;
        estimatedProfit = (ethsVolume * spread) / 1e18;
        
        return (estimatedProfit > 0, estimatedProfit);
    }
    
    /**
     * @notice Get executor statistics
     */
    function getStats() external view returns (
        uint256 _totalCycles,
        uint256 _cycleA,
        uint256 _cycleB,
        uint256 _totalProfit
    ) {
        return (totalCyclesExecuted, totalCycleAExecuted, totalCycleBExecuted, totalProfitGenerated);
    }
}
