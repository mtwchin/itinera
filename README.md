# Itinera - AI-Powered Travel Planner

A production-quality MVP that creates personalized multi-day itineraries using TikTok travel content, OpenAI GPT, and Google Maps.

## 🎯 Features

- **AI-Powered Discovery**: Scrapes TikTok for trending travel content
- **Smart POI Extraction**: Uses OpenAI GPT to extract and deduplicate points of interest
- **Intelligent Clustering**: Groups nearby locations for geographically coherent daily plans
- **Interactive Maps**: Real-time Google Maps integration
- **Customizable Itineraries**: Drag-and-drop reordering, add/remove stops
- **Multi-Day Planning**: Automatically spreads activities across requested trip length

## 🏗️ Architecture

```
itinera/
├── backend/          # Python FastAPI backend
│   ├── app/
│   │   ├── api/      # API routes
│   │   ├── core/     # Core config and utilities
│   │   ├── models/   # SQLAlchemy models
│   │   ├── schemas/  # Pydantic schemas
│   │   ├── services/ # Business logic (TikTok, OpenAI, Google Maps)
│   │   └── workers/  # Background job workers
│   └── tests/        # Backend tests
├── frontend/         # React TypeScript frontend
│   └── src/
│       ├── components/
│       ├── services/
│       └── pages/
└── docker/          # Docker configuration
```

## 🚀 Quick Start

### Prerequisites

- Python 3.11+
- Node.js 18+
- Redis (for background jobs)
- PostgreSQL

### Environment Variables

Create `.env` files in `backend/` and `frontend/`:

**backend/.env**
```env
DATABASE_URL=postgresql://user:pass@localhost:5432/itinera
REDIS_URL=redis://localhost:6379
OPENAI_API_KEY=your_openai_key
GOOGLE_MAPS_API_KEY=your_google_maps_key
TIKTOK_API_KEY=your_tiktok_key
```

**frontend/.env**
```env
REACT_APP_API_URL=http://localhost:8000
REACT_APP_GOOGLE_MAPS_API_KEY=your_google_maps_key
```

### Installation

#### Backend
```bash
cd backend
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
pip install -r requirements.txt
alembic upgrade head
uvicorn app.main:app --reload
```

#### Worker (separate terminal)
```bash
cd backend
source venv/bin/activate
celery -A app.workers.celery_app worker --loglevel=info
```

#### Frontend
```bash
cd frontend
npm install
npm start
```

## 🧪 Testing

```bash
cd backend
pytest tests/ -v --cov=app
```

## 📚 API Documentation

Once running, visit:
- Swagger UI: http://localhost:8000/docs
- ReDoc: http://localhost:8000/redoc

## 🔑 Key Components

### Backend Services

1. **TikTok Service** (`services/tiktok_service.py`)
   - Discovers travel content via TikTok API
   - Extracts video captions and metadata

2. **OpenAI Service** (`services/openai_service.py`)
   - Extracts POIs from text using GPT-4
   - Deduplicates and summarizes locations

3. **Google Maps Service** (`services/google_maps_service.py`)
   - Geocodes POIs to lat/lng
   - Fetches place details and photos

4. **Itinerary Generator** (`services/itinerary_service.py`)
   - Clusters POIs using geographic distance
   - Balances food and sights across days
   - Optimizes daily routes

### Frontend Components

- **TripWizard**: Multi-step form for trip creation
- **ItineraryView**: Interactive map + day-by-day lists
- **DayCard**: Drag-and-drop daily schedule
- **MapView**: Google Maps with POI markers

## 🎨 Design Decisions

- **Monorepo**: Simplified deployment and shared types
- **FastAPI**: High performance, async support, auto-generated docs
- **Celery**: Background processing for API-heavy operations
- **SQLAlchemy**: Robust ORM with migration support
- **React + TypeScript**: Type safety and modern UX
- **Tailwind CSS**: Rapid UI development with consistent design

## 📈 Future Enhancements

- [ ] User authentication and saved trips
- [ ] Budget estimation per itinerary
- [ ] Weather integration
- [ ] Social sharing features
- [ ] Mobile app (React Native)
- [ ] Real-time collaboration

## 📄 License

MIT License - See LICENSE file for details

