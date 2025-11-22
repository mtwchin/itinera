import axios from 'axios';

const API_BASE_URL = process.env.REACT_APP_API_URL || 'http://localhost:8000';

const api = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

export interface TripCreate {
  city: string;
  country?: string;
  duration_days: number;
  preference_food_weight: number;
  preference_walking_friendly: number;
  preference_types?: string[];
}

export interface Trip {
  id: number;
  city: string;
  country?: string;
  duration_days: number;
  preference_food_weight: number;
  preference_walking_friendly: number;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  error_message?: string;
  created_at: string;
  updated_at: string;
}

export interface POI {
  id: number;
  name: string;
  description?: string;
  poi_type: string;
  is_food: boolean;
  address?: string;
  latitude?: number;
  longitude?: number;
  rating?: number;
  review_count?: number;
  price_level?: number;
  photo_references?: string;
}

export interface ItineraryItem {
  id: number;
  order_index: number;
  poi: POI;
  suggested_duration_minutes?: number;
  notes?: string;
  distance_to_next_km?: number;
}

export interface ItineraryDay {
  id: number;
  day_number: number;
  title?: string;
  description?: string;
  total_distance_km?: number;
  estimated_duration_minutes?: number;
  items: ItineraryItem[];
}

export interface Itinerary {
  id: number;
  trip_id: number;
  title?: string;
  description?: string;
  total_distance_km?: number;
  total_duration_minutes?: number;
  days: ItineraryDay[];
  created_at: string;
}

export const tripApi = {
  createTrip: async (data: TripCreate): Promise<Trip> => {
    const response = await api.post('/api/trips/', data);
    return response.data;
  },

  getTrip: async (tripId: number): Promise<Trip> => {
    const response = await api.get(`/api/trips/${tripId}`);
    return response.data;
  },

  getTripStatus: async (tripId: number): Promise<any> => {
    const response = await api.get(`/api/trips/${tripId}/status`);
    return response.data;
  },

  listTrips: async (): Promise<Trip[]> => {
    const response = await api.get('/api/trips/');
    return response.data;
  },
};

export const itineraryApi = {
  getItineraryForTrip: async (tripId: number): Promise<Itinerary> => {
    const response = await api.get(`/api/itineraries/trip/${tripId}`);
    return response.data;
  },

  deleteItem: async (itemId: number): Promise<void> => {
    await api.delete(`/api/itineraries/items/${itemId}`);
  },

  reorderItems: async (items: any[]): Promise<void> => {
    await api.put('/api/itineraries/items/reorder', items);
  },
};

export const poiApi = {
  getPOIsForTrip: async (tripId: number): Promise<POI[]> => {
    const response = await api.get(`/api/pois/trip/${tripId}`);
    return response.data;
  },
};

export default api;

