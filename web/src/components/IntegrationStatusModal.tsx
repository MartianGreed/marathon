import React, { useState, useEffect } from 'react';
import { getIntegrationStatus } from '../lib/api';
import type { Integration, IntegrationStatusDetails } from '../lib/types';

interface IntegrationStatusModalProps {
  isOpen: boolean;
  integration?: Integration;
  onClose: () => void;
}

export function IntegrationStatusModal({ isOpen, integration, onClose }: IntegrationStatusModalProps) {
  const [statusDetails, setStatusDetails] = useState<IntegrationStatusDetails | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (isOpen && integration) {
      loadStatusDetails();
    }
  }, [isOpen, integration]);

  const loadStatusDetails = async () => {
    if (!integration) return;

    setLoading(true);
    setError(null);

    try {
      const details = await getIntegrationStatus(integration.id);
      setStatusDetails(details);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load status details');
    } finally {
      setLoading(false);
    }
  };

  if (!isOpen || !integration) return null;

  const formatDate = (timestamp: number) => {
    return new Date(timestamp * 1000).toLocaleString();
  };

  const formatTimeFromNow = (timestamp: number) => {
    const now = Date.now() / 1000;
    const diff = timestamp - now;
    
    if (diff < 0) return 'Expired';
    
    const minutes = Math.floor(diff / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);
    
    if (days > 0) return `${days}d ${hours % 24}h`;
    if (hours > 0) return `${hours}h ${minutes % 60}m`;
    return `${minutes}m`;
  };

  const getIntegrationIcon = (type: string) => {
    const icons: Record<string, string> = {
      github: '⚡',
      docker_hub: '🐳',
      github_container_registry: '📦',
      aws_ecr: '🏗️',
      aws_s3: '☁️',
      aws_lambda: '⚡',
      aws_ec2: '🖥️',
      aws_cloudwatch: '📊',
    };
    return icons[type] || '🔗';
  };

  const getStatusIcon = (status: string) => {
    const icons: Record<string, { icon: string; color: string }> = {
      connected: { icon: '✅', color: 'text-green-400' },
      disconnected: { icon: '❌', color: 'text-red-400' },
      connecting: { icon: '🔄', color: 'text-yellow-400' },
      error: { icon: '⚠️', color: 'text-red-400' },
      rate_limited: { icon: '⏳', color: 'text-yellow-400' },
    };
    return icons[status] || { icon: '❓', color: 'text-gray-400' };
  };

  const statusIcon = getStatusIcon(integration.status);

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-gray-800 rounded-lg border border-gray-700 max-w-2xl w-full max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-gray-700">
          <div className="flex items-center space-x-3">
            <div className="text-2xl">{getIntegrationIcon(integration.integration_type)}</div>
            <div>
              <h2 className="text-xl font-bold">{integration.name}</h2>
              <p className="text-sm text-gray-400">{integration.integration_type.replace('_', ' ')}</p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-white transition-colors"
          >
            ✕
          </button>
        </div>

        {/* Content */}
        <div className="p-6">
          {loading && (
            <div className="text-center py-8">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-500 mx-auto"></div>
              <p className="mt-2 text-gray-400">Loading status details...</p>
            </div>
          )}

          {error && (
            <div className="p-4 bg-red-500/10 border border-red-500 rounded-lg mb-6">
              <p className="text-red-400">⚠️ {error}</p>
            </div>
          )}

          {!loading && !error && (
            <div className="space-y-6">
              {/* Current Status */}
              <div>
                <h3 className="text-lg font-semibold mb-4">📊 Current Status</h3>
                <div className="bg-gray-700 rounded-lg p-4">
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <div className="text-sm text-gray-400">Status</div>
                      <div className={`flex items-center space-x-2 ${statusIcon.color} font-medium`}>
                        <span>{statusIcon.icon}</span>
                        <span>{integration.status.replace('_', ' ')}</span>
                      </div>
                    </div>
                    <div>
                      <div className="text-sm text-gray-400">Enabled</div>
                      <div className="font-medium">
                        {integration.enabled ? '✅ Yes' : '❌ No'}
                      </div>
                    </div>
                    <div>
                      <div className="text-sm text-gray-400">Created</div>
                      <div className="font-medium">{formatDate(integration.created_at)}</div>
                    </div>
                    <div>
                      <div className="text-sm text-gray-400">Last Updated</div>
                      <div className="font-medium">{formatDate(integration.updated_at)}</div>
                    </div>
                  </div>
                </div>
              </div>

              {/* Rate Limiting Info */}
              {statusDetails?.rate_limit_remaining !== undefined && (
                <div>
                  <h3 className="text-lg font-semibold mb-4">⏱️ Rate Limiting</h3>
                  <div className="bg-gray-700 rounded-lg p-4">
                    <div className="grid grid-cols-2 gap-4">
                      <div>
                        <div className="text-sm text-gray-400">Remaining Requests</div>
                        <div className="font-medium text-lg">
                          {statusDetails.rate_limit_remaining.toLocaleString()}
                        </div>
                      </div>
                      {statusDetails.rate_limit_reset_at && (
                        <div>
                          <div className="text-sm text-gray-400">Resets In</div>
                          <div className="font-medium text-lg">
                            {formatTimeFromNow(statusDetails.rate_limit_reset_at)}
                          </div>
                        </div>
                      )}
                    </div>
                    
                    {/* Rate limit visualization */}
                    <div className="mt-4">
                      <div className="flex justify-between text-sm text-gray-400 mb-1">
                        <span>Usage</span>
                        <span>{statusDetails.rate_limit_remaining} remaining</span>
                      </div>
                      <div className="w-full bg-gray-600 rounded-full h-2">
                        <div 
                          className={`h-2 rounded-full transition-all duration-500 ${
                            statusDetails.rate_limit_remaining > 1000 ? 'bg-green-500' :
                            statusDetails.rate_limit_remaining > 100 ? 'bg-yellow-500' : 'bg-red-500'
                          }`}
                          style={{ 
                            width: `${Math.min(100, (statusDetails.rate_limit_remaining / 5000) * 100)}%` 
                          }}
                        ></div>
                      </div>
                    </div>
                  </div>
                </div>
              )}

              {/* Error Information */}
              {integration.last_error && (
                <div>
                  <h3 className="text-lg font-semibold mb-4">⚠️ Last Error</h3>
                  <div className="bg-red-500/10 border border-red-500/20 rounded-lg p-4">
                    <div className="text-red-400 font-mono text-sm">
                      {integration.last_error}
                    </div>
                  </div>
                </div>
              )}

              {/* Connection Health */}
              <div>
                <h3 className="text-lg font-semibold mb-4">🔍 Connection Health</h3>
                <div className="space-y-3">
                  <div className="flex items-center justify-between p-3 bg-gray-700 rounded-lg">
                    <div className="flex items-center space-x-2">
                      <span className={integration.status === 'connected' ? 'text-green-400' : 'text-red-400'}>
                        {integration.status === 'connected' ? '✅' : '❌'}
                      </span>
                      <span>API Connection</span>
                    </div>
                    <span className="text-sm text-gray-400 capitalize">
                      {integration.status.replace('_', ' ')}
                    </span>
                  </div>
                  
                  <div className="flex items-center justify-between p-3 bg-gray-700 rounded-lg">
                    <div className="flex items-center space-x-2">
                      <span className={integration.enabled ? 'text-green-400' : 'text-yellow-400'}>
                        {integration.enabled ? '✅' : '⏳'}
                      </span>
                      <span>Service Enabled</span>
                    </div>
                    <span className="text-sm text-gray-400">
                      {integration.enabled ? 'Active' : 'Disabled'}
                    </span>
                  </div>

                  <div className="flex items-center justify-between p-3 bg-gray-700 rounded-lg">
                    <div className="flex items-center space-x-2">
                      <span className={statusDetails?.rate_limit_remaining && statusDetails.rate_limit_remaining > 100 ? 'text-green-400' : 'text-yellow-400'}>
                        {statusDetails?.rate_limit_remaining && statusDetails.rate_limit_remaining > 100 ? '✅' : '⏳'}
                      </span>
                      <span>Rate Limit Status</span>
                    </div>
                    <span className="text-sm text-gray-400">
                      {statusDetails?.rate_limit_remaining && statusDetails.rate_limit_remaining > 100 ? 'Healthy' : 'Limited'}
                    </span>
                  </div>
                </div>
              </div>

              {/* Integration Capabilities */}
              <div>
                <h3 className="text-lg font-semibold mb-4">🛠️ Available Features</h3>
                <div className="grid grid-cols-2 gap-2">
                  {getIntegrationCapabilities(integration.integration_type).map((capability, index) => (
                    <div key={index} className="flex items-center space-x-2 p-2 bg-gray-700 rounded">
                      <span className="text-green-400">✓</span>
                      <span className="text-sm">{capability}</span>
                    </div>
                  ))}
                </div>
              </div>

              {/* Actions */}
              <div className="flex space-x-4 pt-6 border-t border-gray-700">
                <button
                  onClick={loadStatusDetails}
                  disabled={loading}
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 rounded-lg transition-colors"
                >
                  🔄 Refresh Status
                </button>
                <button
                  onClick={onClose}
                  className="px-4 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
                >
                  Close
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function getIntegrationCapabilities(integrationType: string): string[] {
  const capabilities: Record<string, string[]> = {
    github: [
      'Repository Cloning',
      'Pull Request Management',
      'Issue Tracking',
      'Branch Operations',
      'Webhook Support',
      'Actions Integration'
    ],
    docker_hub: [
      'Image Building',
      'Registry Push/Pull',
      'Multi-stage Builds',
      'Tag Management',
      'Repository Management',
      'Automated Builds'
    ],
    github_container_registry: [
      'Container Hosting',
      'Package Management',
      'Access Control',
      'Multi-arch Support',
      'Version Tagging',
      'GitHub Integration'
    ],
    aws_ecr: [
      'Private Registries',
      'Image Scanning',
      'Lifecycle Policies',
      'Cross-region Replication',
      'IAM Integration',
      'Docker API Compatibility'
    ],
    aws_s3: [
      'File Storage',
      'Bucket Management',
      'Object Lifecycle',
      'Cross-region Replication',
      'Event Notifications',
      'Static Web Hosting'
    ],
    aws_lambda: [
      'Function Deployment',
      'Event Triggers',
      'Runtime Management',
      'Environment Variables',
      'VPC Configuration',
      'Monitoring Integration'
    ],
    aws_ec2: [
      'Instance Management',
      'Auto Scaling',
      'Security Groups',
      'Load Balancing',
      'Storage Management',
      'Network Configuration'
    ],
    aws_cloudwatch: [
      'Metrics Collection',
      'Log Aggregation',
      'Alarms & Notifications',
      'Dashboard Creation',
      'Custom Metrics',
      'Event Rules'
    ],
  };

  return capabilities[integrationType] || ['Basic Integration'];
}