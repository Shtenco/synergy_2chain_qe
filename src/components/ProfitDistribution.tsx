import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip } from 'recharts';
import { Wallet } from 'lucide-react';
import type { ProfitDistribution } from '../types';

interface Props {
  distribution: ProfitDistribution;
}

export function ProfitDistribution({ distribution }: Props) {
  const data = [
    { name: 'Owner (40%)', value: distribution.owner, color: '#f59e0b' },
    { name: 'Bridge Reserve (30%)', value: distribution.bridgeReserve, color: '#22d3ee' },
    { name: 'Insurance Fund (20%)', value: distribution.insuranceFund, color: '#a78bfa' },
    { name: 'Rebase Fund (10%)', value: distribution.rebalanceFund, color: '#34d399' },
  ];

  const total = distribution.totalDistributed;

  return (
    <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-gray-200 flex items-center gap-2">
          <Wallet size={16} className="text-amber-400" />
          Profit Distribution
        </h3>
        <span className="text-xs text-gray-500">
          Total: <span className="text-emerald-400 font-mono font-bold">${total.toLocaleString('en-US', { maximumFractionDigits: 0 })}</span>
        </span>
      </div>

      <div className="flex items-center gap-4">
        <div className="w-32 h-32 flex-shrink-0">
          {total > 0 ? (
            <ResponsiveContainer width="100%" height="100%">
              <PieChart>
                <Pie
                  data={data}
                  cx="50%"
                  cy="50%"
                  innerRadius={30}
                  outerRadius={55}
                  paddingAngle={2}
                  dataKey="value"
                >
                  {data.map((entry, index) => (
                    <Cell key={`cell-${index}`} fill={entry.color} />
                  ))}
                </Pie>
                <Tooltip
                  contentStyle={{
                    backgroundColor: '#111827',
                    border: '1px solid #374151',
                    borderRadius: '8px',
                    fontSize: '11px',
                  }}
                  formatter={(value: number) => [`$${value.toFixed(2)}`, '']}
                />
              </PieChart>
            </ResponsiveContainer>
          ) : (
            <div className="w-full h-full flex items-center justify-center">
              <div className="w-16 h-16 rounded-full border-2 border-dashed border-gray-700 flex items-center justify-center">
                <span className="text-[10px] text-gray-500">No data</span>
              </div>
            </div>
          )}
        </div>

        <div className="flex-1 space-y-2">
          {data.map((item, i) => (
            <div key={i} className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <div className="w-2.5 h-2.5 rounded-full" style={{ backgroundColor: item.color }} />
                <span className="text-xs text-gray-400">{item.name}</span>
              </div>
              <span className="text-xs font-mono text-white">${item.value.toLocaleString('en-US', { maximumFractionDigits: 0 })}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
