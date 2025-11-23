"""
TikTok Scraper Service
Uses unofficial TikTok API to fetch trending travel content
"""
from TikTokApi import TikTokApi
import asyncio
from typing import List, Dict, Optional
import os
import re


class TikTokScraper:
    def __init__(self):
        self.api = None
        self._initialized = False
    
    async def initialize(self):
        """Initialize TikTok API with custom session"""
        if self._initialized:
            return
        
        ms_token = os.environ.get("TIKTOK_MS_TOKEN", None)
        self.api = TikTokApi()
        
        try:
            await self.api.create_sessions(
                ms_tokens=[ms_token] if ms_token else None,
                num_sessions=1,
                sleep_after=3
            )
            self._initialized = True
            print("✅ TikTok API initialized successfully")
        except Exception as e:
            print(f"❌ TikTok API initialization failed: {e}")
            print("   Will use fallback simulated data")
    
    async def search_trending_places(
        self, 
        city: str, 
        country: str, 
        max_results: int = 20
    ) -> List[Dict]:
        """
        Search TikTok for trending places in a city
        
        Args:
            city: City name
            country: Country name
            max_results: Maximum number of results
        
        Returns:
            List of places with TikTok metadata
        """
        try:
            if not self._initialized:
                await self.initialize()
            
            if not self.api:
                return self._get_fallback_data(city, country, max_results)
            
            # Search queries optimized for travel content
            queries = [
                f"{city} {country} travel",
                f"{city} food",
                f"things to do {city}",
                f"best places {city}",
                f"{city} hidden gems",
                f"{city} must visit"
            ]
            
            all_videos = []
            
            for query in queries:
                try:
                    search = self.api.search.search_type(
                        search_term=query,
                        search_type="general",
                        count=max_results // len(queries) + 2
                    )
                    
                    async for video in search:
                        video_data = video.as_dict
                        place_info = self._extract_place_from_video(video_data, city, country)
                        
                        if place_info and place_info not in all_videos:
                            all_videos.append(place_info)
                            
                            if len(all_videos) >= max_results:
                                break
                                
                except Exception as e:
                    print(f"Error searching '{query}': {e}")
                    continue
                
                if len(all_videos) >= max_results:
                    break
            
            # Sort by engagement
            sorted_videos = sorted(
                all_videos, 
                key=lambda x: x.get('engagement', 0), 
                reverse=True
            )
            
            return sorted_videos[:max_results]
        
        except Exception as e:
            print(f"TikTok scraping error: {e}")
            return self._get_fallback_data(city, country, max_results)
    
    def _extract_place_from_video(self, video: Dict, city: str, country: str) -> Optional[Dict]:
        """Extract place information from TikTok video"""
        try:
            desc = video.get('desc', '')
            stats = video.get('stats', {})
            author = video.get('author', {})
            
            # Skip if no description
            if not desc or len(desc) < 10:
                return None
            
            # Calculate engagement score
            engagement = (
                stats.get('playCount', 0) + 
                stats.get('diggCount', 0) * 2 +  # Likes weighted more
                stats.get('shareCount', 0) * 3 +  # Shares weighted most
                stats.get('commentCount', 0)
            )
            
            # Extract hashtags
            hashtags = []
            if 'challenges' in video:
                hashtags = [c.get('title', '') for c in video.get('challenges', [])]
            
            # Also extract from description
            hashtag_pattern = r'#(\w+)'
            desc_hashtags = re.findall(hashtag_pattern, desc)
            hashtags.extend(desc_hashtags)
            
            # Categorize
            category = self._categorize_from_text(desc, hashtags)
            
            # Extract potential place name
            place_name = self._extract_place_name(desc, city)
            
            return {
                'name': place_name,
                'type': category,
                'city': city,
                'country': country,
                'description': desc[:250].strip(),
                'tiktok_url': f"https://www.tiktok.com/@{author.get('uniqueId', '')}/video/{video.get('id', '')}",
                'views': stats.get('playCount', 0),
                'likes': stats.get('diggCount', 0),
                'shares': stats.get('shareCount', 0),
                'comments': stats.get('commentCount', 0),
                'engagement': engagement,
                'hashtags': list(set(hashtags))[:5],  # Unique, limited to 5
                'author': author.get('uniqueId', 'unknown')
            }
        except Exception as e:
            print(f"Error extracting place from video: {e}")
            return None
    
    def _categorize_from_text(self, text: str, hashtags: List[str]) -> str:
        """Categorize place based on text and hashtags"""
        combined = (text + " " + " ".join(hashtags)).lower()
        
        categories = {
            'food': ['food', 'restaurant', 'cafe', 'eat', 'dining', 'foodie', 'eats', 'cuisine'],
            'culture': ['museum', 'art', 'gallery', 'temple', 'church', 'historic', 'cultural', 'history'],
            'nature': ['beach', 'park', 'mountain', 'nature', 'hiking', 'outdoor', 'scenic', 'view'],
            'shopping': ['shop', 'market', 'mall', 'boutique', 'shopping', 'store'],
            'nightlife': ['bar', 'club', 'night', 'party', 'drinks', 'nightlife'],
            'adventure': ['adventure', 'extreme', 'thrill', 'adrenaline', 'activity']
        }
        
        # Count matches for each category
        scores = {}
        for category, keywords in categories.items():
            score = sum(1 for keyword in keywords if keyword in combined)
            if score > 0:
                scores[category] = score
        
        # Return category with highest score
        if scores:
            return max(scores, key=scores.get)
        
        return 'landmark'
    
    def _extract_place_name(self, text: str, city: str) -> str:
        """Extract place name from description (simplified NER)"""
        # Clean text
        text = text.replace('\n', ' ')
        
        # Look for quoted places
        quoted = re.findall(r'"([^"]+)"', text)
        if quoted:
            return quoted[0]
        
        # Look for capitalized sequences (2+ words)
        words = text.split()
        for i, word in enumerate(words):
            if (word and len(word) > 2 and word[0].isupper() and 
                i < len(words) - 1 and not word.startswith('#')):
                next_word = words[i + 1]
                if next_word and next_word[0].isupper():
                    potential_name = f"{word} {next_word}"
                    # Avoid common words
                    if potential_name.lower() not in ['the best', 'must visit', 'you need']:
                        return potential_name
        
        # Look for location indicators
        location_patterns = [
            r'at\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)',
            r'visit\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)',
            r'in\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)'
        ]
        
        for pattern in location_patterns:
            match = re.search(pattern, text)
            if match:
                place = match.group(1)
                if place != city and len(place) > 3:
                    return place
        
        return f"Trending spot in {city}"
    
    def _get_fallback_data(self, city: str, country: str, max_results: int) -> List[Dict]:
        """Generate fallback data when TikTok API is unavailable"""
        print(f"Using fallback data for {city}, {country}")
        
        import random
        
        templates = [
            {'name': f'{city} Old Town', 'type': 'culture'},
            {'name': f'{city} Food Market', 'type': 'food'},
            {'name': f'{city} Viewpoint', 'type': 'nature'},
            {'name': f'{city} Contemporary Art Museum', 'type': 'culture'},
            {'name': f'{city} Beach', 'type': 'nature'},
            {'name': 'Traditional Local Restaurant', 'type': 'food'},
            {'name': f'{city} Shopping Street', 'type': 'shopping'},
            {'name': 'Historic Cathedral', 'type': 'culture'},
            {'name': f'{city} Night Market', 'type': 'food'},
            {'name': f'{city} Central Park', 'type': 'nature'},
            {'name': 'Rooftop Bar', 'type': 'nightlife'},
            {'name': 'Street Art District', 'type': 'culture'},
            {'name': 'Hidden Gem Cafe', 'type': 'food'},
            {'name': 'Local Artisan Market', 'type': 'shopping'},
            {'name': f'{city} Botanical Garden', 'type': 'nature'}
        ]
        
        results = []
        for template in templates[:max_results]:
            results.append({
                **template,
                'city': city,
                'country': country,
                'description': f"Popular destination in {city}, {country}. Trending on social media for its unique atmosphere and experiences.",
                'tiktok_url': '#',
                'views': random.randint(50000, 2000000),
                'likes': random.randint(5000, 200000),
                'shares': random.randint(500, 20000),
                'comments': random.randint(100, 5000),
                'engagement': random.randint(60000, 2500000),
                'hashtags': [f'{city.lower()}travel', 'thingstodo', template['type']],
                'author': 'simulated'
            })
        
        return results
    
    async def close(self):
        """Close TikTok API session"""
        if self.api:
            await self.api.close_sessions()


# Singleton instance
_scraper = None

async def get_tiktok_scraper() -> TikTokScraper:
    """Get or create TikTok scraper instance"""
    global _scraper
    if _scraper is None:
        _scraper = TikTokScraper()
        await _scraper.initialize()
    return _scraper

