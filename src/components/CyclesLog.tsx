import { Zap, CheckCircle, XCircle, Loader2, Clock } from 'lucide-react';
import type { ArbCycle, SystemMetrics } from '../types';

interface Props {
  cycles: ArbCycle[];
  metrics: SystemMetrics;
}

export function CyclesLog({ cycles, metrics }: Props) {
  const statusIcon = (status: ArbCycle['status']) => {
    switch (status) {
      case 'completed': return <CheckCircle size={14} className="text-emerald-400" />;
      case 'failed': return <XCircle size={14} className="text-rose-400" />;
      case 'executing': return <Loader2 size={14} className="text-amber-400 animate-spin" />;
      case 'pending': return <Clock size={14} className="text-gray-400" />;
    }
  };

  const statusColor = (status: ArbCycle['status']) => {
    switch (status) {
      case 'completed': return 'text-emerald-400';
      case 'failed': return 'text-rose-400';
      case 'executing': return 'text-amber-400';
      case 'pending': return 'text-gray-400';
    }
  };

  return (
    <div className="space-y-6">
      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
          <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Total Cycles</div>
          <div className="text-2xl font-bold text-white">{metrics.totalCycles}</div>
        </div>
        <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
          <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Successful</div>
          <div className="text-2xl font-bold text-emerald-400">{metrics.successfulCycles}</div>
        </div>
        <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
          <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Failed</div>
          <div className="text-2xl font-bold text-rose-400">{metrics.failedCycles}</div>
        </div>
        <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-4">
          <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Success Rate</div>
          <div className="text-2xl font-bold text-cyan-400">
            {metrics.totalCycles > 0 ? ((metrics.successfulCycles / metrics.totalCycles) * 100).toFixed(1) : '0'}%
          </div>
        </div>
      </div>

      {/* Cycle Log */}
      <div className="bg-gray-900/50 rounded-xl border border-gray-800 overflow-hidden">
        <div className="p-4 border-b border-gray-800 flex items-center justify-between">
          <h3 className="text-sm font-semibold text-gray-200 flex items-center gap-2">
            <Zap size={16} className="text-amber-400" />
            Arbitrage Cycle Log
          </h3>
          <span className="text-[10px] text-gray-500">Last {cycles.length} cycles</span>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="text-gray-500 border-b border-gray-800">
                <th className="text-left px-4 py-2 font-medium">Status</th>
                <th className="text-left px-4 py-2 font-medium">Type</th>
                <th className="text-left px-4 py-2 font-medium">Time</th>
                <th className="text-right px-4 py-2 font-medium">Ext. Price</th>
                <th className="text-right px-4 py-2 font-medium">Int. Price</th>
                <th className="text-right px-4 py-2 font-medium">Spread</th>
                <th className="text-right px-4 py-2 font-medium">Volume (ETH)</th>
                <th className="text-right px-4 py-2 font-medium">Profit</th>
              </tr>
            </thead>
            <tbody>
              {cycles.length === 0 ? (
                <tr>
                  <td colSpan={8} className="text-center py-8 text-gray-500">
                    Waiting for first arbitrage cycle...
                  </td>
                </tr>
              ) : (
                cycles.map(cycle => (
                  <tr key={cycle.id} className="border-b border-gray-800/50 hover:bg-gray-800/30 transition">
                    <td className="px-4 py-2.5">
                      <div className="flex items-center gap-1.5">
                        {statusIcon(cycle.status)}
                        <span className={`capitalize ${statusColor(cycle.status)}`}>{cycle.status}</span>
                      </div>
                    </td>
                    <td className="px-4 py-2.5">
                      <span className={`px-2 py-0.5 rounded text-[10px] font-bold ${
                        cycle.type === 'A'
                          ? 'bg-rose-500/20 text-rose-400'
                          : 'bg-emerald-500/20 text-emerald-400'
                      }`}>
                        Cycle {cycle.type}
                      </span>
                    </td>
                    <td className="px-4 py-2.5 text-gray-400 font-mono">
                      {new Date(cycle.timestamp).toLocaleTimeString()}
                    </td>
                    <td className="px-4 py-2.5 text-right text-cyan-400 font-mono">
                      ${cycle.ethPriceExternal.toFixed(2)}
                    </td>
                    <td className="px-4 py-2.5 text-right text-violet-400 font-mono">
                      ${cycle.ethPriceInternal.toFixed(2)}
                    </td>
                    <td className="px-4 py-2.5 text-right text-amber-400 font-mono">
                      {cycle.spread.toFixed(2)}%
                    </td>
                    <td className="px-4 py-2.5 text-right text-white font-mono">
                      {cycle.volume}
                    </td>
                    <td className="px-4 py-2.5 text-right font-mono">
                      <span className={cycle.status === 'completed' ? 'text-emerald-400' : 'text-gray-500'}>
                        ${cycle.profit.toLocaleString('en-US', { minimumFractionDigits: 2 })}
                      </span>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Cycle Description */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div className="bg-rose-500/5 border border-rose-500/20 rounded-xl p-5">
          <h4 className="text-sm font-semibold text-rose-400 mb-3">Cycle A: Extract from External Pool</h4>
          <div className="text-[11px] text-gray-400 space-y-1.5">
            <p>1. Buy canonical ETH on Base at market price</p>
            <p>2. Lock ETH → Mint ETHS on Fork</p>
            <p>3. Sell ETHS in internal pool at underpriced rate</p>
            <p>4. Burn USDS → Unlock USDC on Base</p>
            <p className="text-rose-300 font-medium pt-1">→ Net profit from spread extraction</p>
          </div>
        </div>
        <div className="bg-emerald-500/5 border border-emerald-500/20 rounded-xl p-5">
          <h4 className="text-sm font-semibold text-emerald-400 mb-3">Cycle B: Rebalance Internal Pool</h4>
          <div className="text-[11px] text-gray-400 space-y-1.5">
            <p>1. Buy ETHS in internal pool with USDS</p>
            <p>2. Burn ETHS → Unlock ETH on Base</p>
            <p>3. Sell ETH on Base at high market price</p>
            <p>4. Convert USDC → USDS for internal pool</p>
            <p className="text-emerald-300 font-medium pt-1">→ Pool rebalanced + additional spread profit</p>
          </div>
        </div>
      </div>
    </div>
  );
}
