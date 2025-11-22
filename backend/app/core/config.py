"""Application configuration"""
from typing import List
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings"""
    
    # App Config
    APP_NAME: str = "Itinera"
    DEBUG: bool = True
    VERSION: str = "1.0.0"
    
    # Database
    DATABASE_URL: str = "postgresql://postgres:postgres@localhost:5432/itinera"
    
    # Redis
    REDIS_URL: str = "redis://localhost:6379/0"
    
    # External APIs
    OPENAI_API_KEY: str = ""
    OPENAI_MODEL: str = "gpt-4-turbo-preview"
    GOOGLE_MAPS_API_KEY: str = ""
    TIKTOK_API_KEY: str = ""
    
    # CORS
    CORS_ORIGINS: List[str] = [
        "http://localhost:3000",
        "http://localhost:8000",
    ]
    
    # Celery
    CELERY_BROKER_URL: str = "redis://localhost:6379/0"
    CELERY_RESULT_BACKEND: str = "redis://localhost:6379/0"
    
    # Itinerary Generation
    MAX_POIS_PER_DAY: int = 6
    MIN_POIS_PER_DAY: int = 3
    FOOD_POI_RATIO: float = 0.3  # 30% food, 70% sights
    MAX_DAILY_DISTANCE_KM: float = 15.0
    
    # TikTok Settings
    TIKTOK_MAX_VIDEOS: int = 50
    TIKTOK_MIN_LIKES: int = 1000
    
    model_config = SettingsConfigDict(
        env_file=".env",
        case_sensitive=True,
        extra="ignore"
    )


settings = Settings()

