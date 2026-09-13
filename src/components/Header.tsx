import { Play, Pause, RotateCcw, Zap, Activity, Layers, ArrowLeftRight, FileCode } from 'lucide-react';

type Tab = 'dashboard' | 'bridge' | 'pool' | 'cycles' | 'contracts';

interface HeaderProps {
  activeTab: Tab;
  setActiveTab: (tab: Tab) => void;
  isRunning: boolean;
  toggleSimulation: () => void;
  speed: number;
  setSpeed: (speed: number) => void;
  resetSimulation: () => void;
}

const tabs: { id: Tab; label: string; icon: React.ReactNode }[] = [
  { id: 'dashboard', label: 'Dashboard', icon: <Activity size={16} /> },
  { id: 'bridge', label: 'Bridge & Oracle', icon: <ArrowLeftRight size={16} /> },
  { id: 'pool', label: 'Internal Pool & LP', icon: <Layers size={16} /> },
  { id: 'cycles', label: 'Arb Cycles', icon: <Zap size={16} /> },
  { id: 'contracts', label: 'Contracts', icon: <FileCode size={16} /> },
];

export function Header({ activeTab, setActiveTab, isRunning, toggleSimulation, speed, setSpeed, resetSimulation }: HeaderProps) {
  return (
    <header className="bg-gray-900/80 backdrop-blur-xl border-b border-gray-800 sticky top-0 z-50">
      <div className="max-w-[1600px] mx-auto px-4">
        <div className="flex items-center justify-between h-16">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-emerald-400 to-cyan-500 flex items-center justify-center">
              <Zap size={18} className="text-gray-900" />
            </div>
            <div>
              <h1 className="text-sm font-bold tracking-tight">Perpetual Arbitrage Engine</h1>
              <p className="text-[10px] text-gray-500 tracking-wider uppercase">Base Mainnet Fork • Live Simulation</p>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <div className="flex items-center gap-1 bg-gray-800 rounded-lg p-1">
              <button
                onClick={() => setSpeed(3000)}
                className={`px-2 py-1 rounded text-xs transition ${speed === 3000 ? 'bg-gray-700 text-white' : 'text-gray-400 hover:text-white'}`}
              >
                0.5x
              </button>
              <button
                onClick={() => setSpeed(2000)}
                className={`px-2 py-1 rounded text-xs transition ${speed === 2000 ? 'bg-gray-700 text-white' : 'text-gray-400 hover:text-white'}`}
              >
                1x
              </button>
              <button
                onClick={() => setSpeed(1000)}
                className={`px-2 py-1 rounded text-xs transition ${speed === 1000 ? 'bg-gray-700 text-white' : 'text-gray-400 hover:text-white'}`}
              >
                2x
              </button>
              <button
                onClick={() => setSpeed(500)}
                className={`px-2 py-1 rounded text-xs transition ${speed === 500 ? 'bg-gray-700 text-white' : 'text-gray-400 hover:text-white'}`}
              >
                4x
              </button>
            </div>

            <button
              onClick={toggleSimulation}
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium transition ${
                isRunning
                  ? 'bg-amber-500/20 text-amber-400 hover:bg-amber-500/30'
                  : 'bg-emerald-500/20 text-emerald-400 hover:bg-emerald-500/30'
              }`}
            >
              {isRunning ? <Pause size={14} /> : <Play size={14} />}
              {isRunning ? 'Pause' : 'Start'}
            </button>

            <button
              onClick={resetSimulation}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium bg-gray-800 text-gray-400 hover:text-white transition"
            >
              <RotateCcw size={14} />
              Reset
            </button>
          </div>
        </div>

        <nav className="flex gap-1 -mb-px overflow-x-auto">
          {tabs.map(tab => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex items-center gap-1.5 px-4 py-2.5 text-xs font-medium border-b-2 transition whitespace-nowrap ${
                activeTab === tab.id
                  ? 'border-emerald-400 text-emerald-400'
                  : 'border-transparent text-gray-500 hover:text-gray-300'
              }`}
            >
              {tab.icon}
              {tab.label}
            </button>
          ))}
        </nav>
      </div>
    </header>
  );
}
