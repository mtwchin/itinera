# 🚀 React Conversion Guide

## Overview

Converting Itinera from Vanilla JS to React with proper component library integration.

---

## 🎯 Goals

- ✅ Use React with TypeScript
- ✅ Integrate `rc-calendar` for date selection
- ✅ Use React component libraries
- ✅ Integrate unofficial TikTok API for real scraping
- ✅ Maintain all existing features
- ✅ Improve performance and maintainability

---

## 📦 Tech Stack

### Frontend
```
- React 18
- TypeScript
- Vite (build tool)
- rc-calendar (date picker)
- react-google-maps/api (maps)
- react-select (dropdowns)
- framer-motion (animations)
- axios (API calls)
- zustand (state management)
```

### Backend  
```
- Flask → FastAPI
- TikTokApi (unofficial)
- AsyncIO for concurrent requests
```

---

## 🚀 Quick Start

### Step 1: Create React App

```bash
# Create Vite React + TypeScript app
npm create vite@latest frontend -- --template react-ts

cd frontend
npm install

# Install dependencies
npm install rc-calendar moment
npm install @react-google-maps/api
npm install react-select
npm install framer-motion
npm install axios
npm install zustand
npm install @types/react-google-maps
```

### Step 2: Install TikTok API (Backend)

```bash
# In project root
pip install TikTokApi
pip install playwright
python -m playwright install
```

### Step 3: Project Structure

```
Itinera/
├── backend/
│   ├── app.py (FastAPI)
│   ├── services/
│   │   ├── tiktok_scraper.py  # NEW!
│   │   ├── openai_service.py
│   │   └── maps_service.py
│   └── requirements.txt
├── frontend/
│   ├── src/
│   │   ├── components/
│   │   │   ├── DestinationSearch.tsx
│   │   │   ├── DatePicker.tsx      # rc-calendar
│   │   │   ├── AccommodationInput.tsx
│   │   │   ├── PreferencesForm.tsx
│   │   │   ├── ItineraryView.tsx
│   │   │   └── MapView.tsx
│   │   ├── hooks/
│   │   │   ├── useItinerary.ts
│   │   │   └── useGoogleMaps.ts
│   │   ├── store/
│   │   │   └── tripStore.ts       # Zustand
│   │   ├── services/
│   │   │   └── api.ts
│   │   ├── types/
│   │   │   └── index.ts
│   │   ├── App.tsx
│   │   └── main.tsx
│   ├── package.json
│   └── vite.config.ts
└── docker-compose.yml
```

---

## 📝 Step-by-Step Conversion

### Phase 1: Backend - TikTok Integration (Day 1)

#### `backend/services/tiktok_scraper.py`

