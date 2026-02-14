import React from 'react';
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  BarElement,
} from 'chart.js';
import { Line, Bar } from 'react-chartjs-2';
import type { ResourceTimeSeriesData } from '../../lib/analytics';
import { format } from 'date-fns';

ChartJS.register(
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  BarElement
);

interface ResourceUsageChartsProps {
  data: ResourceTimeSeriesData;
  isLoading: boolean;
}

const ResourceUsageCharts: React.FC<ResourceUsageChartsProps> = ({ data, isLoading }) => {
  if (isLoading) {
    return (
      <div className="space-y-6">
        <h2 className="text-lg font-semibold text-gray-900">Resource Usage</h2>
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
          {[1, 2, 3, 4].map((i) => (
            <div key={i} className="bg-white p-6 rounded-lg shadow-sm border">
              <div className="animate-pulse">
                <div className="h-4 bg-gray-200 rounded w-1/3 mb-4"></div>
                <div className="h-64 bg-gray-200 rounded"></div>
              </div>
            </div>
          ))}
        </div>
      </div>
    );
  }

  const formatTimestamp = (timestamp: number) => {
    return format(new Date(timestamp * 1000), 'MMM dd HH:mm');
  };

  // CPU Usage Chart
  const cpuData = {
    labels: data.cpu_usage?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'CPU Usage (%)',
        data: data.cpu_usage?.map(point => point.value * 100) || [],
        borderColor: 'rgb(239, 68, 68)',
        backgroundColor: 'rgba(239, 68, 68, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Memory Usage Chart
  const memoryData = {
    labels: data.memory_usage?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Memory Usage (%)',
        data: data.memory_usage?.map(point => point.value * 100) || [],
        borderColor: 'rgb(59, 130, 246)',
        backgroundColor: 'rgba(59, 130, 246, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Disk Usage Chart
  const diskData = {
    labels: data.disk_usage?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Disk Usage (%)',
        data: data.disk_usage?.map(point => point.value * 100) || [],
        borderColor: 'rgb(168, 85, 247)',
        backgroundColor: 'rgba(168, 85, 247, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Network I/O Chart
  const networkData = {
    labels: data.network_io?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Network I/O (MB/s)',
        data: data.network_io?.map(point => point.value / (1024 * 1024)) || [],
        backgroundColor: 'rgba(34, 197, 94, 0.8)',
        borderColor: 'rgba(34, 197, 94, 1)',
        borderWidth: 1,
      },
    ],
  };

  const lineChartOptions = {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      legend: {
        position: 'top' as const,
      },
      tooltip: {
        intersect: false,
        mode: 'index' as const,
        callbacks: {
          label: function(context: any) {
            const value = context.raw;
            if (context.dataset.label.includes('CPU') || 
                context.dataset.label.includes('Memory') || 
                context.dataset.label.includes('Disk')) {
              return `${context.dataset.label}: ${value.toFixed(1)}%`;
            }
            return `${context.dataset.label}: ${value}`;
          }
        }
      },
    },
    scales: {
      x: {
        grid: {
          display: false,
        },
      },
      y: {
        beginAtZero: true,
        max: 100,
        grid: {
          color: 'rgba(0, 0, 0, 0.05)',
        },
        ticks: {
          callback: function(value: any) {
            return value + '%';
          }
        }
      },
    },
    interaction: {
      intersect: false,
      mode: 'index' as const,
    },
  };

  const networkChartOptions = {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      legend: {
        position: 'top' as const,
      },
      tooltip: {
        intersect: false,
        mode: 'index' as const,
        callbacks: {
          label: function(context: any) {
            return `${context.dataset.label}: ${context.raw.toFixed(2)} MB/s`;
          }
        }
      },
    },
    scales: {
      x: {
        grid: {
          display: false,
        },
      },
      y: {
        beginAtZero: true,
        grid: {
          color: 'rgba(0, 0, 0, 0.05)',
        },
        ticks: {
          callback: function(value: any) {
            return value + ' MB/s';
          }
        }
      },
    },
  };

  // Calculate current resource usage levels
  const getCurrentUsage = (dataPoints: any[]) => {
    if (!dataPoints || dataPoints.length === 0) return 0;
    return dataPoints[dataPoints.length - 1].value * 100;
  };

  const currentCpu = getCurrentUsage(data.cpu_usage || []);
  const currentMemory = getCurrentUsage(data.memory_usage || []);
  const currentDisk = getCurrentUsage(data.disk_usage || []);

  const getUsageColor = (percentage: number) => {
    if (percentage > 90) return 'text-red-600';
    if (percentage > 70) return 'text-yellow-600';
    return 'text-green-600';
  };

  const getUsageBarColor = (percentage: number) => {
    if (percentage > 90) return 'bg-red-500';
    if (percentage > 70) return 'bg-yellow-500';
    return 'bg-green-500';
  };

  return (
    <div className="space-y-6">
      <h2 className="text-lg font-semibold text-gray-900">Resource Usage</h2>
      
      {/* Current Resource Usage Overview */}
      <div className="bg-white p-6 rounded-lg shadow-sm border">
        <h3 className="text-md font-medium text-gray-900 mb-4">Current Resource Utilization</h3>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div>
            <div className="flex justify-between items-center mb-2">
              <span className="text-sm font-medium text-gray-700">CPU Usage</span>
              <span className={`text-sm font-bold ${getUsageColor(currentCpu)}`}>
                {currentCpu.toFixed(1)}%
              </span>
            </div>
            <div className="w-full bg-gray-200 rounded-full h-2">
              <div 
                className={`h-2 rounded-full ${getUsageBarColor(currentCpu)}`}
                style={{ width: `${currentCpu}%` }}
              ></div>
            </div>
          </div>
          <div>
            <div className="flex justify-between items-center mb-2">
              <span className="text-sm font-medium text-gray-700">Memory Usage</span>
              <span className={`text-sm font-bold ${getUsageColor(currentMemory)}`}>
                {currentMemory.toFixed(1)}%
              </span>
            </div>
            <div className="w-full bg-gray-200 rounded-full h-2">
              <div 
                className={`h-2 rounded-full ${getUsageBarColor(currentMemory)}`}
                style={{ width: `${currentMemory}%` }}
              ></div>
            </div>
          </div>
          <div>
            <div className="flex justify-between items-center mb-2">
              <span className="text-sm font-medium text-gray-700">Disk Usage</span>
              <span className={`text-sm font-bold ${getUsageColor(currentDisk)}`}>
                {currentDisk.toFixed(1)}%
              </span>
            </div>
            <div className="w-full bg-gray-200 rounded-full h-2">
              <div 
                className={`h-2 rounded-full ${getUsageBarColor(currentDisk)}`}
                style={{ width: `${currentDisk}%` }}
              ></div>
            </div>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* CPU Usage */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">CPU Usage Over Time</h3>
          <div className="h-64">
            <Line data={cpuData} options={lineChartOptions} />
          </div>
        </div>

        {/* Memory Usage */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Memory Usage Over Time</h3>
          <div className="h-64">
            <Line data={memoryData} options={lineChartOptions} />
          </div>
        </div>

        {/* Disk Usage */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Disk Usage Over Time</h3>
          <div className="h-64">
            <Line data={diskData} options={lineChartOptions} />
          </div>
        </div>

        {/* Network I/O */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Network I/O</h3>
          <div className="h-64">
            <Bar data={networkData} options={networkChartOptions} />
          </div>
        </div>
      </div>

      {/* Resource Alerts */}
      <div className="bg-white p-6 rounded-lg shadow-sm border">
        <h3 className="text-md font-medium text-gray-900 mb-4">Resource Alerts</h3>
        <div className="space-y-2">
          {currentCpu > 90 && (
            <div className="flex items-center p-3 bg-red-50 border border-red-200 rounded-md">
              <div className="flex-shrink-0">
                <svg className="w-5 h-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                  <path fillRule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clipRule="evenodd" />
                </svg>
              </div>
              <div className="ml-3">
                <p className="text-sm text-red-800">
                  High CPU usage detected ({currentCpu.toFixed(1)}%). Consider scaling resources.
                </p>
              </div>
            </div>
          )}
          {currentMemory > 90 && (
            <div className="flex items-center p-3 bg-red-50 border border-red-200 rounded-md">
              <div className="flex-shrink-0">
                <svg className="w-5 h-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                  <path fillRule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clipRule="evenodd" />
                </svg>
              </div>
              <div className="ml-3">
                <p className="text-sm text-red-800">
                  High memory usage detected ({currentMemory.toFixed(1)}%). Memory optimization recommended.
                </p>
              </div>
            </div>
          )}
          {currentDisk > 90 && (
            <div className="flex items-center p-3 bg-red-50 border border-red-200 rounded-md">
              <div className="flex-shrink-0">
                <svg className="w-5 h-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                  <path fillRule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clipRule="evenodd" />
                </svg>
              </div>
              <div className="ml-3">
                <p className="text-sm text-red-800">
                  Low disk space available ({(100 - currentDisk).toFixed(1)}% free). Cleanup recommended.
                </p>
              </div>
            </div>
          )}
          {currentCpu <= 90 && currentMemory <= 90 && currentDisk <= 90 && (
            <div className="flex items-center p-3 bg-green-50 border border-green-200 rounded-md">
              <div className="flex-shrink-0">
                <svg className="w-5 h-5 text-green-400" fill="currentColor" viewBox="0 0 20 20">
                  <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clipRule="evenodd" />
                </svg>
              </div>
              <div className="ml-3">
                <p className="text-sm text-green-800">
                  All resource utilization levels are within normal ranges.
                </p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default ResourceUsageCharts;