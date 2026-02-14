import React from 'react';
import type { TaskMetrics, ResourceUsage, UserActivity, SystemHealth } from '../../lib/analytics';
import { 
  CheckCircleIcon, 
  XCircleIcon, 
  ClockIcon, 
  CpuChipIcon,
  UserGroupIcon,
  ServerIcon,
  ArrowTrendingUpIcon,
  ArrowTrendingDownIcon
} from '@heroicons/react/24/outline';

interface OverviewCardsProps {
  data: {
    task_metrics: TaskMetrics;
    resource_usage: ResourceUsage;
    user_activity: UserActivity;
    system_health: SystemHealth;
  };
  isLoading: boolean;
}

interface MetricCardProps {
  title: string;
  value: string | number;
  icon: React.ReactNode;
  trend?: {
    value: number;
    isPositive: boolean;
  };
  color: string;
  isLoading?: boolean;
}

const MetricCard: React.FC<MetricCardProps> = ({ 
  title, 
  value, 
  icon, 
  trend, 
  color,
  isLoading = false 
}) => {
  return (
    <div className="bg-white rounded-lg shadow-sm border p-6">
      <div className="flex items-center justify-between">
        <div>
          <p className="text-sm font-medium text-gray-600">{title}</p>
          {isLoading ? (
            <div className="mt-2 h-8 w-20 bg-gray-200 animate-pulse rounded"></div>
          ) : (
            <p className="mt-2 text-3xl font-bold text-gray-900">{value}</p>
          )}
          {trend && !isLoading && (
            <div className="mt-2 flex items-center text-sm">
              {trend.isPositive ? (
                <ArrowTrendingUpIcon className="h-4 w-4 text-green-500 mr-1" />
              ) : (
                <ArrowTrendingDownIcon className="h-4 w-4 text-red-500 mr-1" />
              )}
              <span className={trend.isPositive ? 'text-green-500' : 'text-red-500'}>
                {Math.abs(trend.value)}%
              </span>
              <span className="text-gray-500 ml-1">vs last period</span>
            </div>
          )}
        </div>
        <div className={`p-3 rounded-full ${color}`}>
          {icon}
        </div>
      </div>
    </div>
  );
};

const OverviewCards: React.FC<OverviewCardsProps> = ({ data, isLoading }) => {
  const { task_metrics, resource_usage, user_activity, system_health } = data;

  const formatPercentage = (value: number) => `${(value * 100).toFixed(1)}%`;
  const formatTime = (ms: number) => {
    if (ms < 1000) return `${ms}ms`;
    if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
    return `${(ms / 60000).toFixed(1)}m`;
  };

  const cards = [
    {
      title: 'Total Tasks',
      value: task_metrics?.total_tasks?.toLocaleString() || '0',
      icon: <ClockIcon className="h-6 w-6 text-white" />,
      color: 'bg-blue-500',
      trend: {
        value: 12,
        isPositive: true
      }
    },
    {
      title: 'Success Rate',
      value: task_metrics ? formatPercentage(task_metrics.success_rate || 0) : '0%',
      icon: <CheckCircleIcon className="h-6 w-6 text-white" />,
      color: 'bg-green-500',
      trend: {
        value: 3.2,
        isPositive: true
      }
    },
    {
      title: 'Avg Execution Time',
      value: task_metrics ? formatTime(task_metrics.average_execution_time_ms || 0) : '0ms',
      icon: <ClockIcon className="h-6 w-6 text-white" />,
      color: 'bg-yellow-500',
      trend: {
        value: 8.1,
        isPositive: false
      }
    },
    {
      title: 'Active Users',
      value: user_activity?.total_active_users?.toLocaleString() || '0',
      icon: <UserGroupIcon className="h-6 w-6 text-white" />,
      color: 'bg-purple-500',
      trend: {
        value: 15.7,
        isPositive: true
      }
    },
    {
      title: 'CPU Usage',
      value: resource_usage ? formatPercentage(resource_usage.average_cpu_usage || 0) : '0%',
      icon: <CpuChipIcon className="h-6 w-6 text-white" />,
      color: 'bg-orange-500'
    },
    {
      title: 'Memory Usage',
      value: resource_usage ? formatPercentage(resource_usage.average_memory_usage || 0) : '0%',
      icon: <ServerIcon className="h-6 w-6 text-white" />,
      color: 'bg-red-500'
    },
    {
      title: 'System Uptime',
      value: system_health ? formatPercentage(system_health.uptime_percentage || 0) : '0%',
      icon: <CheckCircleIcon className="h-6 w-6 text-white" />,
      color: 'bg-emerald-500'
    },
    {
      title: 'Failed Tasks',
      value: task_metrics?.failed_tasks?.toLocaleString() || '0',
      icon: <XCircleIcon className="h-6 w-6 text-white" />,
      color: 'bg-red-600',
      trend: {
        value: 5.3,
        isPositive: false
      }
    }
  ];

  return (
    <div>
      <h2 className="text-lg font-semibold text-gray-900 mb-4">Overview</h2>
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        {cards.map((card, index) => (
          <MetricCard
            key={index}
            title={card.title}
            value={card.value}
            icon={card.icon}
            trend={card.trend}
            color={card.color}
            isLoading={isLoading}
          />
        ))}
      </div>
    </div>
  );
};

export default OverviewCards;