import React, { useEffect, useRef, useState } from 'react';
import { POI } from '../services/api';

interface MapViewProps {
  pois: POI[];
  selectedDay?: number;
  onPOIClick?: (poi: POI) => void;
}

const MapView: React.FC<MapViewProps> = ({ pois, selectedDay, onPOIClick }) => {
  const mapRef = useRef<HTMLDivElement>(null);
  const [map, setMap] = useState<google.maps.Map | null>(null);
  const [markers, setMarkers] = useState<google.maps.Marker[]>([]);

  // Initialize map
  useEffect(() => {
    if (!mapRef.current || map) return;

    const newMap = new google.maps.Map(mapRef.current, {
      zoom: 13,
      center: { lat: 48.8566, lng: 2.3522 }, // Default to Paris
      mapTypeControl: false,
      streetViewControl: false,
      fullscreenControl: true,
    });

    setMap(newMap);
  }, [map]);

  // Update markers when POIs change
  useEffect(() => {
    if (!map) return;

    // Clear existing markers
    markers.forEach((marker) => marker.setMap(null));

    // Filter POIs based on selected day
    const filteredPOIs = pois.filter((poi) => poi.latitude && poi.longitude);

    if (filteredPOIs.length === 0) return;

    // Create new markers
    const newMarkers = filteredPOIs.map((poi, index) => {
      const marker = new google.maps.Marker({
        position: { lat: poi.latitude!, lng: poi.longitude! },
        map: map,
        title: poi.name,
        label: {
          text: String(index + 1),
          color: 'white',
          fontWeight: 'bold',
        },
        icon: {
          path: google.maps.SymbolPath.CIRCLE,
          scale: 12,
          fillColor: poi.is_food ? '#f97316' : '#0ea5e9',
          fillOpacity: 1,
          strokeColor: 'white',
          strokeWeight: 2,
        },
      });

      // Add click listener
      marker.addListener('click', () => {
        if (onPOIClick) {
          onPOIClick(poi);
        }
      });

      return marker;
    });

    setMarkers(newMarkers);

    // Fit bounds to show all markers
    const bounds = new google.maps.LatLngBounds();
    filteredPOIs.forEach((poi) => {
      bounds.extend({ lat: poi.latitude!, lng: poi.longitude! });
    });
    map.fitBounds(bounds);
  }, [map, pois, selectedDay]);

  return (
    <div className="relative w-full h-full">
      <div ref={mapRef} className="w-full h-full rounded-lg" />
      
      {/* Legend */}
      <div className="absolute bottom-4 left-4 bg-white p-3 rounded-lg shadow-lg">
        <div className="flex items-center space-x-4 text-sm">
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 rounded-full bg-primary-500"></div>
            <span>Sights</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 rounded-full bg-orange-500"></div>
            <span>Food</span>
          </div>
        </div>
      </div>
    </div>
  );
};

export default MapView;

