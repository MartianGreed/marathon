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
import type { UserActivityData } from '../../lib/analytics';
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

interface UserActivityChartsProps {
  data: UserActivityData;
  isLoading: boolean;
}

const UserActivityCharts: React.FC<UserActivityChartsProps> = ({ data, isLoading }) => {
  if (isLoading) {
    return (
      <div className="space-y-6">
        <h2 className="text-lg font-semibold text-gray-900">User Activity & Engagement</h2>
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

  // Login Frequency Chart
  const loginData = {
    labels: data.login_frequency?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'User Logins',
        data: data.login_frequency?.map(point => point.value) || [],
        borderColor: 'rgb(59, 130, 246)',
        backgroundColor: 'rgba(59, 130, 246, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Task Creation Activity
  const taskCreationData = {
    labels: data.task_creation?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Tasks Created',
        data: data.task_creation?.map(point => point.value) || [],
        backgroundColor: 'rgba(34, 197, 94, 0.8)',
        borderColor: 'rgba(34, 197, 94, 1)',
        borderWidth: 1,
      },
    ],
  };

  // Workspace Usage
  const workspaceData = {
    labels: data.workspace_usage?.map(point => formatTimestamp(point.timestamp)) || [],
    datasets: [
      {
        label: 'Active Workspaces',
        data: data.workspace_usage?.map(point => point.value) || [],
        borderColor: 'rgb(168, 85, 247)',
        backgroundColor: 'rgba(168, 85, 247, 0.1)',
        tension: 0.3,
        fill: true,
      },
    ],
  };

  // Generate heatmap data for user activity (mock data for demonstration)
  const generateHeatmapData = () => {
    // Generate mock heatmap data based on typical patterns
    const heatmapData = [];
    for (let day = 0; day < 7; day++) {
      for (let hour = 0; hour < 24; hour++) {
        // Simulate higher activity during work hours on weekdays
        let intensity;
        if (day >= 1 && day <= 5) { // Weekdays
          if (hour >= 9 && hour <= 17) {
            intensity = Math.floor(Math.random() * 50) + 50; // High activity
          } else if (hour >= 6 && hour <= 22) {
            intensity = Math.floor(Math.random() * 30) + 20; // Medium activity
          } else {
            intensity = Math.floor(Math.random() * 10); // Low activity
          }
        } else { // Weekends
          intensity = Math.floor(Math.random() * 20) + 10; // Lower overall activity
        }
        
        heatmapData.push({
          x: hour,
          y: day,
          v: intensity
        });
      }
    }
    return heatmapData;
  };

  const heatmapData = generateHeatmapData();

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

  // User engagement breakdown (mock data)
  const engagementData = {
    labels: ['Highly Active', 'Active', 'Moderate', 'Low Activity'],
    datasets: [
      {
        data: [25, 35, 25, 15],
        backgroundColor: [
          'rgba(34, 197, 94, 0.8)',
          'rgba(59, 130, 246, 0.8)',
          'rgba(251, 191, 36, 0.8)',
          'rgba(156, 163, 175, 0.8)',
        ],
        borderColor: [
          'rgba(34, 197, 94, 1)',
          'rgba(59, 130, 246, 1)',
          'rgba(251, 191, 36, 1)',
          'rgba(156, 163, 175, 1)',
        ],
        borderWidth: 2,
      },
    ],
  };

  return (
    <div className="space-y-6">
      <h2 className="text-lg font-semibold text-gray-900">User Activity & Engagement</h2>
      
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Login Frequency */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">User Login Frequency</h3>
          <div className="h-64">
            <Line data={loginData} options={chartOptions} />
          </div>
        </div>

        {/* Task Creation Activity */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Task Creation Activity</h3>
          <div className="h-64">
            <Bar data={taskCreationData} options={chartOptions} />
          </div>
        </div>

        {/* Workspace Usage */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">Workspace Usage</h3>
          <div className="h-64">
            <Line data={workspaceData} options={chartOptions} />
          </div>
        </div>

        {/* User Engagement Breakdown */}
        <div className="bg-white p-6 rounded-lg shadow-sm border">
          <h3 className="text-md font-medium text-gray-900 mb-4">User Engagement Levels</h3>
          <div className="h-64 flex items-center justify-center">
            <div className="w-48 h-48">
              <Doughnut 
                data={engagementData} 
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

      {/* Activity Heatmap */}
      <div className="bg-white p-6 rounded-lg shadow-sm border">
        <h3 className="text-md font-medium text-gray-900 mb-4">User Activity Heatmap</h3>
        <div className="overflow-x-auto">
          <div className="inline-block min-w-full">
            <div className="grid grid-cols-25 gap-1 text-xs">
              {/* Hour headers */}
              <div></div>
              {Array.from({ length: 24 }, (_, i) => (
                <div key={i} className="text-center text-gray-500 p-1">
                  {i}
                </div>
              ))}
              
              {/* Heatmap rows */}
              {['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].map((day, dayIndex) => (
                <React.Fragment key={day}>
                  <div className="text-gray-500 p-1 text-right pr-2">{day}</div>
                  {Array.from({ length: 24 }, (_, hour) => {
                    const dataPoint = heatmapData.find(d => d.x === hour && d.y === dayIndex);
                    const intensity = dataPoint ? dataPoint.v : 0;
                    const opacity = intensity / 100;
                    
                    return (
                      <div
                        key={`${dayIndex}-${hour}`}
                        className="w-4 h-4 rounded-sm border border-gray-100"
                        style={{
                          backgroundColor: `rgba(59, 130, 246, ${opacity})`,
                        }}
                        title={`${day} ${hour}:00 - ${intensity} activities`}
                      ></div>
                    );
                  })}
                </React.Fragment>
              ))}
            </div>
            
            {/* Legend */}
            <div className="mt-4 flex items-center justify-center space-x-2">
              <span className="text-sm text-gray-500">Less</span>
              {[0.2, 0.4, 0.6, 0.8, 1.0].map((opacity, index) => (
                <div
                  key={index}
                  className="w-3 h-3 rounded-sm border border-gray-200"
                  style={{ backgroundColor: `rgba(59, 130, 246, ${opacity})` }}
                ></div>
              ))}
              <span className="text-sm text-gray-500">More</span>
            </div>
          </div>
        </div>
      </div>

      {/* Activity Summary */}
      <div className="bg-white p-6 rounded-lg shadow-sm border">
        <h3 className="text-md font-medium text-gray-900 mb-4">Activity Summary</h3>
        <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
          <div className="text-center">
            <div className="text-2xl font-bold text-blue-600">
              {data.login_frequency && data.login_frequency.length > 0
                ? data.login_frequency.reduce((sum, point) => sum + point.value, 0)
                : 0}
            </div>
            <div className="text-sm text-gray-500">Total Logins</div>
          </div>
          <div className="text-center">
            <div className="text-2xl font-bold text-green-600">
              {data.task_creation && data.task_creation.length > 0
                ? data.task_creation.reduce((sum, point) => sum + point.value, 0)
                : 0}
            </div>
            <div className="text-sm text-gray-500">Tasks Created</div>
          </div>
          <div className="text-center">
            <div className="text-2xl font-bold text-purple-600">
              {data.workspace_usage && data.workspace_usage.length > 0
                ? Math.max(...data.workspace_usage.map(point => point.value))
                : 0}
            </div>
            <div className="text-sm text-gray-500">Peak Workspaces</div>
          </div>
          <div className="text-center">
            <div className="text-2xl font-bold text-yellow-600">
              {data.login_frequency && data.login_frequency.length > 0
                ? Math.round(data.login_frequency.reduce((sum, point) => sum + point.value, 0) / data.login_frequency.length * 10) / 10
                : 0}
            </div>
            <div className="text-sm text-gray-500">Avg Daily Logins</div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default UserActivityCharts;