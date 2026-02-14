import React, { useState } from 'react';
import { connectIntegration } from '../lib/api';
import type { IntegrationType } from '../lib/types';

interface IntegrationSetupModalProps {
  isOpen: boolean;
  integrationType?: IntegrationType;
  onClose: () => void;
  onComplete: () => void;
}

interface CredentialField {
  name: string;
  label: string;
  type: 'text' | 'password' | 'select';
  required: boolean;
  placeholder?: string;
  options?: string[];
  defaultValue?: string;
  helpText?: string;
}

const integrationConfigs: Record<IntegrationType, {
  name: string;
  icon: string;
  description: string;
  credentials: CredentialField[];
  settings: CredentialField[];
  helpUrl?: string;
}> = {
  github: {
    name: 'GitHub',
    icon: '⚡',
    description: 'Connect to GitHub for repository management, PR automation, and issue tracking.',
    credentials: [
      {
        name: 'token',
        label: 'Personal Access Token',
        type: 'password',
        required: true,
        placeholder: 'ghp_xxxxxxxxxxxxxxxxxxxx',
        helpText: 'Create a token at: Settings → Developer settings → Personal access tokens'
      }
    ],
    settings: [],
    helpUrl: 'https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token'
  },
  docker_hub: {
    name: 'Docker Hub',
    icon: '🐳',
    description: 'Connect to Docker Hub for container image management and publishing.',
    credentials: [
      {
        name: 'username',
        label: 'Username',
        type: 'text',
        required: true,
        placeholder: 'your-username'
      },
      {
        name: 'password',
        label: 'Password or Access Token',
        type: 'password',
        required: true,
        placeholder: 'your-password-or-token',
        helpText: 'Use an access token instead of password for better security'
      }
    ],
    settings: [],
    helpUrl: 'https://docs.docker.com/docker-hub/access-tokens/'
  },
  github_container_registry: {
    name: 'GitHub Container Registry',
    icon: '📦',
    description: 'Connect to GitHub Container Registry (ghcr.io) for container image hosting.',
    credentials: [
      {
        name: 'token',
        label: 'Personal Access Token',
        type: 'password',
        required: true,
        placeholder: 'ghp_xxxxxxxxxxxxxxxxxxxx',
        helpText: 'Token needs "read:packages" and "write:packages" scopes'
      }
    ],
    settings: [],
    helpUrl: 'https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry'
  },
  aws_ecr: {
    name: 'AWS ECR',
    icon: '🏗️',
    description: 'Connect to AWS Elastic Container Registry for Docker image storage.',
    credentials: [
      {
        name: 'access_key_id',
        label: 'Access Key ID',
        type: 'text',
        required: true,
        placeholder: 'AKIAIOSFODNN7EXAMPLE'
      },
      {
        name: 'secret_access_key',
        label: 'Secret Access Key',
        type: 'password',
        required: true,
        placeholder: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      },
      {
        name: 'region',
        label: 'Region',
        type: 'select',
        required: true,
        defaultValue: 'us-east-1',
        options: ['us-east-1', 'us-west-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'ap-southeast-1']
      }
    ],
    settings: [],
    helpUrl: 'https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html'
  },
  aws_s3: {
    name: 'AWS S3',
    icon: '☁️',
    description: 'Connect to AWS S3 for file storage, backups, and artifact management.',
    credentials: [
      {
        name: 'access_key_id',
        label: 'Access Key ID',
        type: 'text',
        required: true,
        placeholder: 'AKIAIOSFODNN7EXAMPLE'
      },
      {
        name: 'secret_access_key',
        label: 'Secret Access Key',
        type: 'password',
        required: true,
        placeholder: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      },
      {
        name: 'region',
        label: 'Region',
        type: 'select',
        required: true,
        defaultValue: 'us-east-1',
        options: ['us-east-1', 'us-west-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'ap-southeast-1']
      }
    ],
    settings: [],
    helpUrl: 'https://docs.aws.amazon.com/s3/latest/userguide/setting-up-s3.html'
  },
  aws_lambda: {
    name: 'AWS Lambda',
    icon: '⚡',
    description: 'Connect to AWS Lambda for serverless function deployment and management.',
    credentials: [
      {
        name: 'access_key_id',
        label: 'Access Key ID',
        type: 'text',
        required: true,
        placeholder: 'AKIAIOSFODNN7EXAMPLE'
      },
      {
        name: 'secret_access_key',
        label: 'Secret Access Key',
        type: 'password',
        required: true,
        placeholder: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      },
      {
        name: 'region',
        label: 'Region',
        type: 'select',
        required: true,
        defaultValue: 'us-east-1',
        options: ['us-east-1', 'us-west-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'ap-southeast-1']
      }
    ],
    settings: [],
    helpUrl: 'https://docs.aws.amazon.com/lambda/latest/dg/getting-started.html'
  },
  aws_ec2: {
    name: 'AWS EC2',
    icon: '🖥️',
    description: 'Connect to AWS EC2 for virtual server management and deployment.',
    credentials: [
      {
        name: 'access_key_id',
        label: 'Access Key ID',
        type: 'text',
        required: true,
        placeholder: 'AKIAIOSFODNN7EXAMPLE'
      },
      {
        name: 'secret_access_key',
        label: 'Secret Access Key',
        type: 'password',
        required: true,
        placeholder: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      },
      {
        name: 'region',
        label: 'Region',
        type: 'select',
        required: true,
        defaultValue: 'us-east-1',
        options: ['us-east-1', 'us-west-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'ap-southeast-1']
      }
    ],
    settings: [],
    helpUrl: 'https://docs.aws.amazon.com/ec2/latest/userguide/get-set-up-for-amazon-ec2.html'
  },
  aws_cloudwatch: {
    name: 'AWS CloudWatch',
    icon: '📊',
    description: 'Connect to AWS CloudWatch for monitoring, logging, and metrics collection.',
    credentials: [
      {
        name: 'access_key_id',
        label: 'Access Key ID',
        type: 'text',
        required: true,
        placeholder: 'AKIAIOSFODNN7EXAMPLE'
      },
      {
        name: 'secret_access_key',
        label: 'Secret Access Key',
        type: 'password',
        required: true,
        placeholder: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
      },
      {
        name: 'region',
        label: 'Region',
        type: 'select',
        required: true,
        defaultValue: 'us-east-1',
        options: ['us-east-1', 'us-west-1', 'us-west-2', 'eu-west-1', 'eu-central-1', 'ap-southeast-1']
      }
    ],
    settings: [],
    helpUrl: 'https://docs.aws.amazon.com/cloudwatch/latest/monitoring/GettingSetup.html'
  },
};

export function IntegrationSetupModal({ isOpen, integrationType, onClose, onComplete }: IntegrationSetupModalProps) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [formData, setFormData] = useState<Record<string, string>>({});

  if (!isOpen || !integrationType) return null;

  const config = integrationConfigs[integrationType];
  if (!config) return null;

  const handleInputChange = (name: string, value: string) => {
    setFormData(prev => ({ ...prev, [name]: value }));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);

    try {
      // Validate required fields
      const requiredFields = [...config.credentials, ...config.settings].filter(field => field.required);
      for (const field of requiredFields) {
        if (!formData[field.name]?.trim()) {
          throw new Error(`${field.label} is required`);
        }
      }

      // Separate credentials and settings
      const credentials: Array<{ key: string; value: string }> = [];
      const settings: Array<{ key: string; value: string }> = [];

      config.credentials.forEach(field => {
        const value = formData[field.name] || field.defaultValue || '';
        if (value) {
          credentials.push({ key: field.name, value });
        }
      });

      config.settings.forEach(field => {
        const value = formData[field.name] || field.defaultValue || '';
        if (value) {
          settings.push({ key: field.name, value });
        }
      });

      const integrationName = formData.name || `${config.name} Integration`;

      await connectIntegration({
        integration_type: integrationType,
        name: integrationName,
        credentials,
        settings,
      });

      onComplete();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to setup integration');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-gray-800 rounded-lg border border-gray-700 max-w-2xl w-full max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-gray-700">
          <div className="flex items-center space-x-3">
            <div className="text-2xl">{config.icon}</div>
            <div>
              <h2 className="text-xl font-bold">Setup {config.name}</h2>
              <p className="text-sm text-gray-400">{config.description}</p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-white transition-colors"
          >
            ✕
          </button>
        </div>

        {/* Form */}
        <form onSubmit={handleSubmit} className="p-6 space-y-6">
          {error && (
            <div className="p-4 bg-red-500/10 border border-red-500 rounded-lg">
              <p className="text-red-400">⚠️ {error}</p>
            </div>
          )}

          {/* Integration Name */}
          <div>
            <label className="block text-sm font-medium mb-2">Integration Name</label>
            <input
              type="text"
              value={formData.name || ''}
              onChange={(e) => handleInputChange('name', e.target.value)}
              placeholder={`My ${config.name} Integration`}
              className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:outline-none focus:border-blue-500"
            />
          </div>

          {/* Credentials */}
          {config.credentials.length > 0 && (
            <div>
              <h3 className="text-lg font-semibold mb-4 flex items-center">
                🔐 Credentials
                {config.helpUrl && (
                  <a
                    href={config.helpUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="ml-2 text-blue-400 hover:text-blue-300 text-sm"
                  >
                    📖 Help
                  </a>
                )}
              </h3>
              <div className="space-y-4">
                {config.credentials.map((field) => (
                  <div key={field.name}>
                    <label className="block text-sm font-medium mb-2">
                      {field.label}
                      {field.required && <span className="text-red-400 ml-1">*</span>}
                    </label>
                    {field.type === 'select' ? (
                      <select
                        value={formData[field.name] || field.defaultValue || ''}
                        onChange={(e) => handleInputChange(field.name, e.target.value)}
                        required={field.required}
                        className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:outline-none focus:border-blue-500"
                      >
                        {field.options?.map((option) => (
                          <option key={option} value={option}>
                            {option}
                          </option>
                        ))}
                      </select>
                    ) : (
                      <input
                        type={field.type}
                        value={formData[field.name] || ''}
                        onChange={(e) => handleInputChange(field.name, e.target.value)}
                        placeholder={field.placeholder}
                        required={field.required}
                        className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:outline-none focus:border-blue-500"
                      />
                    )}
                    {field.helpText && (
                      <p className="text-xs text-gray-400 mt-1">{field.helpText}</p>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Settings */}
          {config.settings.length > 0 && (
            <div>
              <h3 className="text-lg font-semibold mb-4">⚙️ Settings</h3>
              <div className="space-y-4">
                {config.settings.map((field) => (
                  <div key={field.name}>
                    <label className="block text-sm font-medium mb-2">
                      {field.label}
                      {field.required && <span className="text-red-400 ml-1">*</span>}
                    </label>
                    {field.type === 'select' ? (
                      <select
                        value={formData[field.name] || field.defaultValue || ''}
                        onChange={(e) => handleInputChange(field.name, e.target.value)}
                        required={field.required}
                        className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:outline-none focus:border-blue-500"
                      >
                        {field.options?.map((option) => (
                          <option key={option} value={option}>
                            {option}
                          </option>
                        ))}
                      </select>
                    ) : (
                      <input
                        type={field.type}
                        value={formData[field.name] || ''}
                        onChange={(e) => handleInputChange(field.name, e.target.value)}
                        placeholder={field.placeholder}
                        required={field.required}
                        className="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:outline-none focus:border-blue-500"
                      />
                    )}
                    {field.helpText && (
                      <p className="text-xs text-gray-400 mt-1">{field.helpText}</p>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Actions */}
          <div className="flex space-x-4 pt-6 border-t border-gray-700">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 bg-gray-700 hover:bg-gray-600 rounded-lg transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={loading}
              className="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed rounded-lg transition-colors"
            >
              {loading ? '⏳ Connecting...' : '🔗 Connect'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}