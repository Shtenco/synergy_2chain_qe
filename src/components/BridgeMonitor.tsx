import { Shield, ArrowDownRight, ArrowUpRight, Lock, Unlock } from 'lucide-react';
import type { BridgeState } from '../types';

interface Props {
  bridge: BridgeState;
  compact?: boolean;
}

export function BridgeMonitor({ bridge, compact }: Props) {
  const hfColor = bridge.healthFactor >= 150 ? 'text-emerald-400' : bridge.healthFactor >= 120 ? 'text-amber-400' : 'text-rose-400';
  const hfBg = bridge.healthFactor >= 150 ? 'bg-emerald-500' : bridge.healthFactor >= 120 ? 'bg-amber-500' : 'bg-rose-500';

  if (compact) {
    return (
      <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-sm font-semibold text-gray-200 flex items-center gap-2">
            <Shield size={16} className="text-cyan-400" />
            Bridge Status
          </h3>
          <span className={`text-xs font-mono font-bold ${hfColor}`}>HF: {bridge.healthFactor}%</span>
        </div>
        <div className="w-full bg-gray-800 rounded-full h-2 mb-4">
          <div className={`h-2 rounded-full transition-all duration-500 ${hfBg}`} style={{ width: `${Math.min(100, (bridge.healthFactor / 250) * 100)}%` }} />
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="bg-gray-800/50 rounded-lg p-3">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Canonical USDC</div>
            <div className="text-sm font-bold text-emerald-400">${bridge.canonicalUSDC.toLocaleString('en-US', { maximumFractionDigits: 0 })}</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-3">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1">Canonical ETH</div>
            <div className="text-sm font-bold text-cyan-400">{bridge.canonicalETH.toFixed(2)} ETH</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-3">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1 flex items-center gap-1"><Lock size={10} /> Total Locked</div>
            <div className="text-sm font-bold text-white">${bridge.totalLocked.toLocaleString('en-US', { maximumFractionDigits: 0 })}</div>
          </div>
          <div className="bg-gray-800/50 rounded-lg p-3">
            <div className="text-[10px] text-gray-500 uppercase tracking-wider mb-1 flex items-center gap-1"><Unlock size={10} /> Total Minted</div>
            <div className="text-sm font-bold text-violet-400">${bridge.totalMinted.toLocaleString('en-US', { maximumFractionDigits: 0 })}</div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Health Factor */}
      <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-6">
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold text-gray-200 flex items-center gap-2">
            <Shield size={20} className="text-cyan-400" />
            Bridge Health Factor
          </h3>
          <div className={`text-2xl font-bold font-mono ${hfColor}`}>{bridge.healthFactor}%</div>
        </div>
        <div className="w-full bg-gray-800 rounded-full h-4 mb-2">
          <div className={`h-4 rounded-full transition-all duration-500 ${hfBg}`} style={{ width: `${Math.min(100, (bridge.healthFactor / 250) * 100)}%` }} />
        </div>
        <div className="flex justify-between text-[10px] text-gray-500">
          <span>0%</span>
          <span className="text-rose-400">110% Emergency Stop</span>
          <span className="text-amber-400">150% Target</span>
          <span>250%+</span>
        </div>
      </div>

      {/* Reserves */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
          <h4 className="text-xs uppercase tracking-wider text-gray-500 mb-4 flex items-center gap-2">
            <ArrowDownRight size={14} className="text-emerald-400" />
            Canonical Assets (Base Mainnet)
          </h4>
          <div className="space-y-3">
            <div className="flex justify-between items-center">
              <span className="text-gray-400 text-sm">USDC Reserve</span>
              <span className="text-emerald-400 font-mono font-bold">${bridge.canonicalUSDC.toLocaleString('en-US', { maximumFractionDigits: 0 })}</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-gray-400 text-sm">ETH Reserve</span>
              <span className="text-cyan-400 font-mono font-bold">{bridge.canonicalETH.toFixed(2)} ETH</span>
            </div>
            <div className="flex justify-between items-center pt-2 border-t border-gray-800">
              <span className="text-gray-300 text-sm font-medium">Total Value</span>
              <span className="text-white font-mono font-bold">${(bridge.canonicalUSDC + bridge.canonicalETH * 2500).toLocaleString('en-US', { maximumFractionDigits: 0 })}</span>
            </div>
          </div>
        </div>

        <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
          <h4 className="text-xs uppercase tracking-wider text-gray-500 mb-4 flex items-center gap-2">
            <ArrowUpRight size={14} className="text-violet-400" />
            Synthetic Assets (Internal Fork)
          </h4>
          <div className="space-y-3">
            <div className="flex justify-between items-center">
              <span className="text-gray-400 text-sm">USDS Supply</span>
              <span className="text-emerald-400 font-mono font-bold">{bridge.syntheticUSDS.toLocaleString('en-US', { maximumFractionDigits: 0 })} USDS</span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-gray-400 text-sm">ETHS Supply</span>
              <span className="text-violet-400 font-mono font-bold">{bridge.syntheticETHS.toFixed(2)} ETHS</span>
            </div>
            <div className="flex justify-between items-center pt-2 border-t border-gray-800">
              <span className="text-gray-300 text-sm font-medium">Total Supply</span>
              <span className="text-white font-mono font-bold">${(bridge.syntheticUSDS + bridge.syntheticETHS * 2500).toLocaleString('en-US', { maximumFractionDigits: 0 })}</span>
            </div>
          </div>
        </div>
      </div>

      {/* Bridge Operations */}
      <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
        <h4 className="text-xs uppercase tracking-wider text-gray-500 mb-4">Bridge Operations</h4>
        <div className="grid grid-cols-2 gap-4">
          <div className="bg-emerald-500/5 border border-emerald-500/20 rounded-lg p-4">
            <div className="text-emerald-400 text-xs font-medium mb-2">Lock/Mint (Base → Fork)</div>
            <div className="text-[11px] text-gray-400 space-y-1">
              <p>• Lock canonical ETH/USDC on Base</p>
              <p>• Mint equivalent ETHS/USDS on Fork</p>
              <p>• Verify Health Factor ≥ 150%</p>
            </div>
          </div>
          <div className="bg-violet-500/5 border border-violet-500/20 rounded-lg p-4">
            <div className="text-violet-400 text-xs font-medium mb-2">Burn/Unlock (Fork → Base)</div>
            <div className="text-[11px] text-gray-400 space-y-1">
              <p>• Burn synthetic ETHS/USDS on Fork</p>
              <p>• Unlock canonical ETH/USDC on Base</p>
              <p>• Verify collateralization maintained</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
