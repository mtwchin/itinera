# Frontend Setup Instructions

## Google Maps API Key Setup

To enable Google Places Autocomplete and map features:

1. Create a `.env` file in the `frontend` directory
2. Add your Google Maps API key:

```
VITE_GOOGLE_MAPS_KEY=your_actual_google_maps_api_key
```

3. Make sure the following APIs are enabled in your Google Cloud Console:
   - Maps JavaScript API
   - Places API
   - Geocoding API

## Running the Frontend

```bash
cd frontend
npm install
npm run dev
```

The frontend will run on `http://localhost:5173` by default.

## Features

### City Autocomplete
- Type in the "Where are you going?" box
- City suggestions will appear automatically using Google Places API
- Click a suggestion to auto-fill the destination

### Map Selection (Coming Soon)
- Click "Select on map" button to choose a destination visually
- Interactive map integration is in development

### Wake Up Time
- Set your preferred wake up time
- The itinerary will be scheduled starting from this time

### Auto Date Setting
- When you select an arrival date, the departure date automatically sets to 3 days later in the same month
- You can manually adjust the departure date as needed

### Google Maps Export
- After generating an itinerary, click "Export Day X to Google Maps"
- Opens Google Maps with the day's route
- Shows all locations in order with directions

