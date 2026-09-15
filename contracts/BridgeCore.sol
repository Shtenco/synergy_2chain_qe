// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./USDS.sol";
import "./ETHS.sol";
import "./IManagedOracle.sol";

/**
 * @title BridgeCore - Transmutation Layer between Base Mainnet and Internal Fork
 * @notice Handles Lock/Mint and Burn/Unlock operations with Health Factor monitoring
 * @dev Implements emergency stop when HF < 110%
 * 
 * ARCHITECTURE:
 * - L1 (External): Canonical USDC/ETH on Base Mainnet
 * - L2 (Bridge): This contract - transmutation between layers
 * - L3 (Internal): Fork with USDS/ETHS pool
 * - L4 (Synthetic): USDS/ETHS tokens
 */
contract BridgeCore is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ============ ROLES ============
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // ============ CONSTANTS ============
    uint256 public constant MIN_HEALTH_FACTOR = 15000;      // 150.00% (basis points)
    uint256 public constant EMERGENCY_THRESHOLD = 11000;    // 110.00% - triggers emergency stop
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant ETH_DECIMALS = 1e18;
    uint256 public constant USDC_DECIMALS = 1e6;
    
    // ============ STATE ============
    USDS public immutable usds;
    ETHS public immutable eths;
    IERC20 public immutable canonicalUSDC;
    IManagedOracle public oracle;
    
    // Canonical assets locked on this side (Base)
    uint256 public totalLockedUSDC;
    uint256 public totalLockedETH;
    
    // Synthetic assets minted on this side
    uint256 public totalMintedUSDS;
    uint256 public totalMintedETHS;
    
    // Emergency state
    bool public emergencyStopped;
    uint256 public lastHealthFactor;
    
    // ============ EVENTS ============
    event Locked(address indexed user, uint256 amount, bool isETH);
    event Minted(address indexed user, uint256 amount, bool isETHS);
    event Burned(address indexed user, uint256 amount, bool isETHS);
    event Unlocked(address indexed user, uint256 amount, bool isETH);
    event EmergencyStopTriggered(uint256 healthFactor);
    event EmergencyStopLifted();
    event OracleUpdated(address indexed newOracle);
    event HealthFactorUpdated(uint256 hf);
    
    // ============ ERRORS ============
    error BridgeEmergencyStopped();
    error InsufficientHealthFactor(uint256 current, uint256 required);
    error InsufficientBalance(uint256 available, uint256 required);
    error ZeroAmount();
    error InvalidOracle();
    
    // ============ MODIFIERS ============
    modifier whenNotStopped() {
        if (emergencyStopped) revert BridgeEmergencyStopped();
        _;
    }
    
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }
    
    // ============ CONSTRUCTOR ============
    constructor(
        address _usds,
        address _eths,
        address _canonicalUSDC,
        address _oracle
    ) {
        usds = USDS(_usds);
        eths = ETHS(_eths);
        canonicalUSDC = IERC20(_canonicalUSDC);
        oracle = IManagedOracle(_oracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    // ============ CORE FUNCTIONS ============
    
    /**
     * @notice Lock canonical USDC and mint equivalent USDS
     * @param user Recipient of minted USDS
     * @param amount Amount of USDC to lock (6 decimals)
     */
    function lockUSDCAndMintUSDS(address user, uint256 amount) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotStopped 
        nonReentrant 
        validAmount(amount) 
    {
        // Transfer canonical USDC from user
        canonicalUSDC.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update state
        totalLockedUSDC += amount;
        totalMintedUSDS += amount;
        
        // Mint synthetic USDS
        usds.mint(user, amount);
        
        // Verify Health Factor
        _verifyHealthFactor();
        
        emit Locked(user, amount, false);
        emit Minted(user, amount, false);
    }
    
    /**
     * @notice Lock canonical ETH and mint equivalent ETHS
     * @param user Recipient of minted ETHS
     * @param amount Amount of ETH to lock (18 decimals)
     */
    function lockETHAndMintETHS(address user, uint256 amount) 
        external 
        payable
        onlyRole(OPERATOR_ROLE) 
        whenNotStopped 
        nonReentrant 
        validAmount(amount) 
    {
        // Update state
        totalLockedETH += amount;
        
        // Mint synthetic ETHS (1:1 with ETH)
        eths.mint(user, amount);
        totalMintedETHS += amount;
        
        // Verify Health Factor
        _verifyHealthFactor();
        
        emit Locked(user, amount, true);
        emit Minted(user, amount, true);
    }
    
    /**
     * @notice Burn USDS and unlock equivalent canonical USDC
     * @param user Recipient of unlocked USDC
     * @param amount Amount of USDS to burn
     */
    function burnUSDSAndUnlockUSDC(address user, uint256 amount) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotStopped 
        nonReentrant 
        validAmount(amount) 
    {
        if (totalMintedUSDS < amount) revert InsufficientBalance(totalMintedUSDS, amount);
        if (totalLockedUSDC < amount) revert InsufficientBalance(totalLockedUSDC, amount);
        
        // Burn synthetic USDS
        usds.bridgeBurn(msg.sender, amount);
        totalMintedUSDS -= amount;
        
        // Update locked amount
        totalLockedUSDC -= amount;
        
        // Transfer canonical USDC to user
        canonicalUSDC.safeTransfer(user, amount);
        
        emit Burned(msg.sender, amount, false);
        emit Unlocked(user, amount, false);
    }
    
    /**
     * @notice Burn ETHS and unlock equivalent canonical ETH
     * @param user Recipient of unlocked ETH
     * @param amount Amount of ETHS to burn (18 decimals)
     */
    function burnETHSAndUnlockETH(address user, uint256 amount) 
        external 
        onlyRole(OPERATOR_ROLE) 
        whenNotStopped 
        nonReentrant 
        validAmount(amount) 
    {
        if (totalMintedETHS < amount) revert InsufficientBalance(totalMintedETHS, amount);
        if (totalLockedETH < amount) revert InsufficientBalance(totalLockedETH, amount);
        
        // Burn synthetic ETHS
        eths.bridgeBurn(msg.sender, amount);
        totalMintedETHS -= amount;
        
        // Update locked amount
        totalLockedETH -= amount;
        
        // Transfer canonical ETH to user
        (bool success, ) = user.call{value: amount}("");
        require(success, "ETH transfer failed");
        
        emit Burned(msg.sender, amount, true);
        emit Unlocked(user, amount, true);
    }
    
    // ============ HEALTH FACTOR ============
    
    /**
     * @notice Calculate current Health Factor
     * @return HF in basis points (15000 = 150%)
     */
    function getHealthFactor() public view returns (uint256) {
        uint256 canonicalValue = _getCanonicalValue();
        uint256 syntheticValue = _getSyntheticValue();
        
        if (syntheticValue == 0) return type(uint256).max;
        
        return (canonicalValue * BASIS_POINTS) / syntheticValue;
    }
    
    /**
     * @notice Get total canonical value in USDC terms (6 decimals)
     */
    function _getCanonicalValue() internal view returns (uint256) {
        uint256 ethValueInUSDC = (totalLockedETH * oracle.getETHPrice()) / ETH_DECIMALS;
        return totalLockedUSDC + ethValueInUSDC;
    }
    
    /**
     * @notice Get total synthetic value in USDC terms (6 decimals)
     */
    function _getSyntheticValue() internal view returns (uint256) {
        uint256 ethsValueInUSDC = (totalMintedETHS * oracle.getETHPrice()) / ETH_DECIMALS;
        return totalMintedUSDS + ethsValueInUSDC;
    }
    
    /**
     * @notice Verify and update health factor, trigger emergency if needed
     */
    function _verifyHealthFactor() internal {
        uint256 hf = getHealthFactor();
        lastHealthFactor = hf;
        
        emit HealthFactorUpdated(hf);
        
        if (hf < EMERGENCY_THRESHOLD) {
            emergencyStopped = true;
            emit EmergencyStopTriggered(hf);
        }
    }
    
    // ============ EMERGENCY ============
    
    /**
     * @notice Manually trigger emergency stop
     */
    function triggerEmergencyStop() external onlyRole(EMERGENCY_ROLE) {
        emergencyStopped = true;
        emit EmergencyStopTriggered(getHealthFactor());
    }
    
    /**
     * @notice Lift emergency stop (only if HF recovered)
     */
    function liftEmergencyStop() external onlyRole(EMERGENCY_ROLE) {
        require(getHealthFactor() >= MIN_HEALTH_FACTOR, "HF not recovered");
        emergencyStopped = false;
        emit EmergencyStopLifted();
    }
    
    // ============ ADMIN ============
    
    /**
     * @notice Update oracle address
     */
    function setOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oracle == address(0)) revert InvalidOracle();
        oracle = IManagedOracle(_oracle);
        emit OracleUpdated(_oracle);
    }
    
    /**
     * @notice Get bridge statistics
     */
    function getStats() external view returns (
        uint256 lockedUSDC,
        uint256 lockedETH,
        uint256 mintedUSDS,
        uint256 mintedETHS,
        uint256 healthFactor,
        bool isStopped
    ) {
        return (
            totalLockedUSDC,
            totalLockedETH,
            totalMintedUSDS,
            totalMintedETHS,
            getHealthFactor(),
            emergencyStopped
        );
    }
    
    // Allow receiving ETH
    receive() external payable {}
}
