import { useState, useEffect, useCallback, useRef } from 'react';
import type { ArbCycle, BridgeState, PoolState, ProfitDistribution, OracleState, SystemMetrics, LPPosition, PriceHistory } from '../types';

const INITIAL_BRIDGE: BridgeState = {
  canonicalUSDC: 500000,
  canonicalETH: 120,
  syntheticUSDS: 450000,
  syntheticETHS: 100,
  healthFactor: 185,
  totalLocked: 800000,
  totalMinted: 750000,
};

const INITIAL_POOL: PoolState = {
  usdsReserve: 500000,
  ethsReserve: 200,
  totalLPShares: 1000,
  k: 100000000,
  navPerLP: 1000,
  initialNAV: 1000,
};

const INITIAL_ORACLE: OracleState = {
  externalPrice: 2500,
  internalPrice: 2375,
  gradient: -5,
  lastUpdate: Date.now(),
  mode: 'underprice',
};

const INITIAL_METRICS: SystemMetrics = {
  totalProfit: 0,
  totalCycles: 0,
  successfulCycles: 0,
  failedCycles: 0,
  uptime: 0,
  avgProfitPerCycle: 0,
  currentSpread: 5,
};

const INITIAL_DISTRIBUTION: ProfitDistribution = {
  owner: 0,
  bridgeReserve: 0,
  insuranceFund: 0,
  rebalanceFund: 0,
  totalDistributed: 0,
};

const LP_POSITIONS: LPPosition[] = [
  { id: '1', address: '0x7a3F...8b2E', shares: 400, initialDeposit: 200000, currentNAV: 200000, pnl: 0, pnlPercent: 0, rebasesReceived: 0 },
  { id: '2', address: '0x1c9D...4f7A', shares: 300, initialDeposit: 150000, currentNAV: 150000, pnl: 0, pnlPercent: 0, rebasesReceived: 0 },
  { id: '3', address: '0x5e2B...9d1C', shares: 200, initialDeposit: 100000, currentNAV: 100000, pnl: 0, pnlPercent: 0, rebasesReceived: 0 },
  { id: '4', address: '0x8f4A...3e6D', shares: 100, initialDeposit: 50000, currentNAV: 50000, pnl: 0, pnlPercent: 0, rebasesReceived: 0 },
];