```python
from TikTokApi import TikTokApi
import asyncio
from typing import List, Dict
import os

class TikTokScraper:
    def __init__(self):
        self.api = None
    
    async def initialize(self):
        """Initialize TikTok API with custom session"""
        ms_token = os.environ.get("TIKTOK_MS_TOKEN", None)
        self.api = TikTokApi()
        await self.api.create_sessions(
            ms_tokens=[ms_token] if ms_token else None,
            num_sessions=1,
            sleep_after=3
        )
    
    async def search_trending_places(
        self, 
        city: str, 
        country: str, 
        max_results: int = 20
    ) -> List[Dict]:
        """
        Search TikTok for trending places in a city
        
        Returns:
            List of places with TikTok metadata
        """
        if not self.api:
            await self.initialize()
        
        # Search queries
        queries = [
            f"{city} {country} travel",
            f"{city} food",
            f"{city} things to do",
            f"best places {city}",
            f"{city} hidden gems"
        ]
        
        all_videos = []
        
        for query in queries:
            try:
                async for video in self.api.hashtag(name=query).videos(count=max_results // len(queries)):
                    video_data = video.as_dict
                    
                    # Extract place information
                    place_info = self._extract_place_from_video(video_data, city, country)
                    if place_info:
                        all_videos.append(place_info)
                        
            except Exception as e:
                print(f"Error searching {query}: {e}")
                continue
        
        # Sort by engagement
        sorted_videos = sorted(
            all_videos, 
            key=lambda x: x['engagement'], 
            reverse=True
        )
        
        return sorted_videos[:max_results]
    
    def _extract_place_from_video(self, video: Dict, city: str, country: str) -> Dict:
        """Extract place information from TikTok video"""
        desc = video.get('desc', '')
        stats = video.get('stats', {})
        
        # Calculate engagement
        engagement = (
            stats.get('playCount', 0) + 
            stats.get('diggCount', 0) * 2 +  # Likes weighted more
            stats.get('shareCount', 0) * 3 +  # Shares weighted most
            stats.get('commentCount', 0)
        )
        
        # Extract hashtags
        hashtags = []
        if 'challenges' in video:
            hashtags = [c.get('title', '') for c in video['challenges']]
        
        # Categorize
        category = self._categorize_from_text(desc, hashtags)
        
        # Extract potential place name (simplified - would use NLP in production)
        place_name = self._extract_place_name(desc, city)
        
        return {
            'name': place_name,
            'type': category,
            'city': city,
            'country': country,
            'description': desc[:200],
            'tiktok_url': f"https://www.tiktok.com/@{video.get('author', {}).get('uniqueId', '')}/video/{video.get('id', '')}",
            'views': stats.get('playCount', 0),
            'likes': stats.get('diggCount', 0),
            'shares': stats.get('shareCount', 0),
            'engagement': engagement,
            'hashtags': hashtags
        }
    
    def _categorize_from_text(self, text: str, hashtags: List[str]) -> str:
        """Categorize place based on text and hashtags"""
        combined = (text + " " + " ".join(hashtags)).lower()
        
        categories = {
            'food': ['food', 'restaurant', 'cafe', 'eat', 'dining', 'foodie'],
            'culture': ['museum', 'art', 'gallery', 'temple', 'church', 'historic'],
            'nature': ['beach', 'park', 'mountain', 'nature', 'hiking', 'outdoor'],
            'shopping': ['shop', 'market', 'mall', 'boutique', 'shopping'],
            'nightlife': ['bar', 'club', 'night', 'party', 'drinks']
        }
        
        for category, keywords in categories.items():
            if any(keyword in combined for keyword in keywords):
                return category
        
        return 'landmark'
    
    def _extract_place_name(self, text: str, city: str) -> str:
        """Extract place name from description (simplified)"""
        # In production, use NER (Named Entity Recognition)
        # For now, extract capitalized phrases
        words = text.split()
        for i, word in enumerate(words):
            if word and word[0].isupper() and i < len(words) - 1:
                next_word = words[i + 1]
                if next_word and next_word[0].isupper():
                    return f"{word} {next_word}"
        
        return f"Popular spot in {city}"


# Usage in FastAPI
scraper = TikTokScraper()

@app.post("/api/tiktok/scrape")
async def scrape_tiktok(data: dict):
    results = await scraper.search_trending_places(
        city=data['city'],
        country=data['country'],
        max_results=20
    )
    return {"success": True, "places": results}
```

---

### Phase 2: Frontend Setup (Day 2-3)

#### `frontend/vite.config.ts`

```typescript
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:5000',
        changeOrigin: true
      }
    }
  }
})
```

#### `frontend/src/types/index.ts`

```typescript
export interface Destination {
  city: string;
  country: string;
  lat: number;
  lng: number;
}

export interface Accommodation {
  address: string;
  lat: number;
  lng: number;
  link: string;
}

export interface TripData {
  destination: Destination;
  accommodation: Accommodation;
  arrivalDate: Date;
  departureDate: Date;
  budget: 'Budget' | 'Medium' | 'Luxury';
  foodPreferences?: string;
  mustDo: string[];
}

export interface Activity {
  time: string;
  name: string;
  type: string;
  duration: string;
  description: string;
  address: string;
  coordinates: { lat: number; lng: number };
}

export interface DayItinerary {
  day: number;
  theme: string;
  activities: Activity[];
}

export interface Itinerary {
  itinerary: DayItinerary[];
  tips: string[];
  accommodationInfo: {
    morningStart: string;
    eveningReturn: string;
    transportationTips: string;
  };
  estimatedBudget: string;
}
```

---

### Phase 3: State Management (Day 3)

#### `frontend/src/store/tripStore.ts`

```typescript
import { create } from 'zustand';
import { TripData, Itinerary } from '../types';

interface TripStore {
  tripData: Partial<TripData>;
  itinerary: Itinerary | null;
  currentDay: number;
  isLoading: boolean;
  error: string | null;
  
  setTripData: (data: Partial<TripData>) => void;
  setItinerary: (itinerary: Itinerary) => void;
  setCurrentDay: (day: number) => void;
  setLoading: (loading: boolean) => void;
  setError: (error: string | null) => void;
  reset: () => void;
}

export const useTripStore = create<TripStore>((set) => ({
  tripData: {},
  itinerary: null,
  currentDay: 1,
  isLoading: false,
  error: null,
  
  setTripData: (data) => set((state) => ({
    tripData: { ...state.tripData, ...data }
  })),
  
  setItinerary: (itinerary) => set({ itinerary }),
  setCurrentDay: (day) => set({ currentDay: day }),
  setLoading: (loading) => set({ isLoading: loading }),
  setError: (error) => set({ error }),
  
  reset: () => set({
    tripData: {},
    itinerary: null,
    currentDay: 1,
    isLoading: false,
    error: null
  })
}));
```

---

### Phase 4: React Components (Day 4-7)

#### `frontend/src/components/DatePicker.tsx`

