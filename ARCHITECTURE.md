# Itinera Architecture Documentation

## Overview

Itinera is a full-stack AI-powered travel planning application that generates multi-day itineraries using TikTok content, OpenAI GPT, and Google Maps APIs.

## System Architecture

```
┌─────────────────┐
│   React Frontend│
│   (TypeScript)  │
└────────┬────────┘
         │ HTTP/REST
         ▼
┌─────────────────────────┐
│   FastAPI Backend       │
│   ┌─────────────────┐   │
│   │  API Routes     │   │
│   └────────┬────────┘   │
│            │            │
│   ┌────────▼────────┐   │
│   │  Services Layer │   │
│   │  - TikTok       │   │
│   │  - OpenAI       │   │
│   │  - Google Maps  │   │
│   │  - Itinerary    │   │
│   └─────────────────┘   │
│                         │
│   ┌─────────────────┐   │
│   │  Data Models    │   │
│   │  (SQLAlchemy)   │   │
│   └────────┬────────┘   │
└────────────┼────────────┘
             │
    ┌────────▼────────┐
    │   PostgreSQL    │
    └─────────────────┘

┌──────────────────────┐
│   Celery Worker      │
│   (Background Jobs)  │
└──────────┬───────────┘
           │
    ┌──────▼──────┐
    │    Redis    │
    └─────────────┘
```

## Backend Architecture

### Layer Separation

1. **API Layer** (`app/api/`)
   - FastAPI route handlers
   - Request validation with Pydantic
   - Response serialization
   - HTTP status codes

2. **Service Layer** (`app/services/`)
   - Business logic
   - External API integration
   - Data transformation
   - Algorithm implementation

3. **Data Layer** (`app/models/`)
   - SQLAlchemy ORM models
   - Database schema
   - Relationships and constraints

4. **Worker Layer** (`app/workers/`)
   - Celery task definitions
   - Background processing
   - Long-running operations

### Key Services

#### TikTokService
- Searches TikTok for travel content
- Filters by engagement metrics
- Returns video captions and metadata
- **Note**: Currently uses mock data for MVP; production would integrate official TikTok API

#### OpenAIService
- Extracts POIs from text using GPT-4
- Deduplicates similar locations
- Generates summaries and descriptions
- Categorizes POI types

#### GoogleMapsService
- Geocodes POI names to coordinates
- Fetches place details (rating, photos, hours)
- Calculates distances between points
- Optimizes routes

#### ItineraryService
- Clusters POIs using K-means algorithm
- Balances food vs sights per day
- Optimizes daily routes with nearest neighbor
- Calculates distances and durations
- Creates database records

### Database Schema

```sql
trips
├── id (PK)
├── city
├── country
├── duration_days
├── preference_food_weight
├── preference_walking_friendly
├── status (pending/processing/completed/failed)
└── celery_task_id

pois
├── id (PK)
├── trip_id (FK)
├── name
├── description
├── poi_type
├── is_food
├── latitude, longitude
├── google_place_id
└── rating, review_count, etc.

itineraries
├── id (PK)
├── trip_id (FK)
├── title, description
└── total_distance_km

itinerary_days
├── id (PK)
├── itinerary_id (FK)
├── day_number
├── title
└── total_distance_km

itinerary_items
├── id (PK)
├── day_id (FK)
├── poi_id (FK)
├── order_index
├── suggested_duration_minutes
└── distance_to_next_km
```

## Frontend Architecture

### Component Hierarchy

```
App
├── Header
└── Router
    ├── HomePage
    │   ├── TripWizard
    │   └── Features
    └── ItineraryPage
        ├── MapView
        ├── DayCard
        │   └── POICard[]
        └── LoadingSpinner
```

### State Management

- **Local State**: React useState for component-level state
- **API Integration**: Axios with TypeScript interfaces
- **Polling**: useEffect with intervals for background job status

### Key Components

#### TripWizard
- Multi-step form with sliders
- Real-time validation
- Submits to `/api/trips/`
- Navigates to itinerary page

#### MapView
- Google Maps JavaScript API
- Custom markers (color-coded by type)
- Auto-fit bounds to show all POIs
- Click handlers for POI selection

#### ItineraryPage
- Polls trip status every 3 seconds
- Shows loading spinner during processing
- Displays completed itinerary
- Allows removing items

## Data Flow

### Trip Creation Flow

1. User fills out TripWizard form
2. Frontend POST to `/api/trips/`
3. Backend creates Trip record with `status=pending`
4. Backend queues Celery task
5. Frontend navigates to `/itinerary/{trip_id}`
6. Frontend polls `/api/trips/{trip_id}/status`

