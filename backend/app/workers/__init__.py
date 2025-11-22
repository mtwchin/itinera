"""Background workers for async tasks"""
from app.workers.celery_app import celery_app
from app.workers.trip_processor import process_trip_task

__all__ = ["celery_app", "process_trip_task"]

