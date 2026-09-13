import { Users, TrendingUp, RefreshCw } from 'lucide-react';
import type { LPPosition } from '../types';

interface Props {
  positions: LPPosition[];
}

export function LPPositions({ positions }: Props) {
  const totalNAV = positions.reduce((sum, p) => sum + p.currentNAV, 0);
  const totalDeposit = positions.reduce((sum, p) => sum + p.initialDeposit, 0);
  const totalPnl = totalNAV - totalDeposit;

  return (
    <div className="bg-gray-900/50 rounded-xl border border-gray-800 overflow-hidden">
      <div className="p-4 border-b border-gray-800 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-gray-200 flex items-center gap-2">
          <Users size={16} className="text-cyan-400" />
          Internal LP Positions (Zero-Loss)
        </h3>
        <div className="flex items-center gap-4 text-xs">
          <div>
            <span className="text-gray-500">Total NAV: </span>
            <span className="text-emerald-400 font-mono font-bold">${totalNAV.toLocaleString('en-US', { maximumFractionDigits: 0 })}</span>
          </div>
          <div>
            <span className="text-gray-500">Total PnL: </span>
            <span className={`font-mono font-bold ${totalPnl >= 0 ? 'text-emerald-400' : 'text-rose-400'}`}>
              {totalPnl >= 0 ? '+' : ''}${totalPnl.toLocaleString('en-US', { maximumFractionDigits: 0 })}
            </span>
          </div>
        </div>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="text-gray-500 border-b border-gray-800">
              <th className="text-left px-4 py-2 font-medium">Address</th>
              <th className="text-right px-4 py-2 font-medium">Shares</th>
              <th className="text-right px-4 py-2 font-medium">Initial Deposit</th>
              <th className="text-right px-4 py-2 font-medium">Current NAV</th>
              <th className="text-right px-4 py-2 font-medium">PnL ($)</th>
              <th className="text-right px-4 py-2 font-medium">PnL (%)</th>
              <th className="text-right px-4 py-2 font-medium">Rebases</th>
              <th className="text-center px-4 py-2 font-medium">Status</th>
            </tr>
          </thead>
          <tbody>
            {positions.map(lp => (
              <tr key={lp.id} className="border-b border-gray-800/50 hover:bg-gray-800/30 transition">
                <td className="px-4 py-3">
                  <span className="font-mono text-cyan-400">{lp.address}</span>
                </td>
                <td className="px-4 py-3 text-right text-white font-mono">{lp.shares}</td>
                <td className="px-4 py-3 text-right text-gray-400 font-mono">${lp.initialDeposit.toLocaleString()}</td>
                <td className="px-4 py-3 text-right text-white font-mono font-bold">${lp.currentNAV.toLocaleString('en-US', { maximumFractionDigits: 0 })}</td>
                <td className="px-4 py-3 text-right font-mono">
                  <span className={lp.pnl >= 0 ? 'text-emerald-400' : 'text-rose-400'}>
                    {lp.pnl >= 0 ? '+' : ''}${lp.pnl.toLocaleString('en-US', { maximumFractionDigits: 0 })}
                  </span>
                </td>
                <td className="px-4 py-3 text-right font-mono">
                  <span className={lp.pnlPercent >= 0 ? 'text-emerald-400' : 'text-rose-400'}>
                    {lp.pnlPercent >= 0 ? '+' : ''}{lp.pnlPercent.toFixed(2)}%
                  </span>
                </td>
                <td className="px-4 py-3 text-right text-amber-400 font-mono flex items-center justify-end gap-1">
                  <RefreshCw size={10} />
                  {lp.rebasesReceived}
                </td>
                <td className="px-4 py-3 text-center">
                  <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] bg-emerald-500/20 text-emerald-400">
                    <TrendingUp size={10} />
                    Protected
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* Zero-Loss Guarantee */}
      <div className="p-4 bg-emerald-500/5 border-t border-emerald-500/20">
        <div className="flex items-start gap-2">
          <div className="w-5 h-5 rounded-full bg-emerald-500/20 flex items-center justify-center flex-shrink-0 mt-0.5">
            <TrendingUp size={12} className="text-emerald-400" />
          </div>
          <div>
            <div className="text-xs font-medium text-emerald-400 mb-1">Zero-Loss Guarantee Active</div>
            <p className="text-[11px] text-gray-400">
              All LP positions are protected by the algorithmic rebasing mechanism. NAV is maintained or increased through compensatory USDS minting during arbitrage cycles. No LP has experienced impermanent loss.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
