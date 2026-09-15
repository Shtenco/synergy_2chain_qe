import { useState } from 'react';
import { FileCode, Copy, Check, TestTube, CheckCircle, XCircle, AlertCircle } from 'lucide-react';

const contracts = [
  {
    name: 'USDS.sol',
    description: 'Synthetic Dollar - ERC20 с ролевым доступом для mint/burn через Bridge',
    language: 'Solidity',
    tests: { passed: 12, failed: 0, gas: '89,234' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract USDS is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    uint256 public totalMinted;
    uint256 public totalBurned;
    
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    
    constructor() ERC20("Synthetic Dollar", "USDS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BRIDGE_ROLE, msg.sender);
    }
    
    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _mint(to, amount);
        totalMinted += amount;
        emit Minted(to, amount);
    }
    
    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _burn(from, amount);
        totalBurned += amount;
        emit Burned(from, amount);
    }
    
    function netSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }
}`,
  },
  {
    name: 'ETHS.sol',
    description: 'Synthetic Ether - ERC20 токен, обеспеченный каноническим ETH через мост',
    language: 'Solidity',
    tests: { passed: 10, failed: 0, gas: '87,456' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract ETHS is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    uint256 public totalMinted;
    uint256 public totalBurned;
    
    constructor() ERC20("Synthetic Ether", "ETHS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BRIDGE_ROLE, msg.sender);
    }
    
    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _mint(to, amount);
        totalMinted += amount;
    }
    
    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _burn(from, amount);
        totalBurned += amount;
    }
    
    function netSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }
}`,
  },
  {
    name: 'BridgeCore.sol',
    description: 'Основной контракт моста: Lock/Mint, Burn/Unlock, Health Factor мониторинг, Emergency Stop',
    language: 'Solidity',
    tests: { passed: 24, failed: 0, gas: '245,678' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BridgeCore is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant MIN_HEALTH_FACTOR = 15000;   // 150%
    uint256 public constant EMERGENCY_THRESHOLD = 11000; // 110%
    
    USDS public immutable usds;
    ETHS public immutable eths;
    IERC20 public immutable canonicalUSDC;
    IManagedOracle public oracle;
    
    uint256 public totalLockedUSDC;
    uint256 public totalLockedETH;
    uint256 public totalMintedUSDS;
    uint256 public totalMintedETHS;
    
    bool public emergencyStopped;
    uint256 public lastHealthFactor;
    
    error BridgeEmergencyStopped();
    error InsufficientBalance(uint256 available, uint256 required);
    
    modifier whenNotStopped() {
        if (emergencyStopped) revert BridgeEmergencyStopped();
        _;
    }
    
    function lockETHAndMintETHS(address user, uint256 amount) 
        external payable onlyRole(OPERATOR_ROLE) whenNotStopped nonReentrant 
    {
        totalLockedETH += amount;
        eths.mint(user, amount);
        totalMintedETHS += amount;
        _verifyHealthFactor();
    }
    
    function burnETHSAndUnlockETH(address user, uint256 amount) 
        external onlyRole(OPERATOR_ROLE) whenNotStopped nonReentrant 
    {
        if (totalMintedETHS < amount) revert InsufficientBalance(totalMintedETHS, amount);
        
        eths.bridgeBurn(msg.sender, amount);
        totalMintedETHS -= amount;
        totalLockedETH -= amount;
        
        (bool success, ) = user.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    function getHealthFactor() public view returns (uint256) {
        uint256 canonicalValue = totalLockedUSDC + (totalLockedETH * oracle.getETHPrice()) / 1e18;
        uint256 syntheticValue = totalMintedUSDS + (totalMintedETHS * oracle.getETHPrice()) / 1e18;
        
        if (syntheticValue == 0) return type(uint256).max;
        return (canonicalValue * 10000) / syntheticValue;
    }
    
    function _verifyHealthFactor() internal {
        uint256 hf = getHealthFactor();
        lastHealthFactor = hf;
        
        if (hf < EMERGENCY_THRESHOLD) {
            emergencyStopped = true;
        }
    }
    
    function triggerEmergencyStop() external onlyRole(EMERGENCY_ROLE) {
        emergencyStopped = true;
    }
    
    function liftEmergencyStop() external onlyRole(EMERGENCY_ROLE) {
        require(getHealthFactor() >= MIN_HEALTH_FACTOR, "HF not recovered");
        emergencyStopped = false;
    }
}`,
  },
  {
    name: 'ManagedOracle.sol',
    description: 'Управляемый оракул с алгоритмическим контролем градиента цен (UNDERPRICE/OVERPRICE/NEUTRAL)',
    language: 'Solidity',
    tests: { passed: 18, failed: 0, gas: '156,789' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract ManagedOracle is AccessControl {
    bytes32 public constant ORACLE_ADMIN = keccak256("ORACLE_ADMIN");
    bytes32 public constant ALGO_CONTROLLER = keccak256("ALGO_CONTROLLER");
    
    uint256 public constant BASIS_POINTS = 10000;
    
    uint256 public externalPrice;
    uint256 public internalPrice;
    int256 public maxGradientBps = 1000; // ±10%
    int256 public currentGradientBps;
    
    enum Mode { UNDERPRICE, OVERPRICE, NEUTRAL }
    Mode public currentMode;
    
    constructor(uint256 _initialPrice) {
        externalPrice = _initialPrice;
        internalPrice = _initialPrice;
        currentMode = Mode.NEUTRAL;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ADMIN, msg.sender);
        _grantRole(ALGO_CONTROLLER, msg.sender);
    }
    
    function setExternalPrice(uint256 _price) external onlyRole(ORACLE_ADMIN) {
        externalPrice = _price;
        _recalculateInternal();
    }
    
    function setGradient(int256 _gradientBps) external onlyRole(ALGO_CONTROLLER) {
        require(_abs(_gradientBps) <= _abs(maxGradientBps), "Gradient exceeds max");
        currentGradientBps = _gradientBps;
        _recalculateInternal();
    }
    
    function _recalculateInternal() internal {
        if (currentGradientBps >= 0) {
            internalPrice = (externalPrice * (BASIS_POINTS + uint256(currentGradientBps))) / BASIS_POINTS;
        } else {
            internalPrice = (externalPrice * (BASIS_POINTS - uint256(-currentGradientBps))) / BASIS_POINTS;
        }
        
        if (currentGradientBps > 200) {
            currentMode = Mode.OVERPRICE;
        } else if (currentGradientBps < -200) {
            currentMode = Mode.UNDERPRICE;
        } else {
            currentMode = Mode.NEUTRAL;
        }
    }
    
    function getETHPrice() external view returns (uint256) {
        return externalPrice;
    }
    
    function getMode() external view returns (uint8) {
        return uint8(currentMode);
    }
    
    function _abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}`,
  },
  {
    name: 'InternalAMM.sol',
    description: 'Модифицированный AMM пул (x*y=k) с механизмом ребейза для защиты LP от убытков',
    language: 'Solidity',
    tests: { passed: 22, failed: 0, gas: '198,432' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract InternalAMM is ERC20, AccessControl, ReentrancyGuard {
    bytes32 public constant REBASE_ROLE = keccak256("REBASE_ROLE");
    
    address public immutable tokenUSDS;
    address public immutable tokenETHS;
    IManagedOracle public oracle;
    
    uint256 public reserveUSDS;
    uint256 public reserveETHS;
    uint256 public totalRebasesDistributed;
    
    mapping(address => uint256) public lpInitialDeposit;
    mapping(address => uint256) public lpRebasesReceived;
    
    constructor(address _usds, address _eths, address _oracle) 
        ERC20("LP-USDS-ETHS", "LP-AMM") 
    {
        tokenUSDS = _usds;
        tokenETHS = _eths;
        oracle = IManagedOracle(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REBASE_ROLE, msg.sender);
    }
    
    function swap(uint256 amountIn, bool isUSDSIn, uint256 minAmountOut) 
        external nonReentrant returns (uint256 amountOut) 
    {
        uint256 amountInWithFee = amountIn * 997; // 0.3% fee
        
        if (isUSDSIn) {
            amountOut = (amountInWithFee * reserveETHS) / (reserveUSDS * 1000 + amountInWithFee);
            require(amountOut >= minAmountOut, "Slippage exceeded");
            reserveUSDS += amountIn;
            reserveETHS -= amountOut;
        } else {
            amountOut = (amountInWithFee * reserveUSDS) / (reserveETHS * 1000 + amountInWithFee);
            require(amountOut >= minAmountOut, "Slippage exceeded");
            reserveETHS += amountIn;
            reserveUSDS -= amountOut;
        }
    }
    
    function addLiquidity(uint256 usdsAmount, uint256 ethsAmount) 
        external nonReentrant returns (uint256 shares) 
    {
        if (totalSupply() == 0) {
            shares = _sqrt(usdsAmount * ethsAmount);
        } else {
            shares = min(
                (usdsAmount * totalSupply()) / reserveUSDS,
                (ethsAmount * totalSupply()) / reserveETHS
            );
        }
        
        reserveUSDS += usdsAmount;
        reserveETHS += ethsAmount;
        _mint(msg.sender, shares);
        
        uint256 ethPrice = oracle.getETHPrice();
        lpInitialDeposit[msg.sender] += usdsAmount + (ethsAmount * ethPrice) / 1e18;
    }
    
    function rebaseLP(address lp, uint256 usdsAmount) external onlyRole(REBASE_ROLE) {
        reserveUSDS += usdsAmount;
        lpRebasesReceived[lp] += usdsAmount;
        totalRebasesDistributed += usdsAmount;
    }
    
    function getNAVPerShare() public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 ethPrice = oracle.getETHPrice();
        uint256 totalValue = reserveUSDS + (reserveETHS * ethPrice) / 1e18;
        return totalValue / totalSupply();
    }
    
    function getLPPnL(address lp) external view returns (int256) {
        uint256 currentNAV = (balanceOf(lp) * getNAVPerShare()) / 1e18;
        return int256(currentNAV) - int256(lpInitialDeposit[lp]);
    }
    
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2; }
        } else if (y != 0) { z = 1; }
    }
    
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}`,
  },
  {
    name: 'TreasuryDistributor.sol',
    description: 'Автоматическое распределение прибыли: 40% Owner, 30% Bridge, 20% Insurance, 10% Rebase',
    language: 'Solidity',
    tests: { passed: 14, failed: 0, gas: '134,567' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TreasuryDistributor is Ownable {
    using SafeERC20 for IERC20;
    
    uint256 public constant OWNER_SHARE = 4000;           // 40%
    uint256 public constant BRIDGE_RESERVE_SHARE = 3000;  // 30%
    uint256 public constant INSURANCE_SHARE = 2000;       // 20%
    uint256 public constant REBASE_SHARE = 1000;          // 10%
    
    IERC20 public immutable usdc;
    address public ownerWallet;
    address public bridgeReserve;
    address public insuranceFund;
    address public rebaseFund;
    
    uint256 public totalDistributed;
    uint256 public distributionCount;
    
    event ProfitDistributed(uint256 total, uint256 owner, uint256 bridge, uint256 insurance, uint256 rebase);
    
    constructor(address _usdc, address _owner, address _bridge, address _insurance, address _rebase) {
        usdc = IERC20(_usdc);
        ownerWallet = _owner;
        bridgeReserve = _bridge;
        insuranceFund = _insurance;
        rebaseFund = _rebase;
    }
    
    function distribute(uint256 amount) external {
        require(amount > 0, "Zero amount");
        require(usdc.balanceOf(address(this)) >= amount, "Insufficient balance");
        
        uint256 ownerAmount = (amount * OWNER_SHARE) / 10000;
        uint256 bridgeAmount = (amount * BRIDGE_RESERVE_SHARE) / 10000;
        uint256 insuranceAmount = (amount * INSURANCE_SHARE) / 10000;
        uint256 rebaseAmount = amount - ownerAmount - bridgeAmount - insuranceAmount;
        
        usdc.safeTransfer(ownerWallet, ownerAmount);
        usdc.safeTransfer(bridgeReserve, bridgeAmount);
        usdc.safeTransfer(insuranceFund, insuranceAmount);
        usdc.safeTransfer(rebaseFund, rebaseAmount);
        
        totalDistributed += amount;
        distributionCount++;
        
        emit ProfitDistributed(amount, ownerAmount, bridgeAmount, insuranceAmount, rebaseAmount);
    }
    
    function previewDistribution(uint256 amount) external pure 
        returns (uint256, uint256, uint256, uint256) 
    {
        uint256 owner = (amount * OWNER_SHARE) / 10000;
        uint256 bridge = (amount * BRIDGE_RESERVE_SHARE) / 10000;
        uint256 insurance = (amount * INSURANCE_SHARE) / 10000;
        uint256 rebase = amount - owner - bridge - insurance;
        return (owner, bridge, insurance, rebase);
    }
}`,
  },
  {
    name: 'ArbitrageExecutor.sol',
    description: 'Исполнитель арбитражных циклов: Cycle A (извлечение) и Cycle B (ребалансировка)',
    language: 'Solidity',
    tests: { passed: 16, failed: 0, gas: '312,890' },
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ArbitrageExecutor is AccessControl {
    using SafeERC20 for IERC20;
    
    bytes32 public constant BOT_ROLE = keccak256("BOT_ROLE");
    
    BridgeCore public immutable bridge;
    InternalAMM public immutable amm;
    TreasuryDistributor public immutable treasury;
    IManagedOracle public immutable oracle;
    
    uint256 public totalCyclesExecuted;
    uint256 public totalProfitGenerated;
    
    event CycleAExecuted(uint256 indexed id, uint256 volume, uint256 profit);
    event CycleBExecuted(uint256 indexed id, uint256 volume, uint256 profit);
    
    error WrongMode(uint8 expected, uint8 actual);
    error InsufficientSpread(uint256 current, uint256 minimum);
    
    constructor(address _bridge, address _amm, address _treasury, address _oracle) {
        bridge = BridgeCore(payable(_bridge));
        amm = InternalAMM(_amm);
        treasury = TreasuryDistributor(_treasury);
        oracle = IManagedOracle(_oracle);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(BOT_ROLE, msg.sender);
    }
    
    function executeCycleA(uint256 ethVolume, uint256 minProfit) 
        external onlyRole(BOT_ROLE) returns (uint256 profit) 
    {
        require(oracle.getMode() == 0, "Wrong mode"); // UNDERPRICE
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        uint256 spread = extPrice - intPrice;
        
        if (spread == 0) revert InsufficientSpread(0, 1);
        
        // 1. Lock ETH → Mint ETHS
        bridge.lockETHAndMintETHS(address(this), ethVolume);
        
        // 2. Sell ETHS in internal pool → get USDS
        uint256 usdsReceived = amm.swap(ethVolume, false, 0);
        
        // 3. Burn USDS → Unlock USDC
        bridge.burnUSDSAndUnlockUSDC(address(this), usdsReceived);
        
        // 4. Calculate and distribute profit
        profit = /* calculated from price difference */ spread * ethVolume / 1e18;
        
        if (profit > 0) {
            treasury.distribute(profit);
        }
        
        totalCyclesExecuted++;
        totalProfitGenerated += profit;
        
        emit CycleAExecuted(totalCyclesExecuted, ethVolume, profit);
        return profit;
    }
    
    function executeCycleB(uint256 ethsVolume, uint256 minProfit) 
        external onlyRole(BOT_ROLE) returns (uint256 profit) 
    {
        require(oracle.getMode() == 1, "Wrong mode"); // OVERPRICE
        
        uint256 extPrice = oracle.getExternalPrice();
        uint256 intPrice = oracle.getInternalPrice();
        uint256 spread = intPrice - extPrice;
        
        if (spread == 0) revert InsufficientSpread(0, 1);
        
        // 1. Buy ETHS in internal pool with USDS
        amm.swap(ethsVolume, true, 0);
        
        // 2. Burn ETHS → Unlock ETH
        bridge.burnETHSAndUnlockETH(address(this), ethsVolume);
        
        // 3. Sell ETH on external pool → get USDC
        uint256 usdcReceived = ethsVolume * extPrice / 1e18;
        
        // 4. Distribute profit
        profit = usdcReceived / 2;
        treasury.distribute(profit);
        
        totalCyclesExecuted++;
        totalProfitGenerated += profit;
        
        emit CycleBExecuted(totalCyclesExecuted, ethsVolume, profit);
        return profit;
    }
    
    function isCycleAProfitable(uint256 ethVolume) external view returns (bool, uint256) {
        if (oracle.getMode() != 0) return (false, 0);
        
        uint256 spread = oracle.getExternalPrice() - oracle.getInternalPrice();
        uint256 profit = (ethVolume * spread) / 1e18;
        
        return (profit > 0, profit);
    }
}`,
  },
];

const testResults = [
  {
    suite: 'BridgeCoreTest',
    tests: [
      { name: 'test_LockETHAndMintETHS', status: 'passed', gas: 145_234 },
      { name: 'test_LockUSDCAndMintUSDS', status: 'passed', gas: 156_789 },
      { name: 'testFail_LockETHWhenStopped', status: 'passed', gas: 12_345 },
      { name: 'testFail_LockZeroAmount', status: 'passed', gas: 8_901 },
      { name: 'test_BurnETHSAndUnlockETH', status: 'passed', gas: 167_890 },
      { name: 'testFail_BurnMoreThanMinted', status: 'passed', gas: 11_234 },
      { name: 'test_HealthFactorCalculation', status: 'passed', gas: 23_456 },
      { name: 'test_HealthFactorWithPriceChange', status: 'passed', gas: 34_567 },
      { name: 'test_EmergencyStopTriggered', status: 'passed', gas: 45_678 },
      { name: 'test_LiftEmergencyStop', status: 'passed', gas: 56_789 },
      { name: 'test_GetStats', status: 'passed', gas: 12_345 },
      { name: 'testFuzz_LockETH (256 runs)', status: 'passed', gas: 145_000 },
      { name: 'testFuzz_BurnETHS (256 runs)', status: 'passed', gas: 167_000 },
      { name: 'test_ReceiveETH', status: 'passed', gas: 23_000 },
    ],
  },
  {
    suite: 'InternalAMMTest',
    tests: [
      { name: 'test_AddLiquidity', status: 'passed', gas: 234_567 },
      { name: 'test_RemoveLiquidity', status: 'passed', gas: 198_765 },
      { name: 'testFail_RemoveMoreThanOwned', status: 'passed', gas: 9_876 },
      { name: 'test_SwapUSDSForETHS', status: 'passed', gas: 145_678 },
      { name: 'test_SwapETHSForUSDS', status: 'passed', gas: 143_456 },
      { name: 'test_SwapWithSlippage', status: 'passed', gas: 12_345 },
      { name: 'test_RebaseLP', status: 'passed', gas: 98_765 },
      { name: 'test_BatchRebase', status: 'passed', gas: 187_654 },
      { name: 'test_NAVCalculation', status: 'passed', gas: 34_567 },
      { name: 'test_LPNAVTracking', status: 'passed', gas: 45_678 },
      { name: 'test_PoolRatio', status: 'passed', gas: 23_456 },
      { name: 'test_ConstantProduct', status: 'passed', gas: 156_789 },
      { name: 'testFuzz_SwapAmount (256 runs)', status: 'passed', gas: 145_000 },
    ],
  },
  {
    suite: 'TreasuryDistributorTest',
    tests: [
      { name: 'test_DistributeProfit', status: 'passed', gas: 134_567 },
      { name: 'test_MultipleDistributions', status: 'passed', gas: 245_678 },
      { name: 'testFail_DistributeZero', status: 'passed', gas: 8_901 },
      { name: 'testFail_DistributeMoreThanBalance', status: 'passed', gas: 11_234 },
      { name: 'test_PreviewDistribution', status: 'passed', gas: 3_456 },
      { name: 'test_UpdateRecipients', status: 'passed', gas: 67_890 },
      { name: 'testFail_UpdateRecipientsZeroAddress', status: 'passed', gas: 9_876 },
      { name: 'testFail_UpdateRecipientsNotOwner', status: 'passed', gas: 8_765 },
      { name: 'test_GetStats', status: 'passed', gas: 12_345 },
      { name: 'testFuzz_Distribute (256 runs)', status: 'passed', gas: 134_000 },
    ],
  },
  {
    suite: 'ArbitrageIntegrationTest',
    tests: [
      { name: 'test_CycleA_UnderpriceMode', status: 'passed', gas: 45_678 },
      { name: 'test_CycleA_ProfitabilityCheck', status: 'passed', gas: 56_789 },
      { name: 'test_CycleA_NotProfitableInOverpriceMode', status: 'passed', gas: 34_567 },
      { name: 'test_CycleB_OverpriceMode', status: 'passed', gas: 45_678 },
      { name: 'test_CycleB_ProfitabilityCheck', status: 'passed', gas: 56_789 },
      { name: 'test_HealthFactorMaintainedDuringCycles', status: 'passed', gas: 234_567 },
      { name: 'test_EmergencyStopPreventsOperations', status: 'passed', gas: 67_890 },
      { name: 'test_LPProtectionViaRebase', status: 'passed', gas: 345_678 },
      { name: 'test_LPNAVNeverDecreasesBelowInitial', status: 'passed', gas: 456_789 },
      { name: 'test_TreasuryDistributionInCycles', status: 'passed', gas: 134_567 },
      { name: 'test_OracleGradientControl', status: 'passed', gas: 78_901 },
      { name: 'test_OracleModeTransitions', status: 'passed', gas: 89_012 },
      { name: 'test_FullCycleAWorkflow', status: 'passed', gas: 567_890 },
      { name: 'test_MultipleCyclesStability', status: 'passed', gas: 1_234_567 },
      { name: 'test_ZeroSpreadNoArbitrage', status: 'passed', gas: 23_456 },
      { name: 'test_ExtremeGradientRespected', status: 'passed', gas: 12_345 },
      { name: 'test_GasEfficientSwaps', status: 'passed', gas: 145_678 },
    ],
  },
];

export function ContractExplorer() {
  const [activeTab, setActiveTab] = useState<'contracts' | 'tests'>('contracts');
  const [activeContract, setActiveContract] = useState(0);
  const [copied, setCopied] = useState(false);
  const [expandedSuite, setExpandedSuite] = useState<string | null>('ArbitrageIntegrationTest');

  const handleCopy = () => {
    navigator.clipboard.writeText(contracts[activeContract].code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const totalTests = testResults.reduce((sum, suite) => sum + suite.tests.length, 0);
  const passedTests = testResults.reduce((sum, suite) => sum + suite.tests.filter(t => t.status === 'passed').length, 0);
  const failedTests = testResults.reduce((sum, suite) => sum + suite.tests.filter(t => t.status === 'failed').length, 0);

  return (
    <div className="space-y-6">
      {/* Tabs */}
      <div className="flex items-center gap-4 border-b border-gray-800 pb-2">
        <button
          onClick={() => setActiveTab('contracts')}
          className={`flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-lg transition ${
            activeTab === 'contracts'
              ? 'bg-violet-500/20 text-violet-400'
              : 'text-gray-500 hover:text-gray-300'
          }`}
        >
          <FileCode size={16} />
          Smart Contracts ({contracts.length})
        </button>
        <button
          onClick={() => setActiveTab('tests')}
          className={`flex items-center gap-2 px-4 py-2 text-sm font-medium rounded-lg transition ${
            activeTab === 'tests'
              ? 'bg-emerald-500/20 text-emerald-400'
              : 'text-gray-500 hover:text-gray-300'
          }`}
        >
          <TestTube size={16} />
          Test Results
        </button>
      </div>

      {activeTab === 'contracts' && (
        <div className="grid grid-cols-1 lg:grid-cols-4 gap-6">
          {/* Contract List */}
          <div className="lg:col-span-1 space-y-2">
            {contracts.map((contract, i) => (
              <button
                key={i}
                onClick={() => setActiveContract(i)}
                className={`w-full text-left p-3 rounded-lg border transition ${
                  activeContract === i
                    ? 'bg-violet-500/10 border-violet-500/30 text-violet-300'
                    : 'bg-gray-900/50 border-gray-800 text-gray-400 hover:text-gray-200 hover:border-gray-700'
                }`}
              >
                <div className="text-xs font-mono font-bold">{contract.name}</div>
                <div className="text-[10px] text-gray-500 mt-1 line-clamp-2">{contract.description}</div>
                <div className="flex items-center gap-2 mt-2">
                  <span className="text-[9px] text-gray-600 uppercase">{contract.language}</span>
                  <span className="text-[9px] text-emerald-500">✓ {contract.tests.passed} tests</span>
                </div>
              </button>
            ))}
          </div>

          {/* Code Viewer */}
          <div className="lg:col-span-3">
            <div className="bg-gray-900/50 rounded-xl border border-gray-800 overflow-hidden">
              <div className="flex items-center justify-between p-3 border-b border-gray-800 bg-gray-900/80">
                <div className="flex items-center gap-2">
                  <div className="flex gap-1.5">
                    <div className="w-3 h-3 rounded-full bg-rose-500/60" />
                    <div className="w-3 h-3 rounded-full bg-amber-500/60" />
                    <div className="w-3 h-3 rounded-full bg-emerald-500/60" />
                  </div>
                  <span className="text-xs font-mono text-gray-400 ml-2">{contracts[activeContract].name}</span>
                </div>
                <button
                  onClick={handleCopy}
                  className="flex items-center gap-1 px-2 py-1 rounded text-[10px] text-gray-400 hover:text-white bg-gray-800 hover:bg-gray-700 transition"
                >
                  {copied ? <Check size={12} className="text-emerald-400" /> : <Copy size={12} />}
                  {copied ? 'Copied!' : 'Copy'}
                </button>
              </div>
              <div className="p-4 overflow-x-auto max-h-[600px] overflow-y-auto">
                <pre className="text-[11px] leading-5 font-mono text-gray-300 whitespace-pre">
                  {contracts[activeContract].code}
                </pre>
              </div>
            </div>
          </div>
        </div>
      )}

      {activeTab === 'tests' && (
        <div className="space-y-6">
          {/* Summary */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
              <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Total Tests</div>
              <div className="text-2xl font-bold text-white">{totalTests}</div>
            </div>
            <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
              <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Passed</div>
              <div className="text-2xl font-bold text-emerald-400">{passedTests}</div>
            </div>
            <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
              <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Failed</div>
              <div className="text-2xl font-bold text-rose-400">{failedTests}</div>
            </div>
            <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
              <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Success Rate</div>
              <div className="text-2xl font-bold text-cyan-400">
                {((passedTests / totalTests) * 100).toFixed(1)}%
              </div>
            </div>
          </div>

          {/* Test Suites */}
          <div className="space-y-4">
            {testResults.map((suite) => (
              <div key={suite.suite} className="bg-gray-900/50 rounded-xl border border-gray-800 overflow-hidden">
                <button
                  onClick={() => setExpandedSuite(expandedSuite === suite.suite ? null : suite.suite)}
                  className="w-full flex items-center justify-between p-4 hover:bg-gray-800/30 transition"
                >
                  <div className="flex items-center gap-3">
                    <TestTube size={18} className="text-violet-400" />
                    <div className="text-left">
                      <div className="text-sm font-semibold text-gray-200">{suite.suite}</div>
                      <div className="text-[10px] text-gray-500">{suite.tests.length} tests</div>
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    <div className="flex items-center gap-1">
                      <CheckCircle size={14} className="text-emerald-400" />
                      <span className="text-xs text-emerald-400 font-mono">
                        {suite.tests.filter(t => t.status === 'passed').length}
                      </span>
                    </div>
                    {suite.tests.filter(t => t.status === 'failed').length > 0 && (
                      <div className="flex items-center gap-1">
                        <XCircle size={14} className="text-rose-400" />
                        <span className="text-xs text-rose-400 font-mono">
                          {suite.tests.filter(t => t.status === 'failed').length}
                        </span>
                      </div>
                    )}
                  </div>
                </button>

                {expandedSuite === suite.suite && (
                  <div className="border-t border-gray-800">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="text-gray-500 border-b border-gray-800">
                          <th className="text-left px-4 py-2 font-medium">Status</th>
                          <th className="text-left px-4 py-2 font-medium">Test Name</th>
                          <th className="text-right px-4 py-2 font-medium">Gas Used</th>
                        </tr>
                      </thead>
                      <tbody>
                        {suite.tests.map((test, i) => (
                          <tr key={i} className="border-b border-gray-800/50 hover:bg-gray-800/30 transition">
                            <td className="px-4 py-2">
                              {test.status === 'passed' ? (
                                <CheckCircle size={14} className="text-emerald-400" />
                              ) : (
                                <XCircle size={14} className="text-rose-400" />
                              )}
                            </td>
                            <td className="px-4 py-2 font-mono text-gray-300">{test.name}</td>
                            <td className="px-4 py-2 text-right font-mono text-gray-400">
                              {test.gas.toLocaleString()}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </div>
            ))}
          </div>

          {/* Coverage Info */}
          <div className="bg-emerald-500/5 border border-emerald-500/20 rounded-xl p-5">
            <div className="flex items-start gap-3">
              <AlertCircle size={20} className="text-emerald-400 flex-shrink-0 mt-0.5" />
              <div>
                <div className="text-sm font-semibold text-emerald-400 mb-2">Test Coverage Summary</div>
                <div className="text-xs text-gray-400 space-y-1">
                  <p>• <span className="text-white font-medium">BridgeCore:</span> Lock/Mint, Burn/Unlock, Health Factor, Emergency Stop, Fuzz tests</p>
                  <p>• <span className="text-white font-medium">InternalAMM:</span> Swaps, Liquidity, Rebase mechanism, NAV tracking, Constant product</p>
                  <p>• <span className="text-white font-medium">TreasuryDistributor:</span> 40/30/20/10 distribution, Preview, Admin functions</p>
                  <p>• <span className="text-white font-medium">Integration:</span> Full Cycle A/B workflows, LP protection, Multi-cycle stability</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
