import { Globe, ArrowLeftRight, Layers, Coins } from 'lucide-react';

export function ArchitectureDiagram() {
  return (
    <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-6">
      <h3 className="text-sm font-semibold text-gray-200 mb-6">System Architecture (4 Levels)</h3>
      
      <div className="space-y-3">
        {/* L1 */}
        <div className="flex items-stretch gap-3">
          <div className="w-16 flex-shrink-0 flex items-center justify-center rounded-lg bg-cyan-500/10 border border-cyan-500/30">
            <span className="text-xs font-bold text-cyan-400">L1</span>
          </div>
          <div className="flex-1 bg-cyan-500/5 border border-cyan-500/20 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-2">
              <Globe size={14} className="text-cyan-400" />
              <span className="text-xs font-semibold text-cyan-400">External Market (Base Mainnet)</span>
            </div>
            <div className="grid grid-cols-3 gap-2 text-[10px] text-gray-400">
              <div>• Canonical USDC/ETH</div>
              <div>• External Pool TVL: $118M+</div>
              <div>• Price Oracle (Chainlink)</div>
            </div>
          </div>
        </div>

        {/* Arrow */}
        <div className="flex items-center justify-center">
          <div className="flex items-center gap-2 text-gray-600">
            <div className="w-px h-4 bg-gray-700" />
            <ArrowLeftRight size={14} />
            <span className="text-[10px] text-gray-500">Lock/Mint • Burn/Unlock</span>
            <div className="w-px h-4 bg-gray-700" />
          </div>
        </div>

        {/* L2 */}
        <div className="flex items-stretch gap-3">
          <div className="w-16 flex-shrink-0 flex items-center justify-center rounded-lg bg-violet-500/10 border border-violet-500/30">
            <span className="text-xs font-bold text-violet-400">L2</span>
          </div>
          <div className="flex-1 bg-violet-500/5 border border-violet-500/20 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-2">
              <ArrowLeftRight size={14} className="text-violet-400" />
              <span className="text-xs font-semibold text-violet-400">Bridge (Transmutation Layer)</span>
            </div>
            <div className="grid grid-cols-3 gap-2 text-[10px] text-gray-400">
              <div>• Lock/Mint contracts</div>
              <div>• Burn/Unlock contracts</div>
              <div>• Health Factor Monitor</div>
            </div>
          </div>
        </div>

        {/* Arrow */}
        <div className="flex items-center justify-center">
          <div className="flex items-center gap-2 text-gray-600">
            <div className="w-px h-4 bg-gray-700" />
            <ArrowLeftRight size={14} />
            <span className="text-[10px] text-gray-500">Oracle Gradient • Rebase</span>
            <div className="w-px h-4 bg-gray-700" />
          </div>
        </div>

        {/* L3 */}
        <div className="flex items-stretch gap-3">
          <div className="w-16 flex-shrink-0 flex items-center justify-center rounded-lg bg-amber-500/10 border border-amber-500/30">
            <span className="text-xs font-bold text-amber-400">L3</span>
          </div>
          <div className="flex-1 bg-amber-500/5 border border-amber-500/20 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-2">
              <Layers size={14} className="text-amber-400" />
              <span className="text-xs font-semibold text-amber-400">Internal Fork (AMM + Oracle)</span>
            </div>
            <div className="grid grid-cols-3 gap-2 text-[10px] text-gray-400">
              <div>• USDS/ETHS Pool (x*y=k)</div>
              <div>• Managed Oracle</div>
              <div>• Rebase Module</div>
            </div>
          </div>
        </div>

        {/* Arrow */}
        <div className="flex items-center justify-center">
          <div className="flex items-center gap-2 text-gray-600">
            <div className="w-px h-4 bg-gray-700" />
            <ArrowLeftRight size={14} />
            <span className="text-[10px] text-gray-500">Mint/Burn Synthetic</span>
            <div className="w-px h-4 bg-gray-700" />
          </div>
        </div>

        {/* L4 */}
        <div className="flex items-stretch gap-3">
          <div className="w-16 flex-shrink-0 flex items-center justify-center rounded-lg bg-emerald-500/10 border border-emerald-500/30">
            <span className="text-xs font-bold text-emerald-400">L4</span>
          </div>
          <div className="flex-1 bg-emerald-500/5 border border-emerald-500/20 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-2">
              <Coins size={14} className="text-emerald-400" />
              <span className="text-xs font-semibold text-emerald-400">Synthetic Assets</span>
            </div>
            <div className="grid grid-cols-3 gap-2 text-[10px] text-gray-400">
              <div>• USDS (Synthetic Dollar)</div>
              <div>• ETHS (Synthetic Ether)</div>
              <div>• Algorithmically Backed</div>
            </div>
          </div>
        </div>
      </div>

      {/* Sustainability Conditions */}
      <div className="mt-6 grid grid-cols-1 md:grid-cols-3 gap-3">
        <div className="bg-emerald-500/5 border border-emerald-500/20 rounded-lg p-3">
          <div className="text-[10px] text-emerald-400 font-bold uppercase tracking-wider mb-1">Condition 1</div>
          <div className="text-[11px] text-gray-300">Inflow ≥ Emission</div>
          <div className="text-[10px] text-gray-500 mt-1">Arb profit + fees cover USDS emission for LP compensation</div>
        </div>
        <div className="bg-cyan-500/5 border border-cyan-500/20 rounded-lg p-3">
          <div className="text-[10px] text-cyan-400 font-bold uppercase tracking-wider mb-1">Condition 2</div>
          <div className="text-[11px] text-gray-300">Bridge Reserve ≥ 150%</div>
          <div className="text-[10px] text-gray-500 mt-1">Canonical assets always exceed 150% of synthetic in transit</div>
        </div>
        <div className="bg-violet-500/5 border border-violet-500/20 rounded-lg p-3">
          <div className="text-[10px] text-violet-400 font-bold uppercase tracking-wider mb-1">Condition 3</div>
          <div className="text-[11px] text-gray-300">Peg Deviation ≤ 2%</div>
          <div className="text-[10px] text-gray-500 mt-1">USDS/USDC exchange rate maintained within 2% via arb cycles</div>
        </div>
      </div>
    </div>
  );
}
