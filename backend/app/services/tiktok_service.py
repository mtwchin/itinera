"""TikTok integration service for discovering travel content"""
import logging
from typing import List, Dict, Optional
import requests
from app.core.config import settings

logger = logging.getLogger(__name__)


class TikTokService:
    """Service for fetching TikTok travel content"""
    
    def __init__(self):
        self.api_key = settings.TIKTOK_API_KEY
        self.max_videos = settings.TIKTOK_MAX_VIDEOS
        self.min_likes = settings.TIKTOK_MIN_LIKES
    
    async def search_travel_content(self, city: str, query_type: str = "things to do") -> List[Dict]:
        """
        Search TikTok for travel content about a city
        
        Args:
            city: City name to search for
            query_type: Type of query (e.g., "things to do", "food", "restaurants")
            
        Returns:
            List of video metadata dictionaries
        """
        try:
            search_query = f"Best {query_type} in {city}"
            logger.info(f"Searching TikTok for: {search_query}")
            
            # NOTE: TikTok's official API requires OAuth and has limitations
            # For MVP, we'll use a simplified approach that can be enhanced
            # In production, consider using:
            # 1. Official TikTok API with proper OAuth
            # 2. Third-party APIs like RapidAPI's TikTok endpoints
            # 3. Web scraping with TikTokApi library (requires browser automation)
            
            videos = await self._fetch_videos(search_query)
            
            # Filter by engagement metrics
            filtered_videos = [
                v for v in videos 
                if v.get("likes", 0) >= self.min_likes
            ]
            
            logger.info(f"Found {len(filtered_videos)} qualifying videos for '{search_query}'")
            return filtered_videos[:self.max_videos]
            
        except Exception as e:
            logger.error(f"Error fetching TikTok content: {str(e)}")
            return []
    
    async def _fetch_videos(self, query: str) -> List[Dict]:
        """
        Fetch videos from TikTok API
        
        For MVP demonstration, this returns mock data.
        In production, implement actual TikTok API integration.
        """
        # Mock data for demonstration
        # In production, replace with actual API calls
        mock_videos = [
            {
                "id": f"mock_video_{i}",
                "text": self._generate_mock_caption(query, i),
                "likes": 5000 + (i * 1000),
                "views": 50000 + (i * 10000),
                "author": f"travel_creator_{i}",
                "created_at": "2024-01-15T00:00:00Z"
            }
            for i in range(20)
        ]
        
        logger.warning("Using mock TikTok data for demonstration. Implement actual API integration for production.")
        return mock_videos
    
    def _generate_mock_caption(self, query: str, index: int) -> str:
        """Generate mock caption for demonstration"""
        city = query.split(" in ")[-1] if " in " in query else "the city"
        
        mock_captions = [
            f"Just discovered the BEST hidden gem in {city}! The Golden Palace restaurant is absolutely amazing. Try their signature dish! 🍜 #travel #foodie",
            f"Top 5 things you MUST do in {city}: 1) Visit the Historic Museum 2) Walk through Central Park 3) Try local street food at Night Market 4) See the Cathedral 5) Sunset at Harbor Point 🌆",
            f"This local cafe in {city} is incredible! The Cozy Corner Coffee has the best pastries and amazing atmosphere ☕️ #cafehop",
            f"Don't miss the Art Gallery when you're in {city}. The contemporary exhibits are mind-blowing! 🎨 #art",
            f"Found the perfect lunch spot! The Garden Bistro in downtown {city} has amazing sandwiches and the cutest outdoor seating 🥗",
            f"The Riverside Walk in {city} is perfect for evening strolls. Best views at sunset! 🌅 #travel",
            f"You HAVE to visit the Local Market in {city}. So much authentic food and crafts! 🛍️",
            f"This rooftop bar (Sky Lounge) has the BEST views of {city}! Great cocktails too 🍹 #nightlife",
            f"The Botanical Gardens in {city} are stunning! Perfect for a peaceful afternoon 🌺 #nature",
            f"Best pizza I've ever had at Mario's Pizzeria in {city}! The wood-fired oven makes all the difference 🍕",
        ]
        
        return mock_captions[index % len(mock_captions)]
    
    async def get_video_details(self, video_id: str) -> Optional[Dict]:
        """Get detailed information about a specific video"""
        # In production, implement actual API call
        return {
            "id": video_id,
            "text": "Video caption",
            "likes": 10000,
            "views": 100000,
            "author": "travel_creator"
        }

