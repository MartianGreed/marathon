import React from 'react';
import type { Integration } from '../lib/types';

interface IntegrationCardProps {
  integration: Integration;
  onTest: () => void;
  onDisconnect: () => void;
  onViewStatus: () => void;
}

const integrationIcons: Record<string, string> = {
  github: '⚡',
  docker_hub: '🐳',
  github_container_registry: '📦',
  aws_ecr: '🏗️',
  aws_s3: '☁️',
  aws_lambda: '⚡',
  aws_ec2: '🖥️',
  aws_cloudwatch: '📊',
};

const statusIcons: Record<string, { icon: string; color: string }> = {
  connected: { icon: '✅', color: 'text-green-400' },
  disconnected: { icon: '❌', color: 'text-red-400' },
  connecting: { icon: '🔄', color: 'text-yellow-400' },
  error: { icon: '⚠️', color: 'text-red-400' },
  rate_limited: { icon: '⏳', color: 'text-yellow-400' },
};

export function IntegrationCard({ integration, onTest, onDisconnect, onViewStatus }: IntegrationCardProps) {
  const icon = integrationIcons[integration.integration_type] || '🔗';
  const statusInfo = statusIcons[integration.status] || { icon: '❓', color: 'text-gray-400' };

  const formatDate = (timestamp: number) => {
    return new Date(timestamp * 1000).toLocaleDateString();
  };

  const getIntegrationDisplayName = (type: string) => {
    const names: Record<string, string> = {
      github: 'GitHub',
      docker_hub: 'Docker Hub',
      github_container_registry: 'GitHub Container Registry',
      aws_ecr: 'AWS ECR',
      aws_s3: 'AWS S3',
      aws_lambda: 'AWS Lambda',
      aws_ec2: 'AWS EC2',
      aws_cloudwatch: 'AWS CloudWatch',
    };
    return names[type] || type;
  };

  return (
    <div className="bg-gray-800 rounded-lg border border-gray-700 p-6 hover:border-gray-600 transition-colors">
      {/* Header */}
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-center space-x-3">
          <div className="text-2xl">{icon}</div>
          <div>
            <h3 className="font-semibold text-lg">{integration.name}</h3>
            <p className="text-sm text-gray-400">{getIntegrationDisplayName(integration.integration_type)}</p>
          </div>
        </div>
        <div className={`flex items-center space-x-1 ${statusInfo.color}`}>
          <span className="text-lg">{statusInfo.icon}</span>
          <span className="text-sm font-medium capitalize">{integration.status.replace('_', ' ')}</span>
        </div>
      </div>

      {/* Status Info */}
      <div className="space-y-2 mb-4 text-sm text-gray-400">
        <div className="flex justify-between">
          <span>Status:</span>
          <span className={statusInfo.color}>{integration.status.replace('_', ' ')}</span>
        </div>
        <div className="flex justify-between">
          <span>Enabled:</span>
          <span>{integration.enabled ? '✅ Yes' : '❌ No'}</span>
        </div>
        <div className="flex justify-between">
          <span>Created:</span>
          <span>{formatDate(integration.created_at)}</span>
        </div>
        {integration.last_error && (
          <div className="mt-2 p-2 bg-red-500/10 border border-red-500/20 rounded text-red-400 text-xs">
            <strong>Last Error:</strong> {integration.last_error}
          </div>
        )}
      </div>

      {/* Actions */}
      <div className="flex space-x-2">
        <button
          onClick={onTest}
          className="flex-1 px-3 py-2 bg-blue-600 hover:bg-blue-700 rounded transition-colors text-sm font-medium"
        >
          🔍 Test
        </button>
        <button
          onClick={onViewStatus}
          className="flex-1 px-3 py-2 bg-gray-700 hover:bg-gray-600 rounded transition-colors text-sm font-medium"
        >
          📊 Status
        </button>
        <button
          onClick={onDisconnect}
          className="px-3 py-2 bg-red-600 hover:bg-red-700 rounded transition-colors text-sm font-medium"
        >
          🗑️
        </button>
      </div>

      {/* Quick Actions */}
      {integration.status === 'connected' && (
        <div className="mt-4 pt-4 border-t border-gray-700">
          <div className="text-sm text-gray-400 mb-2">Quick Actions:</div>
          <div className="flex space-x-2">
            {integration.integration_type === 'github' && (
              <>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  📋 Clone Repo
                </button>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  🔀 Create PR
                </button>
              </>
            )}
            {integration.integration_type === 'docker_hub' && (
              <>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  🔨 Build Image
                </button>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  📤 Push Image
                </button>
              </>
            )}
            {integration.integration_type === 'aws_s3' && (
              <>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  📁 List Buckets
                </button>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  📤 Upload File
                </button>
              </>
            )}
            {integration.integration_type === 'aws_lambda' && (
              <>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  🚀 Deploy Function
                </button>
                <button className="px-2 py-1 bg-gray-700 hover:bg-gray-600 rounded text-xs">
                  ⚡ Invoke
                </button>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}