```typescript
import React from 'react';
import Calendar from 'rc-calendar';
import 'rc-calendar/assets/index.css';
import moment, { Moment } from 'moment';

interface DatePickerProps {
  value?: Date;
  onChange: (date: Date) => void;
  label: string;
  minDate?: Date;
}

export const DatePicker: React.FC<DatePickerProps> = ({
  value,
  onChange,
  label,
  minDate
}) => {
  const [open, setOpen] = React.useState(false);
  
  const handleChange = (date: Moment) => {
    onChange(date.toDate());
    setOpen(false);
  };
  
  return (
    <div className="date-picker">
      <label>{label}</label>
      <div className="date-input" onClick={() => setOpen(true)}>
        {value ? moment(value).format('MMM DD, YYYY h:mm A') : 'Select date'}
      </div>
      
      {open && (
        <div className="calendar-overlay" onClick={() => setOpen(false)}>
          <div className="calendar-wrapper" onClick={(e) => e.stopPropagation()}>
            <Calendar
              value={moment(value)}
              onChange={handleChange}
              showDateInput={false}
              showToday
              disabledDate={(current) => {
                if (!minDate) return false;
                return current && current < moment(minDate).startOf('day');
              }}
            />
          </div>
        </div>
      )}
    </div>
  );
};
```

#### `frontend/src/components/TripForm.tsx`

```typescript
import React from 'react';
import { DatePicker } from './DatePicker';
import { DestinationSearch } from './DestinationSearch';
import { AccommodationInput } from './AccommodationInput';
import { useTripStore } from '../store/tripStore';
import { motion } from 'framer-motion';

export const TripForm: React.FC = () => {
  const { tripData, setTripData, setLoading } = useTripStore();
  const [mustDoList, setMustDoList] = React.useState<string[]>(['']);
  
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setLoading(true);
    
    try {
      // API call to generate itinerary
      const response = await fetch('/api/generate-itinerary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...tripData,
          mustDo: mustDoList.filter(item => item.trim())
        })
      });
      
      const data = await response.json();
      // Handle response
    } catch (error) {
      console.error(error);
    } finally {
      setLoading(false);
    }
  };
  
  return (
    <motion.form
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      className="trip-form"
      onSubmit={handleSubmit}
    >
      <div className="logo">
        <h1>Itinera</h1>
        <p>AI-powered travel planning from TikTok trends</p>
      </div>
      
      <DestinationSearch />
      
      <AccommodationInput />
      
      <div className="date-section">
        <h2>Trip Dates</h2>
        <div className="date-grid">
          <DatePicker
            label="Arrival"
            value={tripData.arrivalDate}
            onChange={(date) => setTripData({ arrivalDate: date })}
          />
          <DatePicker
            label="Departure"
            value={tripData.departureDate}
            onChange={(date) => setTripData({ departureDate: date })}
            minDate={tripData.arrivalDate}
          />
        </div>
      </div>
      
      {/* More form fields... */}
      
      <button type="submit" className="btn-primary">
        Generate Itinerary
      </button>
    </motion.form>
  );
};
```

---

## 🔧 Integration Steps

### 1. Install All Dependencies

```bash
cd frontend
npm install rc-calendar moment
npm install @react-google-maps/api
npm install react-select framer-motion axios zustand
npm install @types/node
```

### 2. Update Backend

```bash
pip install TikTokApi playwright fastapi uvicorn
python -m playwright install
```

### 3. Run Both Servers

```bash
# Terminal 1 - Backend
uvicorn app:app --reload --port 5000

# Terminal 2 - Frontend
cd frontend
npm run dev
```

---

## 📚 Component Libraries Used

From [awesome-react-components](https://github.com/brillout/awesome-react-components):

1. **rc-calendar** - Date picker ✅
2. **react-select** - Dropdown menus
3. **framer-motion** - Animations
4. **react-google-maps/api** - Google Maps
5. **react-hot-toast** - Notifications
6. **react-icons** - Icon library

---

## 🎯 Migration Checklist

- [ ] Create React app with Vite
- [ ] Install all dependencies
- [ ] Set up TypeScript types
- [ ] Create Zustand store
- [ ] Build DatePicker with rc-calendar
- [ ] Build DestinationSearch component
- [ ] Build AccommodationInput component
- [ ] Build ItineraryView component
- [ ] Build MapView component
- [ ] Integrate TikTok API backend
- [ ] Connect frontend to backend
- [ ] Add loading states
- [ ] Add error handling
- [ ] Style with Tailwind or CSS modules
- [ ] Test all features
- [ ] Deploy

---

## 🚀 Next Steps

1. Run the setup commands above
2. Start with the backend TikTok integration
3. Build React components one by one
4. Connect everything together
5. Test and refine

**Estimated Time**: 2-3 weeks for full conversion

**Benefit**: Modern, maintainable, scalable React app with real TikTok data! 🎉

