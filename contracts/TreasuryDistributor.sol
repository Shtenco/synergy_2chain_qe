// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TreasuryDistributor - Automatic profit distribution
 * @notice Distributes arbitrage profit according to fixed ratios:
 *   - 40% Owner (canonical profit / seigniorage)
 *   - 30% Bridge Reserve (maintain HF > 150%)
 *   - 20% Insurance Fund (extreme market buffer)
 *   - 10% Rebase Fund (LP compensation)
 */
contract TreasuryDistributor is Ownable {
    using SafeERC20 for IERC20;
    
    // ============ CONSTANTS ============
    uint256 public constant OWNER_SHARE = 4000;           // 40%
    uint256 public constant BRIDGE_RESERVE_SHARE = 3000;  // 30%
    uint256 public constant INSURANCE_SHARE = 2000;       // 20%
    uint256 public constant REBASE_SHARE = 1000;          // 10%
    uint256 public constant TOTAL_SHARES = 10000;         // 100%
    
    // ============ STATE ============
    IERC20 public immutable usdc;
    
    address public ownerWallet;
    address public bridgeReserve;
    address public insuranceFund;
    address public rebaseFund;
    
    // Tracking
    uint256 public totalDistributed;
    uint256 public totalOwnerWithdrawn;
    uint256 public totalBridgeDeposited;
    uint256 public totalInsuranceDeposited;
    uint256 public totalRebaseDeposited;
    uint256 public distributionCount;
    
    // ============ EVENTS ============
    event ProfitDistributed(
        uint256 total,
        uint256 ownerAmount,
        uint256 bridgeAmount,
        uint256 insuranceAmount,
        uint256 rebaseAmount
    );
    event RecipientsUpdated(address owner, address bridge, address insurance, address rebase);
    
    // ============ ERRORS ============
    error ZeroAmount();
    error InsufficientBalance(uint256 available, uint256 required);
    error InvalidAddress();
    
    // ============ CONSTRUCTOR ============
    constructor(
        address _usdc,
        address _owner,
        address _bridge,
        address _insurance,
        address _rebase
    ) {
        usdc = IERC20(_usdc);
        ownerWallet = _owner;
        bridgeReserve = _bridge;
        insuranceFund = _insurance;
        rebaseFund = _rebase;
    }
    
    // ============ CORE ============
    
    /**
     * @notice Distribute profit from arbitrage cycle
     * @param amount Total profit to distribute (USDC, 6 decimals)
     */
    function distribute(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance(balance, amount);
        
        uint256 ownerAmount = (amount * OWNER_SHARE) / TOTAL_SHARES;
        uint256 bridgeAmount = (amount * BRIDGE_RESERVE_SHARE) / TOTAL_SHARES;
        uint256 insuranceAmount = (amount * INSURANCE_SHARE) / TOTAL_SHARES;
        uint256 rebaseAmount = amount - ownerAmount - bridgeAmount - insuranceAmount; // remainder
        
        // Transfer to recipients
        usdc.safeTransfer(ownerWallet, ownerAmount);
        usdc.safeTransfer(bridgeReserve, bridgeAmount);
        usdc.safeTransfer(insuranceFund, insuranceAmount);
        usdc.safeTransfer(rebaseFund, rebaseAmount);
        
        // Update tracking
        totalDistributed += amount;
        totalOwnerWithdrawn += ownerAmount;
        totalBridgeDeposited += bridgeAmount;
        totalInsuranceDeposited += insuranceAmount;
        totalRebaseDeposited += rebaseAmount;
        distributionCount++;
        
        emit ProfitDistributed(amount, ownerAmount, bridgeAmount, insuranceAmount, rebaseAmount);
    }
    
    /**
     * @notice Preview distribution amounts
     */
    function previewDistribution(uint256 amount) 
        external 
        pure 
        returns (uint256 owner, uint256 bridge, uint256 insurance, uint256 rebase) 
    {
        owner = (amount * OWNER_SHARE) / TOTAL_SHARES;
        bridge = (amount * BRIDGE_RESERVE_SHARE) / TOTAL_SHARES;
        insurance = (amount * INSURANCE_SHARE) / TOTAL_SHARES;
        rebase = amount - owner - bridge - insurance;
    }
    
    // ============ ADMIN ============
    
    /**
     * @notice Update recipient addresses
     */
    function updateRecipients(
        address _owner,
        address _bridge,
        address _insurance,
        address _rebase
    ) external onlyOwner {
        if (_owner == address(0) || _bridge == address(0) || 
            _insurance == address(0) || _rebase == address(0)) revert InvalidAddress();
        
        ownerWallet = _owner;
        bridgeReserve = _bridge;
        insuranceFund = _insurance;
        rebaseFund = _rebase;
        
        emit RecipientsUpdated(_owner, _bridge, _insurance, _rebase);
    }
    
    /**
     * @notice Get distribution statistics
     */
    function getStats() external view returns (
        uint256 _totalDistributed,
        uint256 _ownerTotal,
        uint256 _bridgeTotal,
        uint256 _insuranceTotal,
        uint256 _rebaseTotal,
        uint256 _count
    ) {
        return (
            totalDistributed,
            totalOwnerWithdrawn,
            totalBridgeDeposited,
            totalInsuranceDeposited,
            totalRebaseDeposited,
            distributionCount
        );
    }
}
