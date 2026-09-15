// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./IManagedOracle.sol";

/**
 * @title ManagedOracle - Custom oracle with algorithmic gradient control
 * @notice Provides external (Chainlink TWAP) and internal (managed) prices
 * @dev Gradient is controlled by ALGO_CONTROLLER role to initiate arb cycles
 * 
 * MODES:
 * - UNDERPRICE: Internal < External → Cycle A (extract from external)
 * - OVERPRICE: Internal > External → Cycle B (rebalance internal)
 * - NEUTRAL: Minimal gradient, no profitable arb
 */
contract ManagedOracle is AccessControl, IManagedOracle {
    bytes32 public constant ORACLE_ADMIN = keccak256("ORACLE_ADMIN");
    bytes32 public constant ALGO_CONTROLLER = keccak256("ALGO_CONTROLLER");
    
    // ============ CONSTANTS ============
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_STALENESS = 3600; // 1 hour
    
    // ============ STATE ============
    // External fair price (from Chainlink TWAP) - 6 decimals (USDC terms)
    uint256 public externalPrice;
    uint256 public externalPriceTimestamp;
    
    // Internal managed price - 6 decimals (USDC terms)
    uint256 public internalPrice;
    uint256 public internalPriceTimestamp;
    
    // Gradient control (basis points, can be negative)
    int256 public maxGradientBps = 1000; // ±10% max
    int256 public currentGradientBps;
    
    // Mode tracking
    enum Mode { UNDERPRICE, OVERPRICE, NEUTRAL }
    Mode public currentMode;
    
    // ============ EVENTS ============
    event PriceUpdated(uint256 externalPrice, uint256 internalPrice, int256 gradientBps);
    event ModeChanged(Mode newMode);
    event MaxGradientUpdated(int256 newMax);
    
    // ============ ERRORS ============
    error GradientExceedsMax(int256 requested, int256 maxAllowed);
    error PriceCannotBeZero();
    error StaleExternalPrice();
    
    // ============ CONSTRUCTOR ============
    constructor(uint256 _initialPrice) {
        externalPrice = _initialPrice;
        internalPrice = _initialPrice;
        externalPriceTimestamp = block.timestamp;
        internalPriceTimestamp = block.timestamp;
        currentMode = Mode.NEUTRAL;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN, msg.sender);
        _grantRole(ALGO_CONTROLLER, msg.sender);
    }
    
    // ============ PRICE UPDATES ============
    
    /**
     * @notice Set external price (from Chainlink or admin)
     * @param _price ETH price in USDC (6 decimals)
     */
    function setExternalPrice(uint256 _price) external onlyRole(ORACLE_ADMIN) {
        if (_price == 0) revert PriceCannotBeZero();
        externalPrice = _price;
        externalPriceTimestamp = block.timestamp;
        _recalculateInternal();
    }
    
    /**
     * @notice Set gradient to control internal price
     * @param _gradientBps Gradient in basis points (positive = overprice, negative = underprice)
     */
    function setGradient(int256 _gradientBps) external onlyRole(ALGO_CONTROLLER) {
        if (_abs(_gradientBps) > _abs(maxGradientBps)) {
            revert GradientExceedsMax(_gradientBps, maxGradientBps);
        }
        currentGradientBps = _gradientBps;
        _recalculateInternal();
    }
    
    /**
     * @notice Set both external price and gradient atomically
     */
    function setPrices(uint256 _externalPrice, int256 _gradientBps) external onlyRole(ALGO_CONTROLLER) {
        if (_externalPrice == 0) revert PriceCannotBeZero();
        if (_abs(_gradientBps) > _abs(maxGradientBps)) {
            revert GradientExceedsMax(_gradientBps, maxGradientBps);
        }
        
        externalPrice = _externalPrice;
        externalPriceTimestamp = block.timestamp;
        currentGradientBps = _gradientBps;
        
        _recalculateInternal();
    }
    
    /**
     * @notice Internal recalculation of internal price based on gradient
     */
    function _recalculateInternal() internal {
        if (currentGradientBps >= 0) {
            internalPrice = (externalPrice * (BASIS_POINTS + uint256(currentGradientBps))) / BASIS_POINTS;
        } else {
            internalPrice = (externalPrice * (BASIS_POINTS - uint256(-currentGradientBps))) / BASIS_POINTS;
        }
        internalPriceTimestamp = block.timestamp;
        
        // Determine mode
        if (currentGradientBps > 200) {
            currentMode = Mode.OVERPRICE;
        } else if (currentGradientBps < -200) {
            currentMode = Mode.UNDERPRICE;
        } else {
            currentMode = Mode.NEUTRAL;
        }
        
        emit PriceUpdated(externalPrice, internalPrice, currentGradientBps);
        emit ModeChanged(currentMode);
    }
    
    // ============ GETTERS (IManagedOracle) ============
    
    /**
     * @notice Get current ETH price (uses external for bridge calculations)
     */
    function getETHPrice() external view override returns (uint256) {
        return externalPrice;
    }
    
    function getExternalPrice() external view override returns (uint256) {
        return externalPrice;
    }
    
    function getInternalPrice() external view override returns (uint256) {
        return internalPrice;
    }
    
    function getGradient() external view override returns (int256) {
        return currentGradientBps;
    }
    
    function getMode() external view override returns (uint8) {
        return uint8(currentMode);
    }
    
    function isStale(uint256 maxAge) external view override returns (bool) {
        return block.timestamp - externalPriceTimestamp > maxAge;
    }
    
    // ============ ADMIN ============
    
    function setMaxGradient(int256 _maxBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxGradientBps = _maxBps;
        emit MaxGradientUpdated(_maxBps);
    }
    
    // ============ INTERNAL ============
    
    function _abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
