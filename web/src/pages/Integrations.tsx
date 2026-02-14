import React, { useState, useEffect } from 'react';
import { IntegrationCard } from '../components/IntegrationCard';
import { IntegrationSetupModal } from '../components/IntegrationSetupModal';
import { IntegrationStatusModal } from '../components/IntegrationStatusModal';
import { getIntegrations, testIntegration, disconnectIntegration } from '../lib/api';
import type { Integration, IntegrationType } from '../lib/types';

export function IntegrationsPage() {
  const [integrations, setIntegrations] = useState<Integration[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [setupModal, setSetupModal] = useState<{
    isOpen: boolean;
    integrationType?: IntegrationType;
  }>({ isOpen: false });
  const [statusModal, setStatusModal] = useState<{
    isOpen: boolean;
    integration?: Integration;
  }>({ isOpen: false });

  useEffect(() => {
    loadIntegrations();
  }, []);

  const loadIntegrations = async () => {
    try {
      setLoading(true);
      const data = await getIntegrations();
      setIntegrations(data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load integrations');
    } finally {
      setLoading(false);
    }
  };

  const handleSetupComplete = () => {
    setSetupModal({ isOpen: false });
    loadIntegrations();
  };

  const handleTest = async (integrationId: string) => {
    try {
      const result = await testIntegration(integrationId);
      alert(`Test ${result.success ? 'passed' : 'failed'}: ${result.message}`);
      loadIntegrations(); // Refresh to update status
    } catch (err) {
      alert(`Test failed: ${err instanceof Error ? err.message : 'Unknown error'}`);
    }
  };

  const handleDisconnect = async (integrationId: string, integrationName: string) => {
    if (!confirm(`Are you sure you want to disconnect "${integrationName}"? This cannot be undone.`)) {
      return;
    }

    try {
      await disconnectIntegration(integrationId);
      loadIntegrations(); // Refresh the list
    } catch (err) {
      alert(`Failed to disconnect: ${err instanceof Error ? err.message : 'Unknown error'}`);
    }
  };

  const handleViewStatus = (integration: Integration) => {
    setStatusModal({ isOpen: true, integration });
  };

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="text-center">
          <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500 mx-auto"></div>
          <p className="mt-4 text-gray-600">Loading integrations...</p>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen" style={{ background: 'var(--bg-primary)', color: 'var(--text-primary)' }}>
      <div className="max-w-6xl mx-auto p-6">
        {/* Header */}
        <div className="mb-8">
          <h1 className="text-3xl font-bold mb-2">🔗 Integrations</h1>
          <p className="text-gray-400">Connect Marathon with your favorite development tools and cloud services.</p>
        </div>

        {error && (
          <div className="mb-6 p-4 bg-red-500/10 border border-red-500 rounded-lg">
            <p className="text-red-400">⚠️ {error}</p>
          </div>
        )}

        {/* Quick Setup Cards */}
        <div className="mb-8">
          <h2 className="text-xl font-semibold mb-4">🚀 Quick Setup</h2>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
            {[
              { type: 'github' as IntegrationType, name: 'GitHub', icon: '⚡', description: 'Repository management and PR automation' },
              { type: 'docker_hub' as IntegrationType, name: 'Docker Hub', icon: '🐳', description: 'Container image building and publishing' },
              { type: 'aws_s3' as IntegrationType, name: 'AWS S3', icon: '☁️', description: 'File storage and artifact management' },
              { type: 'aws_lambda' as IntegrationType, name: 'AWS Lambda', icon: '⚡', description: 'Serverless function deployment' },
            ].map((service) => (
              <button
                key={service.type}
                onClick={() => setSetupModal({ isOpen: true, integrationType: service.type })}
                className="p-4 bg-gray-800 hover:bg-gray-700 rounded-lg border border-gray-700 transition-colors text-left"
              >
                <div className="text-2xl mb-2">{service.icon}</div>
                <div className="font-semibold mb-1">{service.name}</div>
                <div className="text-sm text-gray-400">{service.description}</div>
              </button>
            ))}
          </div>
        </div>

        {/* Connected Integrations */}
        <div>
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-xl font-semibold">📋 Connected Services</h2>
            <button
              onClick={loadIntegrations}
              className="px-4 py-2 bg-blue-600 hover:bg-blue-700 rounded-lg transition-colors"
            >
              🔄 Refresh
            </button>
          </div>

          {integrations.length === 0 ? (
            <div className="text-center py-12 bg-gray-800 rounded-lg border border-gray-700">
              <div className="text-4xl mb-4">🔌</div>
              <h3 className="text-lg font-semibold mb-2">No integrations yet</h3>
              <p className="text-gray-400 mb-4">Get started by connecting your first service above.</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {integrations.map((integration) => (
                <IntegrationCard
                  key={integration.id}
                  integration={integration}
                  onTest={() => handleTest(integration.id)}
                  onDisconnect={() => handleDisconnect(integration.id, integration.name)}
                  onViewStatus={() => handleViewStatus(integration)}
                />
              ))}
            </div>
          )}
        </div>

        {/* Modals */}
        <IntegrationSetupModal
          isOpen={setupModal.isOpen}
          integrationType={setupModal.integrationType}
          onClose={() => setSetupModal({ isOpen: false })}
          onComplete={handleSetupComplete}
        />

        <IntegrationStatusModal
          isOpen={statusModal.isOpen}
          integration={statusModal.integration}
          onClose={() => setStatusModal({ isOpen: false })}
        />
      </div>
    </div>
  );
}