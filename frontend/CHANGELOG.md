# Itinera Frontend - Changelog

## Latest Updates

### Interactive Map Background (Current)
- **Full-screen background map**: The entire background is now an interactive world map
- **Click to select destination**: Users can click anywhere on the map to choose their destination city
- **Floating form overlay**: The form floats over the map with a frosted glass effect
- **Auto-geocoding**: Clicked locations are automatically converted to city names
- **Visual marker**: A marker appears on the map when a destination is selected
- **Dual input methods**: Users can either click the map OR use the search box with autocomplete

### Recent UI/UX Improvements
- ✅ Removed all emojis and emoticons for a cleaner, professional look
- ✅ Added wake-up time preference input
- ✅ Google Places autocomplete for city search
- ✅ Auto-set departure date to 3 days after arrival (same month)
- ✅ Google Maps export function with route lines for each day
- ✅ Improved form layout with preferences grid
- ✅ Semi-transparent frosted glass effect on form
- ✅ Smooth scrollbar styling
- ✅ Better mobile responsiveness

### Technical Features
- **Google Maps JavaScript API**: For map rendering and interaction
- **Google Places API**: For city autocomplete suggestions
- **Reverse Geocoding**: Converts map clicks to city names
- **Custom map styling**: Minimalist map design with reduced POI clutter
- **Backdrop blur effects**: Modern glass morphism design
- **Responsive overlays**: Form adapts to different screen sizes

### API Integration
- **Backend**: Flask server at `http://localhost:5000`
- **Frontend**: React + Vite at `http://localhost:5173`
- **Proxy**: Vite proxies API calls to the Flask backend
- **Required APIs**:
  - OpenAI API (for itinerary generation)
  - Google Maps API (for geocoding and map features)
  - TikTok API (for trending location data)

### Setup Requirements
1. Add `VITE_GOOGLE_MAPS_KEY` to `frontend/.env`
2. Enable the following in Google Cloud Console:
   - Maps JavaScript API
   - Places API
   - Geocoding API
3. Run backend: `python app.py` (port 5000)
4. Run frontend: `cd frontend && npm run dev` (port 5173)

### Browser Compatibility
- Chrome/Edge: ✅ Full support
- Firefox: ✅ Full support
- Safari: ✅ Full support (with webkit prefixes)
- Mobile: ✅ Responsive design

### Known Limitations
- Map clicks require a valid Google Maps API key
- Autocomplete suggestions limited to cities only
- Some remote areas may not reverse geocode to a city name

### Next Steps
- Consider adding map type controls (satellite, terrain, etc.)
- Add loading spinner for reverse geocoding
- Add toast notifications for user feedback
- Implement map bounds restriction to land areas only
- Add popular cities as quick-select buttons

