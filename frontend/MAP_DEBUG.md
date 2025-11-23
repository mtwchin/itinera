# Map Debugging Guide

## If the map doesn't show up, check these:

### 1. Check Browser Console
Open DevTools (F12) and look for errors:
- `Failed to load Google Maps script` - API key issue
- `InvalidKeyMapError` - Wrong or restricted API key
- Network errors - Check internet connection

### 2. Verify API Key Setup
```bash
# Check if .env file exists
ls frontend/.env

# Contents should be:
VITE_GOOGLE_MAPS_KEY=your_actual_key_here
```

### 3. Google Cloud Console Checklist
1. Go to: https://console.cloud.google.com/
2. Enable these APIs:
   - ✅ Maps JavaScript API
   - ✅ Places API  
   - ✅ Geocoding API
3. Check API key restrictions:
   - If restricted, add `http://localhost:5173` to allowed URLs

### 4. Restart Everything
```bash
# Stop both servers (Ctrl+C)

# Restart backend
python app.py

# Restart frontend (in new terminal)
cd frontend
npm run dev
```

### 5. Check Map Element
In browser console, type:
```javascript
document.getElementById('background-map')
```
Should return an HTML element (not null).

### 6. Check if Google Maps Loaded
In browser console, type:
```javascript
window.google?.maps
```
Should return an object (not undefined).

### 7. Manual Test
Add this to browser console:
```javascript
const mapElement = document.getElementById('background-map');
if (mapElement && window.google?.maps) {
  new window.google.maps.Map(mapElement, {
    center: { lat: 0, lng: 0 },
    zoom: 2
  });
  console.log('Map created successfully!');
}
```

## Common Issues & Fixes

### "Map doesn't show up"
- **Cause**: API key not loaded or invalid
- **Fix**: Check `.env` file has `VITE_GOOGLE_MAPS_KEY=...`

### "Map shows but is gray"
- **Cause**: APIs not enabled in Google Cloud
- **Fix**: Enable Maps JavaScript API

### "Map doesn't respond to clicks"
- **Cause**: Pointer events blocked
- **Fix**: Already handled in CSS with `pointer-events: none` on overlay

### "RefererNotAllowedMapError"
- **Cause**: API key restricted to wrong URLs
- **Fix**: Add `http://localhost:5173` to allowed URLs in Google Cloud Console

## Environment Variables

The key MUST start with `VITE_` to be accessible in the React app:
```
✅ VITE_GOOGLE_MAPS_KEY=abc123...
❌ GOOGLE_MAPS_KEY=abc123...  (won't work!)
```

## Test URLs
- Frontend: http://localhost:5173
- Backend: http://localhost:5000
- Backend API test: http://localhost:5000/api/config

## Still Not Working?

1. Check backend is running on port 5000
2. Check frontend is running on port 5173
3. Clear browser cache (Ctrl+Shift+Delete)
4. Try in incognito/private window
5. Check browser console for specific error messages

