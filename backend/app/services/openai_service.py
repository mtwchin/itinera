"""OpenAI integration service for POI extraction and summarization"""
import logging
import json
from typing import List, Dict, Optional
from openai import OpenAI
from app.core.config import settings

logger = logging.getLogger(__name__)


class OpenAIService:
    """Service for using OpenAI GPT to extract and process POIs"""
    
    def __init__(self):
        self.client = OpenAI(api_key=settings.OPENAI_API_KEY)
        self.model = settings.OPENAI_MODEL
    
    async def extract_pois_from_videos(self, video_captions: List[str], city: str) -> List[Dict]:
        """
        Extract points of interest from TikTok video captions
        
        Args:
            video_captions: List of video captions/descriptions
            city: City name for context
            
        Returns:
            List of extracted POI dictionaries with names, types, and descriptions
        """
        try:
            # Combine captions for processing
            combined_text = "\n\n".join([
                f"Video {i+1}: {caption}" 
                for i, caption in enumerate(video_captions)
            ])
            
            prompt = f"""You are analyzing TikTok videos about travel in {city}. 
Extract all points of interest (POIs) mentioned in these videos.

For each POI, provide:
1. name: The exact name of the place (e.g., "Golden Palace Restaurant", "Central Park")
2. type: Category (restaurant, cafe, bar, museum, park, landmark, attraction, shopping, entertainment)
3. description: A brief, engaging 1-2 sentence summary
4. is_food: true if it's a food/drink establishment, false otherwise

Videos:
{combined_text}

Return ONLY a valid JSON array of POIs. No other text.
Format:
[
  {{
    "name": "Place Name",
    "type": "restaurant",
    "description": "Brief description",
    "is_food": true
  }}
]

Deduplicate similar places (e.g., "Golden Palace" and "the Golden Palace restaurant" are the same).
Extract 15-30 POIs total."""

            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": "You are a travel expert assistant that extracts structured data from travel content."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.3,
                max_tokens=2000
            )
            
            content = response.choices[0].message.content.strip()
            
            # Parse JSON response
            try:
                pois = json.loads(content)
                logger.info(f"Extracted {len(pois)} POIs from {len(video_captions)} videos")
                return pois
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse OpenAI response as JSON: {str(e)}")
                logger.debug(f"Response content: {content}")
                return []
                
        except Exception as e:
            logger.error(f"Error extracting POIs with OpenAI: {str(e)}")
            return []
    
    async def enhance_poi_description(self, poi_name: str, city: str, existing_description: Optional[str] = None) -> str:
        """
        Enhance or generate a description for a POI
        
        Args:
            poi_name: Name of the POI
            city: City where POI is located
            existing_description: Optional existing description to enhance
            
        Returns:
            Enhanced description
        """
        try:
            if existing_description:
                prompt = f"Improve this description of {poi_name} in {city}: '{existing_description}'. Make it more engaging and concise (2-3 sentences max)."
            else:
                prompt = f"Write a brief, engaging 2-3 sentence description of {poi_name} in {city} for a travel itinerary."
            
            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": "You are a travel writer creating engaging, concise descriptions."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.7,
                max_tokens=150
            )
            
            return response.choices[0].message.content.strip()
            
        except Exception as e:
            logger.error(f"Error enhancing description: {str(e)}")
            return existing_description or f"A popular destination in {city}"
    
    async def categorize_poi(self, poi_name: str, description: str) -> tuple[str, bool]:
        """
        Determine the category and food status of a POI
        
        Args:
            poi_name: Name of the POI
            description: Description of the POI
            
        Returns:
            Tuple of (category, is_food)
        """
        try:
            prompt = f"""Categorize this place:
Name: {poi_name}
Description: {description}

Return ONLY a JSON object:
{{
  "category": "restaurant|cafe|bar|museum|park|landmark|attraction|shopping|entertainment",
  "is_food": true or false
}}"""

            response = self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": "You categorize places for travel itineraries."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.1,
                max_tokens=50
            )
            
            result = json.loads(response.choices[0].message.content.strip())
            return result.get("category", "attraction"), result.get("is_food", False)
            
        except Exception as e:
            logger.error(f"Error categorizing POI: {str(e)}")
            return "attraction", False

