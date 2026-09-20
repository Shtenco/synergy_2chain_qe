// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    // NOTE (fork-test correction, disclosed): a 1:1 lock/mint bridge always sits at HF = 100%.
    // Thresholds above 100% made the FIRST regular operation halt the bridge, so no cycle
    // could ever complete. 150%+ collateralization requires an external capital subsidy and
    // cannot be produced by the bridge itself.
    uint256 public constant MIN_HEALTH_FACTOR = 10000;      // 100.00% (basis points)
    uint256 public constant EMERGENCY_THRESHOLD = 9500;     // 95.00% - triggers emergency stop
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRICE_6D_TO_18 = 1e12; // oracle prices are 6-decimal
    // NOTE (decimals audit, disclosed): ALL internal accounting is normalized to
    // 18-decimal "dollar" units. Canonical USDC (6 decimals on real Base) is scaled
    // by usdcScale = 10^(18 - usdcDecimals) on entry; payouts divide back (floor).
    // With an 18-decimal mock the scale is 1 and behavior is byte-identical to before.
    
    // ============ STATE ============
    USDS public immutable usds;
    ETHS public immutable eths;
    IERC20 public immutable canonicalUSDC;
    IManagedOracle public oracle;
    uint8 public immutable usdcDecimals;
    uint256 public immutable usdcScale; // 10^(18 - usdcDecimals)
    
    // Canonical assets locked on this side (Base)
    uint256 public totalLockedUSDC;
    uint256 public totalLockedETH;
    
    // Synthetic assets minted on this side
    uint256 public totalMintedUSDS;
    uint256 public totalMintedETHS;
    
    // Emergency state
    bool public emergencyStopped;
    uint256 public lastHealthFactor;

    // Stage 2 (ТЗ 7.1): per-transaction lock caps against reserve drain.
    // 0 = no cap (default, preserves existing behavior until caps are set).
    uint256 public maxLockETHPerTx;
    uint256 public maxLockUSDCPerTx;
    
    // ============ EVENTS ============
    event Locked(address indexed user, uint256 amount, bool isETH);
    event Minted(address indexed user, uint256 amount, bool isETHS);
    event Burned(address indexed user, uint256 amount, bool isETHS);
    event Unlocked(address indexed user, uint256 amount, bool isETH);
    event EmergencyStopTriggered(uint256 healthFactor);
    event EmergencyStopLifted();
    event OracleUpdated(address indexed newOracle);
    event HealthFactorUpdated(uint256 hf);
    event LockCapsUpdated(uint256 maxETHPerTx, uint256 maxUSDCPerTx);
    
    // ============ ERRORS ============
    error BridgeEmergencyStopped();
    error InsufficientHealthFactor(uint256 current, uint256 required);
    error InsufficientBalance(uint256 available, uint256 required);
    error ZeroAmount();
    error InvalidOracle();
    error IncorrectETHValue(uint256 sent, uint256 required);
    error LockExceedsCap(uint256 amount, uint256 cap);
    error UnsupportedDecimals(uint8 decimals);
    
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

        uint8 dec = IERC20Metadata(_canonicalUSDC).decimals();
        if (dec > 18) revert UnsupportedDecimals(dec);
        usdcDecimals = dec;
        usdcScale = 10 ** (18 - dec);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    // ============ CORE FUNCTIONS ============
    
    /**
     * @notice Lock canonical USDC and mint equivalent USDS
     * @param user Recipient of minted USDS
     * @param amount Amount of USDC to lock (canonical token decimals)
     */
    function lockUSDCAndMintUSDS(address user, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotStopped
        nonReentrant
        validAmount(amount)
    {
        if (maxLockUSDCPerTx != 0 && amount > maxLockUSDCPerTx) {
            revert LockExceedsCap(amount, maxLockUSDCPerTx);
        }

        // Transfer canonical USDC from user
        canonicalUSDC.safeTransferFrom(msg.sender, address(this), amount);

        // Normalize to 18-decimal accounting units (decimals audit).
        uint256 norm = amount * usdcScale;

        // Update state
        totalLockedUSDC += norm;
        totalMintedUSDS += norm;

        // Mint synthetic USDS
        usds.mint(user, norm);
        
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
        // SECURITY (disclosed fix): without this check an operator could mint ETHS
        // without locking any ETH, creating unbacked claims on the reserve.
        if (msg.value != amount) revert IncorrectETHValue(msg.value, amount);
        if (maxLockETHPerTx != 0 && amount > maxLockETHPerTx) {
            revert LockExceedsCap(amount, maxLockETHPerTx);
        }

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
     * @param amount Amount of USDS to burn (18 decimals)
     */
    function burnUSDSAndUnlockUSDC(address user, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotStopped
        nonReentrant
        validAmount(amount)
    {
        if (totalMintedUSDS < amount) revert InsufficientBalance(totalMintedUSDS, amount);
        // Denormalize payout (floor; sub-unit dust stays locked, favoring the reserve).
        uint256 payout = amount / usdcScale;
        if (totalLockedUSDC < payout * usdcScale) {
            revert InsufficientBalance(totalLockedUSDC, payout * usdcScale);
        }

        // Burn synthetic USDS
        usds.bridgeBurn(msg.sender, amount);
        totalMintedUSDS -= amount;

        // Update locked amount
        totalLockedUSDC -= payout * usdcScale;

        // Transfer canonical USDC to user
        canonicalUSDC.safeTransfer(user, payout);
        
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
     * @notice Get total canonical value in normalized 18-decimal dollar units
     */
    function _getCanonicalValue() internal view returns (uint256) {
        uint256 ethValue = (totalLockedETH * oracle.getETHPrice() * PRICE_6D_TO_18) / 1e18;
        return totalLockedUSDC + ethValue;
    }

    /**
     * @notice Get total synthetic value in normalized 18-decimal dollar units
     */
    function _getSyntheticValue() internal view returns (uint256) {
        uint256 ethsValue = (totalMintedETHS * oracle.getETHPrice() * PRICE_6D_TO_18) / 1e18;
        return totalMintedUSDS + ethsValue;
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
     * @notice Set per-transaction lock caps (Stage 2, ТЗ 7.1). Zero disables.
     */
    function setLockCaps(uint256 _maxETHPerTx, uint256 _maxUSDCPerTx) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxLockETHPerTx = _maxETHPerTx;
        maxLockUSDCPerTx = _maxUSDCPerTx;
        emit LockCapsUpdated(_maxETHPerTx, _maxUSDCPerTx);
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