### Background Processing Flow

1. Celery worker picks up task
2. Update Trip `status=processing`
3. Fetch TikTok videos
4. Extract POIs with OpenAI
5. Geocode POIs with Google Maps
6. Generate itinerary with clustering
7. Save all to database
8. Update Trip `status=completed`

### Itinerary Display Flow

1. Frontend detects `status=completed`
2. Fetch itinerary from `/api/itineraries/trip/{trip_id}`
3. Load Google Maps
4. Display day-by-day cards
5. User can remove items or reorder

## Algorithm Details

### Geographic Clustering

**K-means Clustering**
- Input: List of POI coordinates
- Output: N clusters (one per day)
- Features: Latitude, longitude
- Optimization: Balances cluster sizes

**Nearest Neighbor Route Optimization**
- Input: Unordered POIs within a day
- Output: Ordered route
- Algorithm: Greedy nearest neighbor
- Result: Minimizes travel distance

### POI Balancing

- Target: 30% food POIs, 70% sights
- Adjustable based on user preference
- Ensures each day has variety

## Scalability Considerations

### Current MVP

- Single worker process
- In-memory Python execution
- SQLite for development
- Polling for status updates

### Production Enhancements

1. **Horizontal Scaling**
   - Multiple Celery workers
   - Load balancer for FastAPI
   - Redis cluster for jobs

2. **Caching**
   - Redis cache for TikTok results
   - Cache geocoded places
   - Cache generated itineraries

3. **Database**
   - PostgreSQL with read replicas
   - Connection pooling
   - Database indexes on foreign keys

4. **Real-time Updates**
   - WebSockets for status updates
   - Server-Sent Events (SSE)
   - Remove polling

5. **CDN & Assets**
   - Static frontend on CDN
   - Google Maps photos via CDN
   - Image optimization

## Security Considerations

1. **API Keys**
   - Environment variables
   - Never commit to version control
   - Rotate regularly

2. **Rate Limiting**
   - Implement per-IP rate limits
   - Throttle expensive operations
   - Queue job limits

3. **Input Validation**
   - Pydantic schemas
   - SQL injection prevention (ORM)
   - XSS prevention (React escaping)

4. **CORS**
   - Whitelist frontend origin
   - No wildcard in production

## Testing Strategy

### Backend Tests

- Unit tests for services
- Integration tests for API endpoints
- Mock external APIs (TikTok, OpenAI, Google)
- Database fixtures

### Frontend Tests

- Component unit tests with React Testing Library
- Integration tests for user flows
- E2E tests with Playwright (future)

## Deployment

### Development

```bash
# Backend
cd backend
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload

# Worker
celery -A app.workers.celery_app worker --loglevel=info

# Frontend
cd frontend
npm install
npm start
```

### Production

**Backend Options:**
- Docker containers (Kubernetes, ECS)
- Platform-as-a-Service (Heroku, Railway, Render)
- Traditional VPS (DigitalOcean, Linode)

**Frontend Options:**
- Vercel, Netlify (static hosting)
- S3 + CloudFront
- Same server as backend

**Database:**
- Managed PostgreSQL (RDS, Digital Ocean, Supabase)

**Redis:**
- Managed Redis (ElastiCache, Redis Cloud)

## Monitoring & Observability

### Metrics to Track

- API response times
- Background job duration
- External API failures
- Database query performance
- User conversion rate (trips created → completed)

### Logging

- Structured JSON logs
- Log levels: DEBUG, INFO, WARNING, ERROR
- External API calls logged
- User actions tracked

### Error Tracking

- Sentry or similar for exception tracking
- Alert on critical failures
- Monitor background job failures

## Future Enhancements

1. **User Accounts**
   - Save trips to account
   - Share itineraries
   - Collaborate on planning

2. **Budget Tracking**
   - Estimate costs from price_level
   - Set budget constraints
   - Filter by price

3. **Time-of-Day Optimization**
   - Consider opening hours
   - Suggest breakfast/lunch/dinner times
   - Avoid closed attractions

4. **Weather Integration**
   - Check forecast for trip dates
   - Suggest indoor/outdoor balance
   - Warn about extreme weather

5. **Real-time Collaboration**
   - Multiple users edit itinerary
   - WebSocket sync
   - Conflict resolution

6. **Mobile App**
   - React Native
   - Offline access
   - GPS navigation

7. **Social Features**
   - Share on social media
   - Comment on POIs
   - Community ratings

