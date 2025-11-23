# Frontend Setup Instructions

## Google Maps API Key Setup

To enable the interactive map background and autocomplete features:

1. Create a `.env` file in the `frontend` directory
2. Add your Google Maps API key:

```
VITE_GOOGLE_MAPS_KEY=your_actual_google_maps_api_key
```

3. Make sure the following APIs are enabled in your Google Cloud Console:
   - **Maps JavaScript API** (for the background map)
   - **Places API** (for city autocomplete)
   - **Geocoding API** (for reverse geocoding clicked locations)

## Running the Frontend

```bash
cd frontend
npm install
npm run dev
```

The frontend will run on `http://localhost:5173` by default.

## Features

### Interactive Map Background 🗺️
- **Full-screen world map**: The entire background is an interactive map
- **Click to select**: Click anywhere on the map to choose your destination
- **Auto-geocoding**: Clicked locations automatically convert to city names
- **Visual markers**: A pin appears on the map when you select a location
- **Dual input**: Use the map OR the search box - whichever you prefer

### City Autocomplete
- Type in the "Where are you going?" box
- City suggestions appear automatically using Google Places API
- Click a suggestion to auto-fill the destination
- Map automatically centers on the selected city

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

## Design Features

### Frosted Glass Effect
- Form overlays the map with a semi-transparent frosted glass effect
- Modern glass morphism design
- Smooth backdrop blur for better readability

### Responsive Design
- Works on desktop and mobile
- Form adapts to different screen sizes
- Smooth scrolling with custom scrollbar styling

### Visual Feedback
- Map markers show selected locations
- Automatic map centering on selection
- Smooth transitions and hover effects

