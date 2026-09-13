export interface ArbCycle {
  id: string;
  type: 'A' | 'B';
  timestamp: number;
  ethPriceExternal: number;
  ethPriceInternal: number;
  spread: number;
  volume: number;
  profit: number;
  status: 'pending' | 'executing' | 'completed' | 'failed';
}

export interface BridgeState {
  canonicalUSDC: number;
  canonicalETH: number;
  syntheticUSDS: number;
  syntheticETHS: number;
  healthFactor: number;
  totalLocked: number;
  totalMinted: number;
}

export interface PoolState {
  usdsReserve: number;
  ethsReserve: number;
  totalLPShares: number;
  k: number; // constant product
  navPerLP: number;
  initialNAV: number;
}

export interface ProfitDistribution {
  owner: number;
  bridgeReserve: number;
  insuranceFund: number;
  rebalanceFund: number;
  totalDistributed: number;
}

export interface OracleState {
  externalPrice: number;
  internalPrice: number;
  gradient: number; // percentage difference
  lastUpdate: number;
  mode: 'underprice' | 'overprice' | 'neutral';
}

export interface SystemMetrics {
  totalProfit: number;
  totalCycles: number;
  successfulCycles: number;
  failedCycles: number;
  uptime: number;
  avgProfitPerCycle: number;
  currentSpread: number;
}

export interface LPPosition {
  id: string;
  address: string;
  shares: number;
  initialDeposit: number;
  currentNAV: number;
  pnl: number;
  pnlPercent: number;
  rebasesReceived: number;
}

export interface PriceHistory {
  timestamp: number;
  external: number;
  internal: number;
}
