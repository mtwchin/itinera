import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { tripApi, TripCreate } from '../services/api';

const TripWizard: React.FC = () => {
  const navigate = useNavigate();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  
  const [formData, setFormData] = useState<TripCreate>({
    city: '',
    country: '',
    duration_days: 3,
    preference_food_weight: 50,
    preference_walking_friendly: 50,
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    setError(null);

    try {
      const trip = await tripApi.createTrip(formData);
      navigate(`/itinerary/${trip.id}`);
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Failed to create trip');
      setLoading(false);
    }
  };

  return (
    <div className="bg-white rounded-lg shadow-lg p-8 max-w-2xl mx-auto">
      <h2 className="text-3xl font-bold text-gray-900 mb-2">
        Plan Your Perfect Trip
      </h2>
      <p className="text-gray-600 mb-6">
        Powered by TikTok travel content and AI
      </p>

      <form onSubmit={handleSubmit} className="space-y-6">
        {/* City Input */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Destination City *
          </label>
          <input
            type="text"
            required
            value={formData.city}
            onChange={(e) => setFormData({ ...formData, city: e.target.value })}
            placeholder="e.g., Paris, Tokyo, New York"
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent"
          />
        </div>

        {/* Country Input */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Country (Optional)
          </label>
          <input
            type="text"
            value={formData.country}
            onChange={(e) => setFormData({ ...formData, country: e.target.value })}
            placeholder="e.g., France, Japan, USA"
            className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary-500 focus:border-transparent"
          />
        </div>

        {/* Duration */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Trip Length: {formData.duration_days} days
          </label>
          <input
            type="range"
            min="1"
            max="14"
            value={formData.duration_days}
            onChange={(e) =>
              setFormData({ ...formData, duration_days: parseInt(e.target.value) })
            }
            className="w-full h-2 bg-gray-200 rounded-lg appearance-none cursor-pointer"
          />
          <div className="flex justify-between text-xs text-gray-500 mt-1">
            <span>1 day</span>
            <span>14 days</span>
          </div>
        </div>

        {/* Food vs Sights */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Experience Balance
          </label>
          <div className="flex items-center space-x-4">
            <span className="text-sm text-gray-600">More Sights</span>
            <input
              type="range"
              min="0"
              max="100"
              value={formData.preference_food_weight}
              onChange={(e) =>
                setFormData({ ...formData, preference_food_weight: parseInt(e.target.value) })
              }
              className="flex-1 h-2 bg-gradient-to-r from-blue-500 to-orange-500 rounded-lg appearance-none cursor-pointer"
            />
            <span className="text-sm text-gray-600">More Food</span>
          </div>
        </div>

        {/* Walking Friendly */}
        <div>
          <label className="block text-sm font-medium text-gray-700 mb-2">
            Walking Preference
          </label>
          <div className="flex items-center space-x-4">
            <span className="text-sm text-gray-600">Spread Out</span>
            <input
              type="range"
              min="0"
              max="100"
              value={formData.preference_walking_friendly}
              onChange={(e) =>
                setFormData({ ...formData, preference_walking_friendly: parseInt(e.target.value) })
              }
              className="flex-1 h-2 bg-gradient-to-r from-purple-500 to-green-500 rounded-lg appearance-none cursor-pointer"
            />
            <span className="text-sm text-gray-600">Compact</span>
          </div>
        </div>

        {/* Error Message */}
        {error && (
          <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg">
            {error}
          </div>
        )}

        {/* Submit Button */}
        <button
          type="submit"
          disabled={loading}
          className="w-full bg-primary-600 text-white py-3 px-6 rounded-lg font-semibold hover:bg-primary-700 disabled:bg-gray-400 disabled:cursor-not-allowed transition-colors"
        >
          {loading ? (
            <span className="flex items-center justify-center">
              <svg className="animate-spin -ml-1 mr-3 h-5 w-5 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
              Creating your itinerary...
            </span>
          ) : (
            'Generate Itinerary'
          )}
        </button>
      </form>

      <div className="mt-6 text-center text-sm text-gray-500">
        <p>
          This usually takes 30-60 seconds as we discover trending spots from TikTok
        </p>
      </div>
    </div>
  );
};

export default TripWizard;

