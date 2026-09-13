import { TrendingUp, Zap, Shield, DollarSign, Activity } from 'lucide-react';
import type { SystemMetrics, OracleState, BridgeState } from '../types';

interface Props {
  metrics: SystemMetrics;
  oracle: OracleState;
  bridge: BridgeState;
}

export function SystemOverview({ metrics, oracle, bridge }: Props) {
  const cards = [
    {
      label: 'Total Canonical Profit',
      value: `$${metrics.totalProfit.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
      sub: `${metrics.successfulCycles} successful cycles`,
      icon: <DollarSign size={18} />,
      color: 'emerald',
    },
    {
      label: 'Current Spread',
      value: `${metrics.currentSpread.toFixed(2)}%`,
      sub: oracle.mode === 'underprice' ? 'Cycle A: Extracting' : oracle.mode === 'overprice' ? 'Cycle B: Rebalancing' : 'Neutral',
      icon: <Activity size={18} />,
      color: 'cyan',
    },
    {
      label: 'Bridge Health Factor',
      value: `${bridge.healthFactor.toFixed(1)}%`,
      sub: bridge.healthFactor >= 150 ? '✓ Above 150% target' : '⚠ Below target',
      icon: <Shield size={18} />,
      color: bridge.healthFactor >= 150 ? 'emerald' : 'amber',
    },
    {
      label: 'Avg Profit / Cycle',
      value: `$${metrics.avgProfitPerCycle.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
      sub: `Success: ${metrics.totalCycles > 0 ? ((metrics.successfulCycles / metrics.totalCycles) * 100).toFixed(1) : 0}%`,
      icon: <TrendingUp size={18} />,
      color: 'violet',
    },
    {
      label: 'Total Cycles',
      value: metrics.totalCycles.toString(),
      sub: `${metrics.failedCycles} failed`,
      icon: <Zap size={18} />,
      color: 'amber',
    },
    {
      label: 'Oracle Gradient',
      value: `${oracle.gradient > 0 ? '+' : ''}${oracle.gradient.toFixed(2)}%`,
      sub: `EXT: $${oracle.externalPrice.toFixed(0)} | INT: $${oracle.internalPrice.toFixed(0)}`,
      icon: <Activity size={18} />,
      color: oracle.gradient < 0 ? 'rose' : 'emerald',
    },
  ];

  const colorMap: Record<string, string> = {
    emerald: 'from-emerald-500/20 to-emerald-500/5 border-emerald-500/30 text-emerald-400',
    cyan: 'from-cyan-500/20 to-cyan-500/5 border-cyan-500/30 text-cyan-400',
    violet: 'from-violet-500/20 to-violet-500/5 border-violet-500/30 text-violet-400',
    amber: 'from-amber-500/20 to-amber-500/5 border-amber-500/30 text-amber-400',
    rose: 'from-rose-500/20 to-rose-500/5 border-rose-500/30 text-rose-400',
  };

  return (
    <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3">
      {cards.map((card, i) => (
        <div
          key={i}
          className={`relative overflow-hidden rounded-xl border bg-gradient-to-br p-4 ${colorMap[card.color]}`}
        >
          <div className="flex items-center justify-between mb-2">
            <span className="text-[10px] uppercase tracking-wider text-gray-400 font-medium">{card.label}</span>
            <div className="opacity-60">{card.icon}</div>
          </div>
          <div className="text-xl font-bold text-white mb-1">{card.value}</div>
          <div className="text-[10px] text-gray-400">{card.sub}</div>
        </div>
      ))}
    </div>
  );
}
