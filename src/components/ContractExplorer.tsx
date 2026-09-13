import { useState } from 'react';
import { FileCode, Copy, Check } from 'lucide-react';

const contracts = [
  {
    name: 'BridgeCore.sol',
    description: 'Lock/Mint and Burn/Unlock contracts with role-based access and Health Factor verification',
    language: 'Solidity',
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract BridgeCore is AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    
    // Canonical assets on Base
    mapping(address => uint256) public lockedUSDC;
    mapping(address => uint256) public lockedETH;
    
    // Synthetic assets on Fork
    uint256 public totalUSDSMinted;
    uint256 public totalETHSMinted;
    
    // Health Factor
    uint256 public constant MIN_HEALTH_FACTOR = 15000; // 150%
    uint256 public constant EMERGENCY_THRESHOLD = 11000; // 110%
    
    uint256 public totalCanonicalValue; // in USDC terms
    bool public emergencyStopped;
    
    event Locked(address indexed user, uint256 amount, bool isETH);
    event Minted(address indexed user, uint256 amount, bool isETHS);
    event Burned(address indexed user, uint256 amount, bool isETHS);
    event Unlocked(address indexed user, uint256 amount, bool isETH);
    
    modifier whenNotStopped() {
        require(!emergencyStopped, "Bridge: emergency stopped");
        _;
    }
    
    function lockAndMint(address user, uint256 amount, bool isETH) 
        external onlyRole(OPERATOR_ROLE) whenNotStopped nonReentrant 
    {
        if (isETH) {
            lockedETH[user] += amount;
            totalCanonicalValue += amount * getETHPrice();
            _mintETHS(user, amount);
        } else {
            lockedUSDC[user] += amount;
            totalCanonicalValue += amount;
            _mintUSDS(user, amount);
        }
        
        require(getHealthFactor() >= MIN_HEALTH_FACTOR, "Bridge: HF too low");
        emit Locked(user, amount, isETH);
    }
    
    function burnAndUnlock(address user, uint256 amount, bool isETHS) 
        external onlyRole(OPERATOR_ROLE) whenNotStopped nonReentrant 
    {
        if (isETHS) {
            require(totalETHSMinted >= amount, "Bridge: insufficient ETHS");
            totalETHSMinted -= amount;
            totalCanonicalValue -= amount * getETHPrice();
            _unlockETH(user, amount);
        } else {
            require(totalUSDSMinted >= amount, "Bridge: insufficient USDS");
            totalUSDSMinted -= amount;
            totalCanonicalValue -= amount;
            _unlockUSDC(user, amount);
        }
        
        emit Burned(user, amount, isETHS);
    }
    
    function getHealthFactor() public view returns (uint256) {
        uint256 totalSynthetic = totalUSDSMinted + (totalETHSMinted * getETHPrice());
        if (totalSynthetic == 0) return type(uint256).max;
        return (totalCanonicalValue * 10000) / totalSynthetic;
    }
    
    function emergencyStop() external onlyRole(OPERATOR_ROLE) {
        if (getHealthFactor() < EMERGENCY_THRESHOLD) {
            emergencyStopped = true;
        }
    }
    
    function getETHPrice() internal view returns (uint256) {
        // Chainlink TWAP oracle call
        return 2500 * 1e6; // placeholder
    }
    
    function _mintUSDS(address to, uint256 amount) internal {
        totalUSDSMinted += amount;
        emit Minted(to, amount, false);
    }
    
    function _mintETHS(address to, uint256 amount) internal {
        totalETHSMinted += amount;
        emit Minted(to, amount, true);
    }
    
    function _unlockUSDC(address to, uint256 amount) internal {
        lockedUSDC[to] -= amount;
        emit Unlocked(to, amount, false);
    }
    
    function _unlockETH(address to, uint256 amount) internal {
        lockedETH[to] -= amount;
        emit Unlocked(to, amount, true);
    }
}`,
  },
  {
    name: 'InternalAMM.sol',
    description: 'Modified Uniswap V2-style pool with algorithmic burn/rebase for LP protection',
    language: 'Solidity',
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract InternalAMM is ERC20 {
    address public tokenUSDS;
    address public tokenETHS;
    
    uint256 public reserveUSDS;
    uint256 public reserveETHS;
    uint256 public constant K = 100_000_000_000; // x * y = k
    
    // LP tracking
    mapping(address => uint256) public lpInitialNAV;
    mapping(address => uint256) public lpRebasesReceived;
    
    // Oracle reference
    address public oracle;
    address public rebaseModule;
    
    event Swap(address indexed user, uint256 amountIn, uint256 amountOut, bool isUSDSIn);
    event Rebase(address indexed lp, uint256 amount);
    event PoolRebalanced(uint256 newReserveUSDS, uint256 newReserveETHS);
    
    constructor(address _usds, address _eths) ERC20("LP Token", "LP-USDS-ETHS") {
        tokenUSDS = _usds;
        tokenETHS = _eths;
    }
    
    function swap(uint256 amountIn, bool isUSDSIn) external returns (uint256 amountOut) {
        if (isUSDSIn) {
            // USDS -> ETHS
            uint256 amountInWithFee = amountIn * 997 / 1000; // 0.3% fee
            amountOut = (reserveETHS * amountInWithFee) / (reserveUSDS + amountInWithFee);
            reserveUSDS += amountIn;
            reserveETHS -= amountOut;
        } else {
            // ETHS -> USDS
            uint256 amountInWithFee = amountIn * 997 / 1000;
            amountOut = (reserveUSDS * amountInWithFee) / (reserveETHS + amountInWithFee);
            reserveETHS += amountIn;
            reserveUSDS -= amountOut;
        }
        
        emit Swap(msg.sender, amountIn, amountOut, isUSDSIn);
    }
    
    function addLiquidity(uint256 usdsAmount, uint256 ethsAmount) external returns (uint256 shares) {
        if (totalSupply() == 0) {
            shares = sqrt(usdsAmount * ethsAmount);
        } else {
            shares = min(
                (usdsAmount * totalSupply()) / reserveUSDS,
                (ethsAmount * totalSupply()) / reserveETHS
            );
        }
        
        require(shares > 0, "AMM: insufficient liquidity minted");
        
        reserveUSDS += usdsAmount;
        reserveETHS += ethsAmount;
        
        _mint(msg.sender, shares);
        lpInitialNAV[msg.sender] = getNAVPerShare() * shares;
    }
    
    function removeLiquidity(uint256 shares) external returns (uint256 usdsAmount, uint256 ethsAmount) {
        require(balanceOf(msg.sender) >= shares, "AMM: insufficient shares");
        
        usdsAmount = (shares * reserveUSDS) / totalSupply();
        ethsAmount = (shares * reserveETHS) / totalSupply();
        
        _burn(msg.sender, shares);
        reserveUSDS -= usdsAmount;
        reserveETHS -= ethsAmount;
    }
    
    // Rebase function called by rebase module
    function rebaseLP(address lp, uint256 usdsAmount) external {
        require(msg.sender == rebaseModule, "AMM: only rebase module");
        
        reserveUSDS += usdsAmount;
        lpRebasesReceived[lp] += usdsAmount;
        
        emit Rebase(lp, usdsAmount);
    }
    
    // Pool rebalancing: burn excess side, mint deficit side
    function rebalancePool(uint256 targetRatioUSDS, uint256 targetRatioETHS) external {
        require(msg.sender == rebaseModule, "AMM: only rebase module");
        
        uint256 totalValue = reserveUSDS + (reserveETHS * getOraclePrice());
        uint256 targetUSDS = (totalValue * targetRatioUSDS) / (targetRatioUSDS + targetRatioETHS);
        
        if (reserveUSDS > targetUSDS) {
            // Burn excess USDS
            uint256 excess = reserveUSDS - targetUSDS;
            reserveUSDS = targetUSDS;
            // Mint equivalent ETHS value for LPs
        } else {
            // Mint compensatory USDS
            uint256 deficit = targetUSDS - reserveUSDS;
            reserveUSDS = targetUSDS;
        }
        
        emit PoolRebalanced(reserveUSDS, reserveETHS);
    }
    
    function getNAVPerShare() public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 totalValue = reserveUSDS + (reserveETHS * getOraclePrice());
        return totalValue / totalSupply();
    }
    
    function getOraclePrice() internal view returns (uint256) {
        return 2500 * 1e6; // placeholder for oracle call
    }
    
    function sqrt(uint256 y) internal pure returns (uint256 z) {
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
    
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}`,
  },
  {
    name: 'TreasuryDistributor.sol',
    description: 'Automatic profit distribution: 40% Owner, 30% Bridge Reserve, 20% Insurance, 10% Rebase',
    language: 'Solidity',
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TreasuryDistributor is Ownable {
    // Distribution ratios (basis points)
    uint256 public constant OWNER_SHARE = 4000;       // 40%
    uint256 public constant BRIDGE_RESERVE_SHARE = 3000; // 30%
    uint256 public constant INSURANCE_SHARE = 2000;    // 20%
    uint256 public constant REBASE_SHARE = 1000;       // 10%
    
    // Recipient addresses
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
    
    IERC20 public usdc;
    
    event ProfitDistributed(uint256 total, uint256 owner, uint256 bridge, uint256 insurance, uint256 rebase);
    
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
    
    function distribute(uint256 amount) external {
        require(amount > 0, "Treasury: zero amount");
        require(usdc.balanceOf(address(this)) >= amount, "Treasury: insufficient balance");
        
        uint256 ownerAmount = (amount * OWNER_SHARE) / 10000;
        uint256 bridgeAmount = (amount * BRIDGE_RESERVE_SHARE) / 10000;
        uint256 insuranceAmount = (amount * INSURANCE_SHARE) / 10000;
        uint256 rebaseAmount = (amount * REBASE_SHARE) / 10000;
        
        usdc.transfer(ownerWallet, ownerAmount);
        usdc.transfer(bridgeReserve, bridgeAmount);
        usdc.transfer(insuranceFund, insuranceAmount);
        usdc.transfer(rebaseFund, rebaseAmount);
        
        totalDistributed += amount;
        totalOwnerWithdrawn += ownerAmount;
        totalBridgeDeposited += bridgeAmount;
        totalInsuranceDeposited += insuranceAmount;
        totalRebaseDeposited += rebaseAmount;
        
        emit ProfitDistributed(amount, ownerAmount, bridgeAmount, insuranceAmount, rebaseAmount);
    }
    
    function updateRecipients(
        address _owner,
        address _bridge,
        address _insurance,
        address _rebase
    ) external onlyOwner {
        ownerWallet = _owner;
        bridgeReserve = _bridge;
        insuranceFund = _insurance;
        rebaseFund = _rebase;
    }
    
    function getDistributionBreakdown(uint256 amount) 
        external pure returns (uint256, uint256, uint256, uint256) 
    {
        return (
            (amount * OWNER_SHARE) / 10000,
            (amount * BRIDGE_RESERVE_SHARE) / 10000,
            (amount * INSURANCE_SHARE) / 10000,
            (amount * REBASE_SHARE) / 10000
        );
    }
}`,
  },
  {
    name: 'ArbitrageBot.ts',
    description: 'Off-chain arbitrage bot (Rust/Go) for monitoring spreads and executing atomic transactions',
    language: 'TypeScript',
    code: `// Arbitrage Bot - Off-chain execution engine
// Language: Rust/Go for production, TypeScript for simulation

interface ArbConfig {
  externalPool: string;     // Base Mainnet pool address
  internalPool: string;     // Fork AMM address
  bridge: string;           // Bridge contract address
  oracle: string;           // Oracle contract address
  flashbotsRpc: string;     // Private RPC for MEV protection
  minProfitUSDC: number;    // Minimum profit threshold
  maxSlippage: number;      // Maximum acceptable slippage (bps)
}

class ArbitrageBot {
  private config: ArbConfig;
  private isRunning: boolean = false;
  
  constructor(config: ArbConfig) {
    this.config = config;
  }
  
  async start() {
    this.isRunning = true;
    console.log('[BOT] Starting arbitrage engine...');
    
    while (this.isRunning) {
      try {
        await this.monitorAndExecute();
      } catch (error) {
        console.error('[BOT] Error in cycle:', error);
      }
      
      await this.sleep(1000); // 1 second between checks
    }
  }
  
  private async monitorAndExecute() {
    // 1. Get prices from both sources
    const externalPrice = await this.getExternalPrice();
    const internalPrice = await this.getInternalPrice();
    
    // 2. Calculate spread
    const spread = ((externalPrice - internalPrice) / externalPrice) * 100;
    const absSpread = Math.abs(spread);
    
    // 3. Determine cycle type
    if (absSpread < 1.0) return; // No profitable opportunity
    
    if (spread > 0) {
      // Internal price > External → Cycle B
      await this.executeCycleB(absSpread, internalPrice, externalPrice);
    } else {
      // External price > Internal → Cycle A
      await this.executeCycleA(absSpread, externalPrice, internalPrice);
    }
  }
  
  private async executeCycleA(
    spread: number, 
    extPrice: number, 
    intPrice: number
  ) {
    console.log(\`[CYCLE A] Spread: \${spread.toFixed(2)}%\`);
    
    // Calculate optimal volume
    const volume = this.calculateOptimalVolume(spread, extPrice);
    
    // Build atomic transaction bundle
    const txBundle = [
      // 1. Buy ETH on external pool
      this.buildBuyETH(extPrice, volume),
      // 2. Lock ETH + Mint ETHS via bridge
      this.buildLockAndMint(volume),
      // 3. Sell ETHS in internal pool
      this.buildSellETHS(intPrice, volume),
      // 4. Burn USDS + Unlock USDC via bridge
      this.buildBurnAndUnlock(),
      // 5. Distribute profit
      this.buildDistributeProfit(),
    ];
    
    // Submit via Flashbots for MEV protection
    const result = await this.submitFlashbots(txBundle);
    
    if (result.profit > this.config.minProfitUSDC) {
      console.log(\`[CYCLE A] Profit: $\${result.profit.toFixed(2)}\`);
    }
  }
  
  private calculateOptimalVolume(spread: number, price: number): number {
    // Optimal volume considering:
    // - External pool depth (minimal slippage < 0.01%)
    // - Internal pool reserves
    // - Bridge capacity
    // - Gas costs
    
    const maxFromExternal = 60; // ETH - limited by external pool impact
    const maxFromInternal = 40; // ETH - limited by internal reserves
    const spreadMultiplier = Math.min(spread / 5, 1.5);
    
    return Math.min(maxFromExternal, maxFromInternal) * spreadMultiplier;
  }
  
  private async submitFlashbots(bundle: any[]) {
    // Submit to Flashbots Protect on Base
    // Ensures atomic execution and MEV protection
    return { profit: 0, success: true };
  }
  
  private sleep(ms: number) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
  
  async stop() {
    this.isRunning = false;
    console.log('[BOT] Stopping arbitrage engine...');
  }
}`,
  },
  {
    name: 'ManagedOracle.sol',
    description: 'Custom oracle with admin/algorithmic price adjustment for gradient control',
    language: 'Solidity',
    code: `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract ManagedOracle is AccessControl {
    bytes32 public constant ORACLE_ADMIN = keccak256("ORACLE_ADMIN");
    bytes32 public constant ALGO_CONTROLLER = keccak256("ALGO_CONTROLLER");
    
    // External fair price (from Chainlink TWAP)
    uint256 public externalPrice;
    uint256 public externalPriceTimestamp;
    
    // Internal managed price
    uint256 public internalPrice;
    uint256 public internalPriceTimestamp;
    
    // Gradient control
    int256 public maxGradientBps = 1000; // ±10% max
    int256 public currentGradientBps;
    
    // Mode
    enum Mode { UNDERPRICE, OVERPRICE, NEUTRAL }
    Mode public currentMode;
    
    event PriceUpdated(uint256 externalPrice, uint256 internalPrice, int256 gradient);
    event ModeChanged(Mode newMode);
    
    function setExternalPrice(uint256 _price) external onlyRole(ORACLE_ADMIN) {
        externalPrice = _price;
        externalPriceTimestamp = block.timestamp;
        _recalculateInternal();
    }
    
    function setGradient(int256 _gradientBps) external onlyRole(ALGO_CONTROLLER) {
        require(abs(_gradientBps) <= abs(maxGradientBps), "Oracle: gradient exceeds max");
        currentGradientBps = _gradientBps;
        _recalculateInternal();
    }
    
    function _recalculateInternal() internal {
        if (currentGradientBps >= 0) {
            internalPrice = externalPrice * (10000 + uint256(currentGradientBps)) / 10000;
            currentMode = currentGradientBps > 100 ? Mode.OVERPRICE : Mode.NEUTRAL;
        } else {
            internalPrice = externalPrice * (10000 + uint256(currentGradientBps)) / 10000;
            currentMode = currentGradientBps < -100 ? Mode.UNDERPRICE : Mode.NEUTRAL;
        }
        internalPriceTimestamp = block.timestamp;
        
        emit PriceUpdated(externalPrice, internalPrice, currentGradientBps);
        emit ModeChanged(currentMode);
    }
    
    function getPrices() external view returns (uint256, uint256, int256, Mode) {
        return (externalPrice, internalPrice, currentGradientBps, currentMode);
    }
    
    function isStale(uint256 maxAge) external view returns (bool) {
        return block.timestamp - externalPriceTimestamp > maxAge;
    }
    
    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}`,
  },
];

export function ContractExplorer() {
  const [activeContract, setActiveContract] = useState(0);
  const [copied, setCopied] = useState(false);

  const handleCopy = () => {
    navigator.clipboard.writeText(contracts[activeContract].code);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center gap-3 mb-2">
        <FileCode size={20} className="text-violet-400" />
        <h2 className="text-lg font-semibold text-gray-200">Smart Contract Source Code</h2>
      </div>

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
              <div className="text-[9px] text-gray-600 mt-1 uppercase">{contract.language}</div>
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
    </div>
  );
}
