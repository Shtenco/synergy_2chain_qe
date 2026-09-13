import { useState } from 'react';
import { useSimulation } from './hooks/useSimulation';
import { Header } from './components/Header';
import { SystemOverview } from './components/SystemOverview';
import { BridgeMonitor } from './components/BridgeMonitor';
import { PoolMonitor } from './components/PoolMonitor';
import { CyclesLog } from './components/CyclesLog';
import { LPPositions } from './components/LPPositions';
import { PriceChart } from './components/PriceChart';
import { ProfitDistribution } from './components/ProfitDistribution';
import { OracleStatus } from './components/OracleStatus';
import { ArchitectureDiagram } from './components/ArchitectureDiagram';
import { ContractExplorer } from './components/ContractExplorer';

type Tab = 'dashboard' | 'bridge' | 'pool' | 'cycles' | 'contracts';

export default function App() {
  const [activeTab, setActiveTab] = useState<Tab>('dashboard');
  const simulation = useSimulation();

  return (
    <div className="min-h-screen bg-gray-950 text-gray-100">
      <Header
        activeTab={activeTab}
        setActiveTab={setActiveTab}
        isRunning={simulation.isRunning}
        toggleSimulation={simulation.toggleSimulation}
        speed={simulation.speed}
        setSpeed={simulation.setSpeed}
        resetSimulation={simulation.resetSimulation}
      />
      
      <main className="max-w-[1600px] mx-auto px-4 py-6">
        {activeTab === 'dashboard' && (
          <div className="space-y-6">
            <SystemOverview metrics={simulation.metrics} oracle={simulation.oracle} bridge={simulation.bridge} />
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <PriceChart priceHistory={simulation.priceHistory} />
              <OracleStatus oracle={simulation.oracle} />
            </div>
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <ProfitDistribution distribution={simulation.distribution} />
              <BridgeMonitor bridge={simulation.bridge} compact />
            </div>
            <ArchitectureDiagram />
          </div>
        )}

        {activeTab === 'bridge' && (
          <div className="space-y-6">
            <BridgeMonitor bridge={simulation.bridge} />
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
              <OracleStatus oracle={simulation.oracle} />
              <ProfitDistribution distribution={simulation.distribution} />
            </div>
          </div>
        )}

        {activeTab === 'pool' && (
          <div className="space-y-6">
            <PoolMonitor pool={simulation.pool} oracle={simulation.oracle} />
            <LPPositions positions={simulation.lpPositions} />
            <PriceChart priceHistory={simulation.priceHistory} />
          </div>
        )}

        {activeTab === 'cycles' && (
          <div className="space-y-6">
            <CyclesLog cycles={simulation.cycles} metrics={simulation.metrics} />
          </div>
        )}

        {activeTab === 'contracts' && (
          <ContractExplorer />
        )}
      </main>
    </div>
  );
}
