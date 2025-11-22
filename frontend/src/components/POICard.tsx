import React from 'react';
import { POI } from '../services/api';

interface POICardProps {
  poi: POI;
  duration?: number;
  onRemove?: () => void;
}

const POICard: React.FC<POICardProps> = ({ poi, duration, onRemove }) => {
  const getTypeEmoji = (type: string) => {
    const emojiMap: { [key: string]: string } = {
      restaurant: '🍽️',
      cafe: '☕',
      bar: '🍹',
      museum: '🏛️',
      park: '🌳',
      landmark: '🗿',
      attraction: '🎭',
      shopping: '🛍️',
      entertainment: '🎪',
    };
    return emojiMap[type] || '📍';
  };

  const renderStars = (rating?: number) => {
    if (!rating) return null;
    const stars = Math.round(rating);
    return (
      <div className="flex items-center space-x-1">
        {[...Array(5)].map((_, i) => (
          <span key={i} className={i < stars ? 'text-yellow-400' : 'text-gray-300'}>
            ★
          </span>
        ))}
        <span className="text-sm text-gray-600 ml-1">{rating.toFixed(1)}</span>
      </div>
    );
  };

  return (
    <div className="bg-gray-50 rounded-lg p-4 hover:bg-gray-100 transition-colors">
      <div className="flex justify-between items-start">
        <div className="flex-1">
          {/* Name and Type */}
          <div className="flex items-center space-x-2 mb-2">
            <span className="text-xl">{getTypeEmoji(poi.poi_type)}</span>
            <h4 className="font-semibold text-gray-900">{poi.name}</h4>
            {poi.is_food && (
              <span className="px-2 py-0.5 bg-orange-100 text-orange-700 text-xs rounded-full">
                Food
              </span>
            )}
          </div>

          {/* Description */}
          {poi.description && (
            <p className="text-sm text-gray-600 mb-2">{poi.description}</p>
          )}

          {/* Rating and Duration */}
          <div className="flex items-center space-x-4 text-sm">
            {renderStars(poi.rating)}
            {duration && (
              <span className="text-gray-500">⏱️ {duration} min</span>
            )}
            {poi.price_level && (
              <span className="text-gray-500">
                {'$'.repeat(poi.price_level)}
              </span>
            )}
          </div>

          {/* Address */}
          {poi.address && (
            <p className="text-xs text-gray-500 mt-2">📍 {poi.address}</p>
          )}
        </div>

        {/* Remove Button */}
        {onRemove && (
          <button
            onClick={onRemove}
            className="ml-2 text-gray-400 hover:text-red-500 transition-colors"
            title="Remove from itinerary"
          >
            <svg
              className="w-5 h-5"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        )}
      </div>
    </div>
  );
};

export default POICard;

