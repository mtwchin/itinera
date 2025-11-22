# Itinera Backend

Python FastAPI backend for the Itinera travel planning application.

## Features

- **FastAPI**: Modern, fast web framework with automatic API documentation
- **SQLAlchemy**: ORM for database interactions
- **Celery**: Background job processing
- **Pydantic**: Data validation and serialization
- **Alembic**: Database migrations

## Project Structure

```
backend/
├── app/
│   ├── api/              # API route handlers
│   │   ├── trips.py
│   │   ├── pois.py
│   │   └── itineraries.py
│   ├── core/             # Core configuration
│   │   ├── config.py
│   │   └── database.py
│   ├── models/           # SQLAlchemy models
│   │   ├── trip.py
│   │   ├── poi.py
│   │   └── itinerary.py
│   ├── schemas/          # Pydantic schemas
│   │   ├── trip.py
│   │   ├── poi.py
│   │   └── itinerary.py
│   ├── services/         # Business logic
│   │   ├── tiktok_service.py
│   │   ├── openai_service.py
│   │   ├── google_maps_service.py
│   │   └── itinerary_service.py
│   ├── workers/          # Celery tasks
│   │   ├── celery_app.py
│   │   └── trip_processor.py
│   └── main.py           # Application entry point
├── tests/                # Test suite
├── alembic/              # Database migrations
├── requirements.txt      # Python dependencies
└── pytest.ini           # Test configuration
```

## Setup

### 1. Create Virtual Environment

```bash
python -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate
```

### 2. Install Dependencies

```bash
pip install -r requirements.txt
```

### 3. Configure Environment

Create `.env` file:

```env
DATABASE_URL=postgresql://user:password@localhost:5432/itinera
REDIS_URL=redis://localhost:6379/0
OPENAI_API_KEY=sk-your-key-here
GOOGLE_MAPS_API_KEY=AIza-your-key-here
TIKTOK_API_KEY=your-key-here
```

### 4. Run Migrations

```bash
alembic upgrade head
```

### 5. Start Server

```bash
uvicorn app.main:app --reload
```

API will be available at http://localhost:8000

### 6. Start Worker (separate terminal)

```bash
celery -A app.workers.celery_app worker --loglevel=info
```

## API Documentation

Once the server is running:
- **Swagger UI**: http://localhost:8000/docs
- **ReDoc**: http://localhost:8000/redoc

## Testing

Run all tests:
```bash
pytest tests/ -v
```

With coverage:
```bash
pytest tests/ -v --cov=app --cov-report=html
```

Run specific test:
```bash
pytest tests/test_api.py::test_create_trip -v
```

## Database Migrations

Create a new migration:
```bash
alembic revision --autogenerate -m "Description"
```

Apply migrations:
```bash
alembic upgrade head
```

Rollback last migration:
```bash
alembic downgrade -1
```

## Code Quality

Format code:
```bash
black app/
```

Check style:
```bash
flake8 app/
```

Type checking:
```bash
mypy app/
```

## Key Services

### TikTokService
Fetches travel content from TikTok based on search queries.

### OpenAIService
Uses GPT-4 to extract POIs from text and generate descriptions.

### GoogleMapsService
Geocodes locations and fetches place details from Google Maps API.

### ItineraryService
Generates optimized multi-day itineraries using clustering algorithms.

## Background Jobs

The trip processing is handled asynchronously using Celery:

1. User creates trip via API
2. Trip record created with `status=pending`
3. Background task queued
4. Worker processes:
   - Fetch TikTok content
   - Extract POIs with OpenAI
   - Geocode with Google Maps
   - Generate itinerary
5. Trip status updated to `completed`

## Troubleshooting

### Database connection errors
- Ensure PostgreSQL is running
- Check DATABASE_URL in .env
- Verify database exists

### Redis connection errors
- Ensure Redis is running: `redis-cli ping`
- Check REDIS_URL in .env

### Import errors
- Activate virtual environment
- Reinstall dependencies: `pip install -r requirements.txt`

### Migration errors
- Check database connection
- Review migration files in alembic/versions/
- Try: `alembic stamp head` then `alembic upgrade head`

## License

MIT

