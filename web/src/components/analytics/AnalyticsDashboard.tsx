import React, { useState, useEffect } from 'react';
import { useQuery } from '@tanstack/react-query';
import { 
  getDashboardData, 
  AnalyticsWebSocket,
  type AnalyticsDashboard as DashboardData,
  type DateRange, 
} from '../../lib/analytics';
import { format, subDays, startOfDay, endOfDay } from 'date-fns';
import toast from 'react-hot-toast';

// Import components
import OverviewCards from './OverviewCards';
import TaskPerformanceCharts from './TaskPerformanceCharts';
import ResourceUsageCharts from './ResourceUsageCharts';
import UserActivityCharts from './UserActivityCharts';
import SystemHealthPanel from './SystemHealthPanel';
import DateRangePicker from './DateRangePicker';
import ExportButton from './ExportButton';

const AnalyticsDashboard: React.FC = () => {
  const [dateRange, setDateRange] = useState<DateRange>({
    start: startOfDay(subDays(new Date(), 7)),
    end: endOfDay(new Date())
  });
  const [isRealTimeEnabled, setIsRealTimeEnabled] = useState(true);
  const [websocket, setWebsocket] = useState<AnalyticsWebSocket | null>(null);

  // Main dashboard data query
  const { data: dashboardData, isLoading, error, refetch } = useQuery<DashboardData>({
    queryKey: ['dashboard', dateRange],
    queryFn: () => getDashboardData(dateRange),
    refetchInterval: isRealTimeEnabled ? 30000 : false, // Refetch every 30 seconds if real-time is enabled
    staleTime: 15000 // Consider data stale after 15 seconds
  });

  // WebSocket connection for real-time updates
  useEffect(() => {
    if (!isRealTimeEnabled) return;

    const ws = new AnalyticsWebSocket();
    ws.connect()
      .then(() => {
        setWebsocket(ws);
        toast.success('Real-time updates enabled');

        // Set up event handlers
        ws.onMessage('task_completed', () => {
          refetch();
        });

        ws.onMessage('task_started', () => {
          refetch();
        });

        ws.onMessage('task_failed', () => {
          refetch();
        });

        ws.onMessage('resource_update', () => {
          refetch();
        });

        ws.onMessage('user_activity', () => {
          refetch();
        });

        ws.onMessage('system_alert', (data) => {
          toast.error(`System Alert: ${data.message}`, {
            duration: 10000
          });
        });
      })
      .catch((error) => {
        console.error('Failed to connect to WebSocket:', error);
        toast.error('Failed to enable real-time updates');
      });

    return () => {
      ws.disconnect();
      setWebsocket(null);
    };
  }, [isRealTimeEnabled, refetch]);

  const handleDateRangeChange = (newRange: DateRange) => {
    setDateRange(newRange);
  };

  const toggleRealTime = () => {
    setIsRealTimeEnabled(!isRealTimeEnabled);
    if (isRealTimeEnabled && websocket) {
      websocket.disconnect();
      setWebsocket(null);
    }
  };

  if (error) {
    return (
      <div className="min-h-screen bg-gray-50 flex items-center justify-center">
        <div className="bg-white p-8 rounded-lg shadow-md max-w-md w-full text-center">
          <div className="text-red-500 text-xl mb-4">⚠️</div>
          <h2 className="text-xl font-semibold text-gray-900 mb-2">Failed to Load Dashboard</h2>
          <p className="text-gray-600 mb-4">
            {error instanceof Error ? error.message : 'An unexpected error occurred'}
          </p>
          <button
            onClick={() => refetch()}
            className="bg-blue-500 text-white px-4 py-2 rounded-md hover:bg-blue-600 transition-colors"
          >
            Retry
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <div className="bg-white shadow-sm border-b">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex items-center justify-between py-4">
            <div>
              <h1 className="text-2xl font-bold text-gray-900">Analytics Dashboard</h1>
              <p className="text-sm text-gray-500">
                Monitor task performance, resource usage, and team productivity
              </p>
            </div>
            
            <div className="flex items-center space-x-4">
              {/* Real-time toggle */}
              <div className="flex items-center">
                <input
                  type="checkbox"
                  id="realtime-toggle"
                  checked={isRealTimeEnabled}
                  onChange={toggleRealTime}
                  className="mr-2"
                />
                <label htmlFor="realtime-toggle" className="text-sm text-gray-700">
                  Real-time updates
                </label>
                {websocket?.isConnected() && (
                  <div className="ml-2 w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
                )}
              </div>

              {/* Date range picker */}
              <DateRangePicker
                dateRange={dateRange}
                onChange={handleDateRangeChange}
              />

              {/* Export button */}
              <ExportButton
                dateRange={dateRange}
                isLoading={isLoading}
              />
            </div>
          </div>
        </div>
      </div>

      {/* Main content */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {isLoading && !dashboardData ? (
          <div className="flex items-center justify-center py-12">
            <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-500"></div>
            <span className="ml-3 text-lg text-gray-600">Loading dashboard data...</span>
          </div>
        ) : dashboardData ? (
          <div className="space-y-8">
            {/* Overview Cards */}
            <OverviewCards 
              data={dashboardData.overview}
              isLoading={isLoading}
            />

            {/* System Health */}
            <SystemHealthPanel 
              data={dashboardData.overview.system_health}
              isLoading={isLoading}
            />

            {/* Task Performance Charts */}
            <TaskPerformanceCharts 
              data={dashboardData.time_series.task_performance}
              isLoading={isLoading}
            />

            {/* Resource Usage Charts */}
            <ResourceUsageCharts 
              data={dashboardData.time_series.resource_usage}
              isLoading={isLoading}
            />

            {/* User Activity Charts */}
            <UserActivityCharts 
              data={dashboardData.time_series.user_activity}
              isLoading={isLoading}
            />

            {/* Last updated timestamp */}
            <div className="text-center text-sm text-gray-500">
              Last updated: {format(new Date(dashboardData.last_updated * 1000), 'PPpp')}
            </div>
          </div>
        ) : (
          <div className="text-center py-12">
            <p className="text-gray-500">No data available for the selected date range.</p>
          </div>
        )}
      </div>
    </div>
  );
};

export default AnalyticsDashboard;