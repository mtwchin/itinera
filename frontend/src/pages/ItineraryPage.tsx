import React, { useEffect, useState, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { tripApi, itineraryApi, Itinerary, Trip } from '../services/api';
import MapView from '../components/MapView';
import DayCard from '../components/DayCard';
import LoadingSpinner from '../components/LoadingSpinner';

const ItineraryPage: React.FC = () => {
  const { tripId } = useParams<{ tripId: string }>();
  const navigate = useNavigate();

  const [trip, setTrip] = useState<Trip | null>(null);
  const [itinerary, setItinerary] = useState<Itinerary | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [processingStatus, setProcessingStatus] = useState<string>('');
  const [selectedDay, setSelectedDay] = useState<number>(1);

  const loadTripStatus = useCallback(async () => {
    if (!tripId) return;

    try {
      const tripData = await tripApi.getTrip(parseInt(tripId));
      setTrip(tripData);

      if (tripData.status === 'completed') {
        // Load the itinerary
        const itineraryData = await itineraryApi.getItineraryForTrip(
          parseInt(tripId)
        );
        setItinerary(itineraryData);
        setLoading(false);
      } else if (tripData.status === 'failed') {
        setError(tripData.error_message || 'Failed to generate itinerary');
        setLoading(false);
      } else {
        // Still processing - check status
        const statusData = await tripApi.getTripStatus(parseInt(tripId));
        if (statusData.step) {
          setProcessingStatus(statusData.step);
        }
      }
    } catch (err: any) {
      setError(err.response?.data?.detail || 'Failed to load trip');
      setLoading(false);
    }
  }, [tripId]);

  useEffect(() => {
    loadTripStatus();

    // Poll for updates if processing
    const interval = setInterval(() => {
      if (trip?.status === 'processing' || trip?.status === 'pending') {
        loadTripStatus();
      }
    }, 3000); // Poll every 3 seconds

    return () => clearInterval(interval);
  }, [trip?.status, loadTripStatus]);

  const handleRemoveItem = async (itemId: number) => {
    if (!itinerary) return;

    try {
      await itineraryApi.deleteItem(itemId);
      // Reload itinerary
      const updatedItinerary = await itineraryApi.getItineraryForTrip(
        parseInt(tripId!)
      );
      setItinerary(updatedItinerary);
    } catch (err) {
      console.error('Failed to remove item:', err);
    }
  };

  // Loading state
  if (loading && (!trip || trip.status !== 'completed')) {
    return (
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        <div className="bg-white rounded-lg shadow-lg">
          <LoadingSpinner
            message={`Planning your trip to ${trip?.city || 'your destination'}...`}
            step={processingStatus}
          />
        </div>
      </div>
    );
  }

  // Error state
  if (error) {
    return (
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        <div className="bg-white rounded-lg shadow-lg p-8 text-center">
          <div className="text-6xl mb-4">😞</div>
          <h2 className="text-2xl font-bold text-gray-900 mb-2">
            Oops! Something went wrong
          </h2>
          <p className="text-gray-600 mb-6">{error}</p>
          <button
            onClick={() => navigate('/')}
            className="bg-primary-600 text-white px-6 py-2 rounded-lg hover:bg-primary-700 transition-colors"
          >
            Start Over
          </button>
        </div>
      </div>
    );
  }

  if (!itinerary || !trip) {
    return null;
  }

  // Get POIs for selected day
  const selectedDayData = itinerary.days.find(
    (d) => d.day_number === selectedDay
  );
  const dayPOIs = selectedDayData
    ? selectedDayData.items.map((item) => item.poi)
    : [];

  return (
    <div className="min-h-screen bg-gray-50">
      {/* Header */}
      <div className="bg-white border-b border-gray-200">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
          <div className="flex justify-between items-start">
            <div>
              <h1 className="text-3xl font-bold text-gray-900">
                {trip.city} Itinerary
              </h1>
              <p className="text-gray-600 mt-1">
                {trip.duration_days} days • {itinerary.days.reduce((sum, day) => sum + day.items.length, 0)} stops
              </p>
              {itinerary.total_distance_km && (
                <p className="text-sm text-gray-500 mt-1">
                  Total distance: {itinerary.total_distance_km.toFixed(1)} km
                </p>
              )}
            </div>
            <button
              onClick={() => navigate('/')}
              className="text-primary-600 hover:text-primary-700 font-medium"
            >
              ← Create New Trip
            </button>
          </div>

          {/* Day Selector */}
          <div className="flex space-x-2 mt-6 overflow-x-auto">
            {itinerary.days.map((day) => (
              <button
                key={day.id}
                onClick={() => setSelectedDay(day.day_number)}
                className={`px-4 py-2 rounded-lg font-medium whitespace-nowrap transition-colors ${
                  selectedDay === day.day_number
                    ? 'bg-primary-600 text-white'
                    : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                }`}
              >
                Day {day.day_number}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* Main Content */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="grid lg:grid-cols-2 gap-8">
          {/* Map */}
          <div className="lg:sticky lg:top-8 h-[600px]">
            <MapView
              pois={dayPOIs}
              selectedDay={selectedDay}
            />
          </div>

          {/* Day Details */}
          <div className="space-y-6">
            {selectedDayData && (
              <DayCard
                day={selectedDayData}
                onRemoveItem={handleRemoveItem}
              />
            )}

            {/* Export Options */}
            <div className="bg-white rounded-lg shadow-md p-6">
              <h3 className="text-lg font-semibold text-gray-900 mb-4">
                Export Options
              </h3>
              <div className="space-y-2">
                <button className="w-full text-left px-4 py-2 bg-gray-50 hover:bg-gray-100 rounded-lg transition-colors">
                  📱 Export to Google Calendar
                </button>
                <button className="w-full text-left px-4 py-2 bg-gray-50 hover:bg-gray-100 rounded-lg transition-colors">
                  📄 Download as PDF
                </button>
                <button className="w-full text-left px-4 py-2 bg-gray-50 hover:bg-gray-100 rounded-lg transition-colors">
                  🔗 Share Link
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default ItineraryPage;

