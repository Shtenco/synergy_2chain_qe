import { Eye, TrendingUp, TrendingDown, Minus } from 'lucide-react';
import type { OracleState } from '../types';

interface Props {
  oracle: OracleState;
}

export function OracleStatus({ oracle }: Props) {
  const modeConfig = {
    underprice: { label: 'UNDERPRICE', color: 'text-rose-400', bg: 'bg-rose-500/10 border-rose-500/30', icon: <TrendingDown size={16} />, cycle: 'A' },
    overprice: { label: 'OVERPRICE', color: 'text-emerald-400', bg: 'bg-emerald-500/10 border-emerald-500/30', icon: <TrendingUp size={16} />, cycle: 'B' },
    neutral: { label: 'NEUTRAL', color: 'text-gray-400', bg: 'bg-gray-500/10 border-gray-500/30', icon: <Minus size={16} />, cycle: '-' },
  };

  const config = modeConfig[oracle.mode];

  return (
    <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-gray-200 flex items-center gap-2">
          <Eye size={16} className="text-amber-400" />
          Oracle Status
        </h3>
        <div className={`flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[10px] font-bold border ${config.bg} ${config.color}`}>
          {config.icon}
          {config.label} → Cycle {config.cycle}
        </div>
      </div>

      <div className="space-y-4">
        {/* Price Comparison */}
        <div className="grid grid-cols-2 gap-3">
          <div className="bg-gray-800/50 rounded-lg p-3">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">External (Base)</div>
            <div className="text-lg font-bold text-cyan-400 font-mono">${oracle.externalPrice.toFixed(2)}</div>
            <div className="text-[10px] text-gray-500">Chainlink TWAP</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-3">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Internal (Fork)</div>
            <div className="text-lg font-bold text-violet-400 font-mono">${oracle.internalPrice.toFixed(2)}</div>
            <div className="text-[10px] text-gray-500">Managed Oracle</div>
          </div>
        </div>

        {/* Gradient Visualization */}
        <div>
          <div className="flex justify-between text-[10px] text-gray-500 mb-1">
            <span>Price Gradient</span>
            <span className={`font-mono font-bold ${config.color}`}>{oracle.gradient > 0 ? '+' : ''}{oracle.gradient.toFixed(2)}%</span>
          </div>
          <div className="relative w-full h-8 bg-gray-800 rounded-lg overflow-hidden">
            {/* Center line */}
            <div className="absolute left-1/2 top-0 bottom-0 w-px bg-gray-600" />
            {/* Gradient indicator */}
            <div
              className={`absolute top-1 bottom-1 rounded transition-all duration-500 ${
                oracle.gradient < 0 ? 'bg-rose-500/50 right-1/2' : 'bg-emerald-500/50 left-1/2'
              }`}
              style={{ width: `${Math.min(50, Math.abs(oracle.gradient) * 5)}%` }}
            />
            {/* Labels */}
            <div className="absolute inset-0 flex items-center justify-between px-2">
              <span className="text-[9px] text-gray-500">-10%</span>
              <span className="text-[9px] text-gray-500">0%</span>
              <span className="text-[9px] text-gray-500">+10%</span>
            </div>
          </div>
        </div>

        {/* Last Update */}
        <div className="flex items-center justify-between text-[10px] text-gray-500 pt-2 border-t border-gray-800">
          <span>Last update: {new Date(oracle.lastUpdate).toLocaleTimeString()}</span>
          <span>Update interval: 2s</span>
        </div>
      </div>
    </div>
  );
}