function generateCycle(type: 'A' | 'B', oracle: OracleState): ArbCycle {
  const volume = Math.floor(Math.random() * 50 + 10); // 10-60 ETH
  const spread = Math.abs(oracle.gradient) + Math.random() * 2;
  const profit = volume * oracle.externalPrice * (spread / 100) * 0.3;
  
  return {
    id: `cycle-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
    type,
    timestamp: Date.now(),
    ethPriceExternal: oracle.externalPrice,
    ethPriceInternal: oracle.internalPrice,
    spread: parseFloat(spread.toFixed(2)),
    volume,
    profit: parseFloat(profit.toFixed(2)),
    status: 'pending',
  };
}

export function useSimulation() {
  const [bridge, setBridge] = useState<BridgeState>(INITIAL_BRIDGE);
  const [pool, setPool] = useState<PoolState>(INITIAL_POOL);
  const [oracle, setOracle] = useState<OracleState>(INITIAL_ORACLE);
  const [metrics, setMetrics] = useState<SystemMetrics>(INITIAL_METRICS);
  const [distribution, setDistribution] = useState<ProfitDistribution>(INITIAL_DISTRIBUTION);
  const [cycles, setCycles] = useState<ArbCycle[]>([]);
  const [lpPositions, setLpPositions] = useState<LPPosition[]>(LP_POSITIONS);
  const [priceHistory, setPriceHistory] = useState<PriceHistory[]>([]);
  const [isRunning, setIsRunning] = useState(true);
  const [speed, setSpeed] = useState(2000);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const simulateStep = useCallback(() => {
    // Update oracle with slight random walk
    setOracle(prev => {
      const priceChange = (Math.random() - 0.5) * 50;
      const newExternal = Math.max(2000, Math.min(3500, prev.externalPrice + priceChange));
      
      // Alternate between underprice and overprice modes
      const modeSwitch = Math.random();
      let gradient: number;
      let mode: OracleState['mode'];
      
      if (modeSwitch < 0.4) {
        gradient = -(Math.random() * 8 + 2); // underprice -5% to -10%
        mode = 'underprice';
      } else if (modeSwitch < 0.8) {
        gradient = Math.random() * 8 + 2; // overprice +2% to +10%
        mode = 'overprice';
      } else {
        gradient = (Math.random() - 0.5) * 3;
        mode = 'neutral';
      }
      
      const internalPrice = newExternal * (1 + gradient / 100);
      
      return {
        externalPrice: parseFloat(newExternal.toFixed(2)),
        internalPrice: parseFloat(internalPrice.toFixed(2)),
        gradient: parseFloat(gradient.toFixed(2)),
        lastUpdate: Date.now(),
        mode,
      };
    });

    // Generate new cycle
    const cycleType = Math.random() > 0.5 ? 'A' : 'B';
    const newCycle = generateCycle(cycleType, oracle);
    
    // Simulate cycle execution
    setTimeout(() => {
      setCycles(prev => {
        const updated = prev.map(c => 
          c.id === newCycle.id ? { ...c, status: 'executing' as const } : c
        );
        return [newCycle, ...updated].slice(0, 50);
      });
    }, 500);

    setTimeout(() => {
      const success = Math.random() > 0.05; // 95% success rate
      
      setCycles(prev => prev.map(c => 
        c.id === newCycle.id ? { ...c, status: success ? 'completed' : 'failed' } : c
      ));

      if (success) {
        // Update metrics
        setMetrics(prev => {
          const newTotal = prev.totalProfit + newCycle.profit;
          const newCycles = prev.totalCycles + 1;
          return {
            ...prev,
            totalProfit: parseFloat(newTotal.toFixed(2)),
            totalCycles: newCycles,
            successfulCycles: prev.successfulCycles + 1,
            avgProfitPerCycle: parseFloat((newTotal / newCycles).toFixed(2)),
            currentSpread: newCycle.spread,
            uptime: prev.uptime + 1,
          };
        });

        // Distribute profit
        setDistribution(prev => ({
          owner: parseFloat((prev.owner + newCycle.profit * 0.4).toFixed(2)),
          bridgeReserve: parseFloat((prev.bridgeReserve + newCycle.profit * 0.3).toFixed(2)),
          insuranceFund: parseFloat((prev.insuranceFund + newCycle.profit * 0.2).toFixed(2)),
          rebalanceFund: parseFloat((prev.rebalanceFund + newCycle.profit * 0.1).toFixed(2)),
          totalDistributed: parseFloat((prev.totalDistributed + newCycle.profit).toFixed(2)),
        }));

        // Update bridge
        setBridge(prev => {
          const hf = Math.max(120, Math.min(250, prev.healthFactor + (Math.random() - 0.3) * 5));
          return {
            ...prev,
            canonicalUSDC: prev.canonicalUSDC + newCycle.profit * 0.3,
            healthFactor: parseFloat(hf.toFixed(1)),
          };
        });

        // Update LP positions with rebasing
        setLpPositions(prev => prev.map(lp => {
          const rebalance = newCycle.profit * 0.1 * (lp.shares / 1000);
          const newNAV = lp.currentNAV + rebalance;
          return {
            ...lp,
            currentNAV: parseFloat(newNAV.toFixed(2)),
            pnl: parseFloat((newNAV - lp.initialDeposit).toFixed(2)),
            pnlPercent: parseFloat((((newNAV - lp.initialDeposit) / lp.initialDeposit) * 100).toFixed(2)),
            rebasesReceived: lp.rebasesReceived + 1,
          };
        }));
      } else {
        setMetrics(prev => ({
          ...prev,
          totalCycles: prev.totalCycles + 1,
          failedCycles: prev.failedCycles + 1,
        }));
      }
    }, 1500);

    // Update price history
    setPriceHistory(prev => {
      const newEntry = {
        timestamp: Date.now(),
        external: oracle.externalPrice,
        internal: oracle.internalPrice,
      };
      return [...prev, newEntry].slice(-100);
    });

  }, [oracle]);

  useEffect(() => {
    if (isRunning) {
      intervalRef.current = setInterval(simulateStep, speed);
    }
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [isRunning, speed, simulateStep]);

  const toggleSimulation = () => setIsRunning(prev => !prev);
  const resetSimulation = () => {
    setBridge(INITIAL_BRIDGE);
    setPool(INITIAL_POOL);
    setOracle(INITIAL_ORACLE);
    setMetrics(INITIAL_METRICS);
    setDistribution(INITIAL_DISTRIBUTION);
    setCycles([]);
    setLpPositions(LP_POSITIONS);
    setPriceHistory([]);
  };

  return {
    bridge,
    pool,
    oracle,
    metrics,
    distribution,
    cycles,
    lpPositions,
    priceHistory,
    isRunning,
    speed,
    setSpeed,
    toggleSimulation,
    resetSimulation,
  };
}
