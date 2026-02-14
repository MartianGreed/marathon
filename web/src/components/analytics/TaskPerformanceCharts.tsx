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
  ArcElement,
} from 'chart.js';
import { Line, Bar, Doughnut } from 'react-chartjs-2';
import type { TaskPerformanceData } from '../../lib/analytics';
import { format } from 'date-fns';

ChartJS.register(
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  BarElement,
  ArcElement
);

interface TaskPerformanceChartsProps {
  data: TaskPerformanceData;
  isLoading: boolean;
}

const TaskPerformanceCharts: React.FC<TaskPerformanceChartsProps> = ({ data, isLoading }) => {
  if (isLoading) {
    return (
      <div className="space-y-6">
        <h2 className="text-lg font-semibold text-gray-900">Task Performance</h2>
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

  // Execution Times Line Chart
  const executionTimeData = {
    labels: data.execution_times?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Execution Time (ms)',
        data: data.execution_times?.map(point => point.value) || [],
        borderColor: 'rgb(59, 130, 246)',
        backgroundColor: 'rgba(59, 130, 246, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Success/Failure Rates Line Chart
  const successRateData = {
    labels: data.success_rates?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Success Rate (%)',
        data: data.success_rates?.map(point => point.value * 100) || [],
        borderColor: 'rgb(34, 197, 94)',
        backgroundColor: 'rgba(34, 197, 94, 0.1)',
        tension: 0.3,
        fill: true,
      },
      {
        label: 'Failure Rate (%)',
        data: data.failure_rates?.map(point => point.value * 100) || [],
        borderColor: 'rgb(239, 68, 68)',
        backgroundColor: 'rgba(239, 68, 68, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Throughput Bar Chart
  const throughputData = {
    labels: data.throughput?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Tasks per Hour',
        data: data.throughput?.map(point => point.value) || [],
        backgroundColor: 'rgba(168, 85, 247, 0.8)',
        borderColor: 'rgba(168, 85, 247, 1)',
        borderWidth: 1,
      },
    ],
  };

  // Task Status Distribution (mock data for demonstration)
  const statusDistribution = {
    labels: ['Completed', 'Failed', 'Running', 'Queued'],
    datasets: [
      {
        data: [65, 15, 12, 8], // This should come from the actual data
        backgroundColor: [
          'rgba(34, 197, 94, 0.8)',
          'rgba(239, 68, 68, 0.8)',
          'rgba(59, 130, 246, 0.8)',
          'rgba(156, 163, 175, 0.8)',
        ],
        borderColor: [
          'rgba(34, 197, 94, 1)',
          'rgba(239, 68, 68, 1)',
          'rgba(59, 130, 246, 1)',
          'rgba(156, 163, 175, 1)',
        ],
        borderWidth: 2,
      },
    ],
  };

  const chartOptions = {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      legend: {
        position: 'top' as const,
      },
      tooltip: {
        intersect: false,
        mode: 'index' as const,
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
      },
    },
    interaction: {
      intersect: false,
      mode: 'index' as const,
    },
  };

  const barChartOptions = {
    ...chartOptions,
    plugins: {
      ...chartOptions.plugins,
      tooltip: {
        ...chartOptions.plugins.tooltip,
        callbacks: {
          label: function(context: any) {
            return `${context.dataset.label}: ${context.raw} tasks`;
          }
        }
      }
    }
  };

  return (
    <div className="space-y-6">
      <h2 className="text-lg font-semibold text-gray-900">Task Performance</h2>
      
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Execution Times */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Execution Times</h3>
          <div className="h-64">
            <Line data={executionTimeData} options={chartOptions} />
          </div>
        </div>

        {/* Success/Failure Rates */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Success & Failure Rates</h3>
          <div className="h-64">
            <Line data={successRateData} options={chartOptions} />
          </div>
        </div>

        {/* Throughput */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Task Throughput</h3>
          <div className="h-64">
            <Bar data={throughputData} options={barChartOptions} />
          </div>
        </div>

        {/* Task Status Distribution */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Task Status Distribution</h3>
          <div className="h-64 flex items-center justify-center">
            <div className="w-48 h-48">
              <Doughnut 
                data={statusDistribution} 
                options={{
                  responsive: true,
                  maintainAspectRatio: false,
                  plugins: {
                    legend: {
                      position: 'bottom' as const,
                    },
                  },
                }} 
              />
            </div>
          </div>
        </div>
      </div>

      {/* Performance Insights */}
      <div className="bg-white p-6 rounded-lg shadow-sm border">
        <h3 className="text-md font-medium text-gray-900 mb-4">Performance Insights</h3>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <div className="text-center">
            <div className="text-2xl font-bold text-blue-600">
              {data.execution_times && data.execution_times.length > 0
                ? Math.round(data.execution_times[data.execution_times.length - 1].value / 1000)
                : 0}s
            </div>
            <div className="text-sm text-gray-500">Latest Avg Execution Time</div>
          </div>
          <div className="text-center">
            <div className="text-2xl font-bold text-green-600">
              {data.success_rates && data.success_rates.length > 0
                ? (data.success_rates[data.success_rates.length - 1].value * 100).toFixed(1)
                : 0}%
            </div>
            <div className="text-sm text-gray-500">Current Success Rate</div>
          </div>
          <div className="text-center">
            <div className="text-2xl font-bold text-purple-600">
              {data.throughput && data.throughput.length > 0
                ? Math.round(data.throughput[data.throughput.length - 1].value)
                : 0}
            </div>
            <div className="text-sm text-gray-500">Tasks/Hour</div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default TaskPerformanceCharts;