import { LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend } from 'recharts';
import { TrendingUp } from 'lucide-react';
import type { PriceHistory } from '../types';

interface Props {
  priceHistory: PriceHistory[];
}

export function PriceChart({ priceHistory }: Props) {
  const data = priceHistory.map((p, i) => ({
    index: i,
    external: p.external,
    internal: p.internal,
    spread: p.external - p.internal,
  }));

  return (
    <div className="bg-gray-900/50 rounded-xl border border-gray-800 p-5">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-gray-200 flex items-center gap-2">
          <TrendingUp size={16} className="text-cyan-400" />
          ETH Price: External vs Internal
        </h3>
        <div className="flex items-center gap-3 text-[10px]">
          <div className="flex items-center gap-1">
            <div className="w-3 h-0.5 bg-cyan-400 rounded" />
            <span className="text-gray-400">External (Base)</span>
          </div>
          <div className="flex items-center gap-1">
            <div className="w-3 h-0.5 bg-violet-400 rounded" />
            <span className="text-gray-400">Internal (Fork)</span>
          </div>
        </div>
      </div>

      <div className="h-64">
        {data.length < 2 ? (
          <div className="h-full flex items-center justify-center text-gray-500 text-xs">
            Collecting price data...
          </div>
        ) : (
          <ResponsiveContainer width="100%" height="100%">
            <LineChart data={data}>
              <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" />
              <XAxis dataKey="index" hide />
              <YAxis
                domain={['auto', 'auto']}
                tick={{ fill: '#6b7280', fontSize: 10 }}
                axisLine={{ stroke: '#374151' }}
                tickLine={false}
              />
              <Tooltip
                contentStyle={{
                  backgroundColor: '#111827',
                  border: '1px solid #374151',
                  borderRadius: '8px',
                  fontSize: '11px',
                }}
                labelStyle={{ color: '#9ca3af' }}
                formatter={(value: number) => [`$${value.toFixed(2)}`, '']}
              />
              <Line
                type="monotone"
                dataKey="external"
                stroke="#22d3ee"
                strokeWidth={2}
                dot={false}
                name="External"
              />
              <Line
                type="monotone"
                dataKey="internal"
                stroke="#a78bfa"
                strokeWidth={2}
                dot={false}
                name="Internal"
              />
            </LineChart>
          </ResponsiveContainer>
        )}
      </div>
    </div>
  );
}
