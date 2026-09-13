import { Layers, TrendingUp, TrendingDown, RefreshCw } from 'lucide-react';
import type { PoolState, OracleState } from '../types';

interface Props {
  pool: PoolState;
  oracle: OracleState;
}

export function PoolMonitor({ pool, oracle }: Props) {
  const usdsRatio = (pool.usdsReserve / (pool.usdsReserve + pool.ethsReserve * oracle.internalPrice)) * 100;
  const ethsRatio = 100 - usdsRatio;

  return (
    <div className="space-y-6">
      {/* Pool Overview */}
      <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-6">
        <div className="flex items-center justify-between mb-6">
          <h3 className="text-lg font-semibold text-gray-200 flex items-center gap-2">
            <Layers size={20} className="text-violet-400" />
            Internal AMM Pool (USDS/ETHS)
          </h3>
          <div className="flex items-center gap-2">
            <span className="text-xs text-gray-500">Constant Product:</span>
            <span className="text-xs font-mono text-violet-400">k = {pool.k.toLocaleString()}</span>
          </div>
        </div>

        {/* Pool Composition Bar */}
        <div className="mb-6">
          <div className="flex justify-between text-xs text-gray-400 mb-2">
            <span>USDS: {usdsRatio.toFixed(1)}%</span>
            <span>ETHS: {ethsRatio.toFixed(1)}%</span>
          </div>
          <div className="w-full h-6 bg-gray-800 rounded-full overflow-hidden flex">
            <div
              className="h-full bg-gradient-to-r from-emerald-500 to-emerald-400 transition-all duration-500"
              style={{ width: `${usdsRatio}%` }}
            />
            <div
              className="h-full bg-gradient-to-r from-violet-500 to-violet-400 transition-all duration-500"
              style={{ width: `${ethsRatio}%` }}
            />
          </div>
        </div>

        {/* Reserves */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div className="bg-gray-800/50 rounded-lg p-4">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">USDS Reserve</div>
            <div className="text-lg font-bold text-emerald-400 font-mono">{pool.usdsReserve.toLocaleString('en-US', { maximumFractionDigits: 0 })}</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-4">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">ETHS Reserve</div>
            <div className="text-lg font-bold text-violet-400 font-mono">{pool.ethsReserve.toFixed(2)}</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-4">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Total LP Shares</div>
            <div className="text-lg font-bold text-white font-mono">{pool.totalLPShares.toLocaleString()}</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-4">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">NAV per LP Share</div>
            <div className="text-lg font-bold text-cyan-400 font-mono">${pool.navPerLP.toFixed(2)}</div>
          </div>
        </div>
      </div>

      {/* Rebase Mechanism */}
      <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-6">
        <h4 className="text-sm font-semibold text-gray-200 flex items-center gap-2 mb-4">
          <RefreshCw size={16} className="text-amber-400" />
          Zero-Loss LP Rebase Mechanism
        </h4>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="bg-amber-500/5 border border-amber-500/20 rounded-lg p-4">
            <div className="text-amber-400 text-xs font-medium mb-2 flex items-center gap-1">
              <TrendingUp size={12} /> NAV Monitoring
            </div>
            <p className="text-[11px] text-gray-400">
              Continuous comparison of real asset value vs initial LP deposit. Triggered every block.
            </p>
            <div className="mt-2 text-xs font-mono text-amber-300">
              Current NAV: ${pool.navPerLP.toFixed(2)} / share
            </div>
          </div>
          <div className="bg-emerald-500/5 border border-emerald-500/20 rounded-lg p-4">
            <div className="text-emerald-400 text-xs font-medium mb-2 flex items-center gap-1">
              <TrendingDown size={12} /> Compensatory Mint
            </div>
            <p className="text-[11px] text-gray-400">
              If imbalance detected, smart contract mints compensatory USDS proportional to LP shares.
            </p>
            <div className="mt-2 text-xs font-mono text-emerald-300">
              Status: {pool.navPerLP >= pool.initialNAV ? '✓ No deficit' : '⚠ Rebasing needed'}
            </div>
          </div>
          <div className="bg-violet-500/5 border border-violet-500/20 rounded-lg p-4">
            <div className="text-violet-400 text-xs font-medium mb-2 flex items-center gap-1">
              <RefreshCw size={12} /> Pool Rebalancing
            </div>
            <p className="text-[11px] text-gray-400">
              Algorithmic burn of excess side + mint of deficit side to restore 50/50 target ratio.
            </p>
            <div className="mt-2 text-xs font-mono text-violet-300">
              Target: 50/50 | Current: {usdsRatio.toFixed(0)}/{ethsRatio.toFixed(0)}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
