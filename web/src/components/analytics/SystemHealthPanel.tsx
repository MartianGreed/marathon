import React from 'react';
import type { SystemHealth } from '../../lib/analytics';
import { format } from 'date-fns';
import { 
  CheckCircleIcon, 
  ExclamationTriangleIcon, 
  XCircleIcon,
  ClockIcon,
  SignalIcon,
  QueueListIcon,
  LinkIcon
} from '@heroicons/react/24/outline';

interface SystemHealthPanelProps {
  data: SystemHealth;
  isLoading: boolean;
}

const SystemHealthPanel: React.FC<SystemHealthPanelProps> = ({ data, isLoading }) => {
  if (isLoading) {
    return (
      <div className="space-y-6">
        <h2 className="text-lg font-semibold text-gray-900">System Health</h2>
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <div className="animate-pulse">
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              {[1, 2, 3, 4].map((i) => (
                <div key={i} className="space-y-2">
                  <div className="h-4 bg-gray-200 rounded w-1/2"></div>
                  <div className="h-8 bg-gray-200 rounded w-3/4"></div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    );
  }

  const getHealthStatus = () => {
    const { uptime_percentage, error_rate, average_response_time_ms } = data;
    
    if (uptime_percentage >= 99.9 && error_rate <= 0.01 && average_response_time_ms <= 200) {
      return { status: 'excellent', color: 'green', icon: CheckCircleIcon };
    } else if (uptime_percentage >= 99.0 && error_rate <= 0.05 && average_response_time_ms <= 500) {
      return { status: 'good', color: 'yellow', icon: ExclamationTriangleIcon };
    } else {
      return { status: 'poor', color: 'red', icon: XCircleIcon };
    }
  };

  const healthStatus = getHealthStatus();
  const StatusIcon = healthStatus.icon;

  const formatUptime = (percentage: number) => `${(percentage * 100).toFixed(2)}%`;
  const formatResponseTime = (ms: number) => {
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(1)}s`;
  };
  const formatErrorRate = (rate: number) => `${(rate * 100).toFixed(3)}%`;

  const getStatusColor = (status: string) => {
    switch (status) {
      case 'excellent': return 'text-green-600 bg-green-100';
      case 'good': return 'text-yellow-600 bg-yellow-100';
      case 'poor': return 'text-red-600 bg-red-100';
      default: return 'text-gray-600 bg-gray-100';
    }
  };

  const getResponseTimeColor = (ms: number) => {
    if (ms <= 200) return 'text-green-600';
    if (ms <= 500) return 'text-yellow-600';
    return 'text-red-600';
  };

  const getErrorRateColor = (rate: number) => {
    if (rate <= 0.01) return 'text-green-600';
    if (rate <= 0.05) return 'text-yellow-600';
    return 'text-red-600';
  };

  const getUptimeColor = (percentage: number) => {
    if (percentage >= 0.999) return 'text-green-600';
    if (percentage >= 0.99) return 'text-yellow-600';
    return 'text-red-600';
  };

  return (
    <div className="space-y-6">
      <h2 className="text-lg font-semibold text-gray-900">System Health</h2>
      
      {/* Overall Health Status */}
      <div className="bg-white p-6 rounded-lg shadow-sm border">
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center space-x-3">
            <StatusIcon className={`h-8 w-8 text-${healthStatus.color}-500`} />
            <div>
              <h3 className="text-lg font-medium text-gray-900">System Status</h3>
              <span className={`inline-flex px-2 py-1 text-xs font-semibold rounded-full ${getStatusColor(healthStatus.status)}`}>
                {healthStatus.status.toUpperCase()}
              </span>
            </div>
          </div>
          <div className="text-right">
            <p className="text-sm text-gray-500">Last Updated</p>
            <p className="text-lg font-medium text-gray-900">
              {format(new Date(data.last_updated * 1000), 'HH:mm:ss')}
            </p>
          </div>
        </div>

        {/* Health Metrics Grid */}
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
          <div className="text-center">
            <div className="flex items-center justify-center mb-2">
              <ClockIcon className="h-5 w-5 text-gray-400 mr-2" />
              <span className="text-sm font-medium text-gray-500">Uptime</span>
            </div>
            <div className={`text-2xl font-bold ${getUptimeColor(data.uptime_percentage)}`}>
              {formatUptime(data.uptime_percentage)}
            </div>
            <div className="text-xs text-gray-400 mt-1">
              {data.uptime_percentage >= 0.999 ? 'Excellent' : 
               data.uptime_percentage >= 0.99 ? 'Good' : 'Poor'}
            </div>
          </div>

          <div className="text-center">
            <div className="flex items-center justify-center mb-2">
              <SignalIcon className="h-5 w-5 text-gray-400 mr-2" />
              <span className="text-sm font-medium text-gray-500">Response Time</span>
            </div>
            <div className={`text-2xl font-bold ${getResponseTimeColor(data.average_response_time_ms)}`}>
              {formatResponseTime(data.average_response_time_ms)}
            </div>
            <div className="text-xs text-gray-400 mt-1">
              {data.average_response_time_ms <= 200 ? 'Fast' : 
               data.average_response_time_ms <= 500 ? 'Normal' : 'Slow'}
            </div>
          </div>

          <div className="text-center">
            <div className="flex items-center justify-center mb-2">
              <ExclamationTriangleIcon className="h-5 w-5 text-gray-400 mr-2" />
              <span className="text-sm font-medium text-gray-500">Error Rate</span>
            </div>
            <div className={`text-2xl font-bold ${getErrorRateColor(data.error_rate)}`}>
              {formatErrorRate(data.error_rate)}
            </div>
            <div className="text-xs text-gray-400 mt-1">
              {data.error_rate <= 0.01 ? 'Low' : 
               data.error_rate <= 0.05 ? 'Medium' : 'High'}
            </div>
          </div>

          <div className="text-center">
            <div className="flex items-center justify-center mb-2">
              <LinkIcon className="h-5 w-5 text-gray-400 mr-2" />
              <span className="text-sm font-medium text-gray-500">Connections</span>
            </div>
            <div className="text-2xl font-bold text-blue-600">
              {data.active_connections.toLocaleString()}
            </div>
            <div className="text-xs text-gray-400 mt-1">Active</div>
          </div>
        </div>
      </div>

      {/* Detailed Metrics */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* System Performance */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Performance Metrics</h3>
          <div className="space-y-4">
            <div className="flex justify-between items-center">
              <span className="text-sm text-gray-600">Average Response Time</span>
              <div className="flex items-center space-x-2">
                <span className={`text-sm font-medium ${getResponseTimeColor(data.average_response_time_ms)}`}>
                  {formatResponseTime(data.average_response_time_ms)}
                </span>
                <div className="w-20 bg-gray-200 rounded-full h-2">
                  <div 
                    className={`h-2 rounded-full ${
                      data.average_response_time_ms <= 200 ? 'bg-green-500' :
                      data.average_response_time_ms <= 500 ? 'bg-yellow-500' : 'bg-red-500'
                    }`}
                    style={{ width: `${Math.min((data.average_response_time_ms / 1000) * 100, 100)}%` }}
                  ></div>
                </div>
              </div>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-sm text-gray-600">Error Rate</span>
              <div className="flex items-center space-x-2">
                <span className={`text-sm font-medium ${getErrorRateColor(data.error_rate)}`}>
                  {formatErrorRate(data.error_rate)}
                </span>
                <div className="w-20 bg-gray-200 rounded-full h-2">
                  <div 
                    className={`h-2 rounded-full ${
                      data.error_rate <= 0.01 ? 'bg-green-500' :
                      data.error_rate <= 0.05 ? 'bg-yellow-500' : 'bg-red-500'
                    }`}
                    style={{ width: `${Math.min(data.error_rate * 2000, 100)}%` }}
                  ></div>
                </div>
              </div>
            </div>

            <div className="flex justify-between items-center">
              <span className="text-sm text-gray-600">Queue Length</span>
              <div className="flex items-center space-x-2">
                <QueueListIcon className="h-4 w-4 text-gray-400" />
                <span className="text-sm font-medium text-gray-900">
                  {data.queue_length.toLocaleString()}
                </span>
              </div>
            </div>
          </div>
        </div>

        {/* System Status Indicators */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Status Indicators</h3>
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-2">
                <div className={`w-3 h-3 rounded-full ${
                  data.uptime_percentage >= 0.999 ? 'bg-green-500' :
                  data.uptime_percentage >= 0.99 ? 'bg-yellow-500' : 'bg-red-500'
                }`}></div>
                <span className="text-sm text-gray-600">System Health</span>
              </div>
              <span className="text-sm font-medium capitalize">{healthStatus.status}</span>
            </div>

            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-2">
                <div className={`w-3 h-3 rounded-full ${
                  data.active_connections > 0 ? 'bg-green-500 animate-pulse' : 'bg-gray-400'
                }`}></div>
                <span className="text-sm text-gray-600">API Endpoint</span>
              </div>
              <span className="text-sm font-medium">
                {data.active_connections > 0 ? 'Online' : 'Offline'}
              </span>
            </div>

            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-2">
                <div className={`w-3 h-3 rounded-full ${
                  data.queue_length < 100 ? 'bg-green-500' :
                  data.queue_length < 500 ? 'bg-yellow-500' : 'bg-red-500'
                }`}></div>
                <span className="text-sm text-gray-600">Queue Status</span>
              </div>
              <span className="text-sm font-medium">
                {data.queue_length < 100 ? 'Normal' :
                 data.queue_length < 500 ? 'Busy' : 'Overloaded'}
              </span>
            </div>

            <div className="flex items-center justify-between">
              <div className="flex items-center space-x-2">
                <div className="w-3 h-3 rounded-full bg-blue-500"></div>
                <span className="text-sm text-gray-600">Database</span>
              </div>
              <span className="text-sm font-medium">Connected</span>
            </div>
          </div>
        </div>
      </div>

      {/* Alerts and Notifications */}
      {(data.error_rate > 0.05 || data.average_response_time_ms > 500 || data.uptime_percentage < 0.99) && (
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">System Alerts</h3>
          <div className="space-y-3">
            {data.error_rate > 0.05 && (
              <div className="flex items-center p-3 bg-red-50 border border-red-200 rounded-md">
                <ExclamationTriangleIcon className="h-5 w-5 text-red-400 mr-3" />
                <div>
                  <p className="text-sm font-medium text-red-800">High Error Rate Detected</p>
                  <p className="text-sm text-red-700">
                    Current error rate is {formatErrorRate(data.error_rate)}, which exceeds the 5% threshold.
                  </p>
                </div>
              </div>
            )}
            
            {data.average_response_time_ms > 500 && (
              <div className="flex items-center p-3 bg-yellow-50 border border-yellow-200 rounded-md">
                <ClockIcon className="h-5 w-5 text-yellow-400 mr-3" />
                <div>
                  <p className="text-sm font-medium text-yellow-800">Slow Response Times</p>
                  <p className="text-sm text-yellow-700">
                    Average response time is {formatResponseTime(data.average_response_time_ms)}, consider performance optimization.
                  </p>
                </div>
              </div>
            )}

            {data.uptime_percentage < 0.99 && (
              <div className="flex items-center p-3 bg-red-50 border border-red-200 rounded-md">
                <XCircleIcon className="h-5 w-5 text-red-400 mr-3" />
                <div>
                  <p className="text-sm font-medium text-red-800">Low System Uptime</p>
                  <p className="text-sm text-red-700">
                    System uptime is {formatUptime(data.uptime_percentage)}, below the 99% SLA target.
                  </p>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default SystemHealthPanel;