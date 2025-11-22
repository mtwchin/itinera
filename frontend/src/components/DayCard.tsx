import React from 'react';
import { ItineraryDay } from '../services/api';
import POICard from './POICard';

interface DayCardProps {
  day: ItineraryDay;
  onRemoveItem?: (itemId: number) => void;
}

const DayCard: React.FC<DayCardProps> = ({ day, onRemoveItem }) => {
  const totalHours = day.estimated_duration_minutes
    ? Math.round(day.estimated_duration_minutes / 60)
    : 0;

  return (
    <div className="bg-white rounded-lg shadow-md p-6">
      {/* Day Header */}
      <div className="border-b border-gray-200 pb-4 mb-4">
        <h3 className="text-xl font-bold text-gray-900">
          {day.title || `Day ${day.day_number}`}
        </h3>
        {day.description && (
          <p className="text-sm text-gray-600 mt-1">{day.description}</p>
        )}
        <div className="flex items-center space-x-4 mt-2 text-sm text-gray-500">
          {day.total_distance_km && (
            <div className="flex items-center space-x-1">
              <span>📍</span>
              <span>{day.total_distance_km.toFixed(1)} km</span>
            </div>
          )}
          {totalHours > 0 && (
            <div className="flex items-center space-x-1">
              <span>⏱️</span>
              <span>{totalHours} hours</span>
            </div>
          )}
          <div className="flex items-center space-x-1">
            <span>🎯</span>
            <span>{day.items.length} stops</span>
          </div>
        </div>
      </div>

      {/* POI List */}
      <div className="space-y-3">
        {day.items.map((item, index) => (
          <div key={item.id} className="relative">
            <div className="flex items-start space-x-3">
              {/* Order Number */}
              <div className="flex-shrink-0 w-8 h-8 rounded-full bg-primary-500 text-white flex items-center justify-center font-bold text-sm">
                {index + 1}
              </div>

              {/* POI Card */}
              <div className="flex-1">
                <POICard
                  poi={item.poi}
                  duration={item.suggested_duration_minutes}
                  onRemove={onRemoveItem ? () => onRemoveItem(item.id) : undefined}
                />
              </div>
            </div>

            {/* Distance to next */}
            {item.distance_to_next_km && index < day.items.length - 1 && (
              <div className="ml-4 mt-2 mb-2 flex items-center text-sm text-gray-500">
                <div className="w-px h-4 bg-gray-300 ml-4"></div>
                <span className="ml-6">
                  ↓ {item.distance_to_next_km.toFixed(1)} km (~
                  {Math.round(item.distance_to_next_km * 15)} min walk)
                </span>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
};

export default DayCard;

