import React, { useState } from 'react';
import type { DateRange } from '../../lib/analytics';
import { format, subDays, startOfDay, endOfDay, subMonths } from 'date-fns';
import { CalendarIcon, ChevronDownIcon } from '@heroicons/react/24/outline';

interface DateRangePickerProps {
  dateRange: DateRange;
  onChange: (range: DateRange) => void;
}

const DateRangePicker: React.FC<DateRangePickerProps> = ({ dateRange, onChange }) => {
  const [isOpen, setIsOpen] = useState(false);

  const presetRanges = [
    {
      label: 'Last 24 Hours',
      range: {
        start: startOfDay(subDays(new Date(), 1)),
        end: endOfDay(new Date())
      }
    },
    {
      label: 'Last 7 Days',
      range: {
        start: startOfDay(subDays(new Date(), 7)),
        end: endOfDay(new Date())
      }
    },
    {
      label: 'Last 30 Days',
      range: {
        start: startOfDay(subDays(new Date(), 30)),
        end: endOfDay(new Date())
      }
    },
    {
      label: 'Last 3 Months',
      range: {
        start: startOfDay(subMonths(new Date(), 3)),
        end: endOfDay(new Date())
      }
    },
    {
      label: 'Last 6 Months',
      range: {
        start: startOfDay(subMonths(new Date(), 6)),
        end: endOfDay(new Date())
      }
    }
  ];

  const handlePresetSelect = (preset: typeof presetRanges[0]) => {
    onChange(preset.range);
    setIsOpen(false);
  };

  const handleCustomDateChange = (field: 'start' | 'end', value: string) => {
    const date = new Date(value);
    const newRange = {
      ...dateRange,
      [field]: field === 'start' ? startOfDay(date) : endOfDay(date)
    };
    onChange(newRange);
  };

  const getCurrentRangeLabel = () => {
    const preset = presetRanges.find(p => 
      p.range.start.getTime() === dateRange.start.getTime() && 
      p.range.end.getTime() === dateRange.end.getTime()
    );
    
    if (preset) {
      return preset.label;
    }
    
    return `${format(dateRange.start, 'MMM dd')} - ${format(dateRange.end, 'MMM dd')}`;
  };

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setIsOpen(!isOpen)}
        className="flex items-center space-x-2 px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500"
      >
        <CalendarIcon className="h-4 w-4" />
        <span>{getCurrentRangeLabel()}</span>
        <ChevronDownIcon className="h-4 w-4" />
      </button>

      {isOpen && (
        <div className="absolute right-0 z-10 mt-2 w-80 bg-white rounded-md shadow-lg border border-gray-200">
          <div className="p-4">
            <h3 className="text-sm font-medium text-gray-900 mb-3">Date Range</h3>
            
            {/* Preset Ranges */}
            <div className="space-y-1 mb-4">
              {presetRanges.map((preset) => (
                <button
                  key={preset.label}
                  onClick={() => handlePresetSelect(preset)}
                  className="w-full text-left px-3 py-2 text-sm text-gray-700 hover:bg-gray-100 rounded-md transition-colors"
                >
                  {preset.label}
                </button>
              ))}
            </div>

            {/* Custom Date Range */}
            <div className="border-t border-gray-200 pt-4">
              <h4 className="text-xs font-medium text-gray-500 uppercase tracking-wide mb-2">
                Custom Range
              </h4>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium text-gray-700 mb-1">
                    Start Date
                  </label>
                  <input
                    type="date"
                    value={format(dateRange.start, 'yyyy-MM-dd')}
                    onChange={(e) => handleCustomDateChange('start', e.target.value)}
                    className="w-full px-3 py-2 text-sm border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium text-gray-700 mb-1">
                    End Date
                  </label>
                  <input
                    type="date"
                    value={format(dateRange.end, 'yyyy-MM-dd')}
                    onChange={(e) => handleCustomDateChange('end', e.target.value)}
                    className="w-full px-3 py-2 text-sm border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500"
                  />
                </div>
              </div>
            </div>

            {/* Actions */}
            <div className="flex justify-end space-x-2 mt-4 pt-4 border-t border-gray-200">
              <button
                onClick={() => setIsOpen(false)}
                className="px-3 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"
              >
                Cancel
              </button>
              <button
                onClick={() => setIsOpen(false)}
                className="px-3 py-2 text-sm font-medium text-white bg-blue-600 rounded-md hover:bg-blue-700"
              >
                Apply
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Backdrop */}
      {isOpen && (
        <div
          className="fixed inset-0 z-0"
          onClick={() => setIsOpen(false)}
        />
      )}
    </div>
  );
};

export default DateRangePicker;