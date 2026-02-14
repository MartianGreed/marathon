import React, { useState } from 'react';
import { exportDashboard, type DateRange, type ExportFormat } from '../../lib/analytics';
import { format } from 'date-fns';
import { 
  ArrowDownTrayIcon, 
  ChevronDownIcon,
  DocumentIcon,
  TableCellsIcon 
} from '@heroicons/react/24/outline';
import toast from 'react-hot-toast';

interface ExportButtonProps {
  dateRange: DateRange;
  isLoading: boolean;
}

const ExportButton: React.FC<ExportButtonProps> = ({ dateRange, isLoading }) => {
  const [isOpen, setIsOpen] = useState(false);
  const [isExporting, setIsExporting] = useState(false);

  const exportOptions = [
    {
      type: 'csv' as const,
      label: 'Export as CSV',
      description: 'Spreadsheet-friendly format',
      icon: TableCellsIcon,
      mimeType: 'text/csv'
    },
    {
      type: 'pdf' as const,
      label: 'Export as PDF',
      description: 'Complete dashboard report',
      icon: DocumentIcon,
      mimeType: 'application/pdf'
    }
  ];

  const generateFilename = (exportFormat: 'csv' | 'pdf') => {
    const startDate = format(dateRange.start, 'yyyy-MM-dd');
    const endDate = format(dateRange.end, 'yyyy-MM-dd');
    
    return `marathon-analytics-${startDate}-to-${endDate}.${exportFormat}`;
  };

  const handleExport = async (exportFormat: ExportFormat) => {
    setIsExporting(true);
    setIsOpen(false);

    const loadingToast = toast.loading(`Generating ${exportFormat.type.toUpperCase()} export...`);

    try {
      const blob = await exportDashboard(exportFormat, dateRange);
      
      // Create download link
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.style.display = 'none';
      a.href = url;
      a.download = exportFormat.filename;
      document.body.appendChild(a);
      a.click();
      
      // Cleanup
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);
      
      toast.success(`${exportFormat.type.toUpperCase()} export completed successfully!`, {
        id: loadingToast
      });
    } catch (error) {
      console.error('Export failed:', error);
      toast.error(`Failed to export ${exportFormat.type.toUpperCase()}. Please try again.`, {
        id: loadingToast
      });
    } finally {
      setIsExporting(false);
    }
  };

  const handleOptionClick = (option: typeof exportOptions[0]) => {
    const exportFormat: ExportFormat = {
      type: option.type,
      filename: generateFilename(option.type)
    };
    
    handleExport(exportFormat);
  };

  if (isLoading) {
    return (
      <button
        disabled
        className="flex items-center space-x-2 px-4 py-2 text-sm font-medium text-gray-400 bg-gray-100 border border-gray-200 rounded-md cursor-not-allowed"
      >
        <ArrowDownTrayIcon className="h-4 w-4" />
        <span>Export</span>
      </button>
    );
  }

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setIsOpen(!isOpen)}
        disabled={isExporting}
        className={`flex items-center space-x-2 px-4 py-2 text-sm font-medium rounded-md transition-colors ${
          isExporting
            ? 'text-gray-400 bg-gray-100 border border-gray-200 cursor-not-allowed'
            : 'text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500'
        }`}
      >
        <ArrowDownTrayIcon className="h-4 w-4" />
        <span>{isExporting ? 'Exporting...' : 'Export'}</span>
        <ChevronDownIcon className="h-4 w-4" />
      </button>

      {isOpen && !isExporting && (
        <div className="absolute right-0 z-10 mt-2 w-64 bg-white rounded-md shadow-lg border border-gray-200">
          <div className="py-1">
            <div className="px-4 py-2 border-b border-gray-100">
              <p className="text-xs font-medium text-gray-500 uppercase tracking-wide">
                Export Options
              </p>
            </div>
            
            {exportOptions.map((option) => {
              const IconComponent = option.icon;
              return (
                <button
                  key={option.type}
                  onClick={() => handleOptionClick(option)}
                  className="w-full text-left px-4 py-3 hover:bg-gray-50 transition-colors"
                >
                  <div className="flex items-center space-x-3">
                    <IconComponent className="h-5 w-5 text-gray-400" />
                    <div>
                      <p className="text-sm font-medium text-gray-900">
                        {option.label}
                      </p>
                      <p className="text-xs text-gray-500">
                        {option.description}
                      </p>
                    </div>
                  </div>
                </button>
              );
            })}
            
            <div className="px-4 py-2 border-t border-gray-100">
              <p className="text-xs text-gray-500">
                Export data for: {format(dateRange.start, 'MMM dd')} - {format(dateRange.end, 'MMM dd, yyyy')}
              </p>
            </div>
          </div>
        </div>
      )}

      {/* Backdrop */}
      {isOpen && !isExporting && (
        <div
          className="fixed inset-0 z-0"
          onClick={() => setIsOpen(false)}
        />
      )}
    </div>
  );
};

export default ExportButton;