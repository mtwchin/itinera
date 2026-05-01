import json
import os
import random
import re
from datetime import datetime

from dotenv import load_dotenv
from flask import Flask, jsonify, request, send_from_directory
from flask_cors import CORS
import googlemaps
import openai
import requests

# Load environment variables
load_dotenv()

app = Flask(__name__, static_folder="public")
CORS(app)

# Initialize API clients
openai_client = openai.OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
gmaps = googlemaps.Client(key=os.getenv("GOOGLE_MAPS_API_KEY"))
TIKTOK_API_KEY = os.getenv("TIKTOK_API_KEY")

# TikTok API Configuration
TIKTOK_API_URL = "https://open.tiktokapis.com/v2/"


def scrape_tiktok_places(city, country, num_results=10):
    """Scrape trending places from TikTok based on city and country."""
    try:
        headers = {
            "Authorization": f"Bearer {TIKTOK_API_KEY}",
            "Content-Type": "application/json",
        }

        payload = {
            "query": {
                "and": [
                    {
                        "field_name": "hashtag_name",
                        "field_values": [city.lower(), "travel", "thingstodo"],
                        "operation": "IN",
                    }
                ],
                "not": [],
            },
            "max_count": num_results,
            "start_date": "20240101",
            "end_date": datetime.now().strftime("%Y%m%d"),
        }

        response = requests.post(
            f"{TIKTOK_API_URL}research/video/query/",
            headers=headers,
            json=payload,
            timeout=10,
        )

        if response.status_code == 200:
            data = response.json()
            return parse_tiktok_response(data, city, country)

        print(f"TikTok API Error: {response.status_code}")
        return simulate_tiktok_data(city, country)

    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Error scraping TikTok: {e}")
        return simulate_tiktok_data(city, country)


def parse_tiktok_response(data, city, country):
    """Parse TikTok API response and extract place information."""
    places = []

    if "data" in data and "videos" in data["data"]:
        for video in data["data"]["videos"][:10]:
            description = video.get("video_description", "")
            hashtags = video.get("hashtags", [])

            place_name = extract_place_from_text(description)

            places.append(
                {
                    "name": place_name,
                    "type": categorize_place(description, hashtags),
                    "city": city,
                    "country": country,
                    "description": description[:200],
                    "tiktok_url": f"https://www.tiktok.com/@{video.get('username', '')}/video/{video.get('id', '')}",
                    "views": video.get("view_count", 0),
                    "engagement": video.get("like_count", 0)
                    + video.get("share_count", 0),
                }
            )

    return places if places else simulate_tiktok_data(city, country)


def extract_place_from_text(text):
    """Extract place name from text (simplified)."""
    words = text.split()
    for i, word in enumerate(words):
        if word and word[0].isupper() and i < len(words) - 1:
            next_word = words[i + 1]
            if next_word and next_word[0].isupper():
                return f"{word} {next_word}"
    return "Popular Spot"


def categorize_place(description, hashtags):
    """Categorize place based on description and hashtags."""
    text = (description + " " + " ".join(hashtags)).lower()

    if any(word in text for word in ["food", "restaurant", "cafe", "eat", "dining"]):
        return "food"
    if any(word in text for word in ["museum", "art", "gallery", "temple", "church"]):
        return "culture"
    if any(word in text for word in ["beach", "park", "mountain", "nature", "hiking"]):
        return "nature"
    if any(word in text for word in ["shop", "market", "mall", "boutique"]):
        return "shopping"
    return "landmark"


def simulate_tiktok_data(city, country):
    """Return simulated TikTok data for testing or fallback."""
    place_templates = [
        {"name": f"{city} Historic Downtown", "type": "landmark"},
        {"name": f"{city} Food Market", "type": "food"},
        {"name": f"{city} Scenic Viewpoint", "type": "nature"},
        {"name": f"{city} Art Museum", "type": "culture"},
        {"name": f"{city} Waterfront", "type": "nature"},
        {"name": "Traditional Local Restaurant", "type": "food"},
        {"name": f"{city} Shopping District", "type": "shopping"},
        {"name": "Historic Temple", "type": "culture"},
        {"name": f"{city} Night Market", "type": "food"},
        {"name": f"{city} Central Park", "type": "nature"},
    ]

    return [
        {
            **place,
            "city": city,
            "country": country,
            "description": f"Popular spot in {city}, {country} trending on TikTok",
            "views": random.randint(10000, 5000000),
            "engagement": random.randint(1000, 500000),
        }
        for place in place_templates
    ]


@app.route("/")
def index():
    """Serve the main index page."""
    return send_from_directory("public", "index.html")


@app.route("/<path:path>")
def static_files(path):
    """Serve static files from the public directory."""
    return send_from_directory("public", path)


@app.route("/api/config", methods=["GET"])
def get_config():
    """Return configuration for frontend."""
    return jsonify({"googleMapsApiKey": os.getenv("GOOGLE_MAPS_API_KEY")})


@app.route("/reverse_geocode", methods=["GET"])
def reverse_geocode():
    """Reverse geocode coordinates to city/address."""
    try:
        lat = float(request.args.get("lat"))
        lng = float(request.args.get("lng"))

        result = gmaps.reverse_geocode((lat, lng))

        if not result:
            return jsonify({"success": False, "error": "Location not found"}), 404

        address_components = result[0].get("address_components", [])
        city = None
        country = None

        for component in address_components:
            types = component.get("types", [])
            if "locality" in types:
                city = component.get("long_name")
            elif "administrative_area_level_1" in types and not city:
                city = component.get("long_name")
            if "country" in types:
                country = component.get("long_name")

        if city and country:
            formatted_address = f"{city}, {country}"
        else:
            formatted_address = result[0]["formatted_address"]

        return jsonify(
            {
                "success": True,
                "address": formatted_address,
                "full_address": result[0]["formatted_address"],
                "city": city,
                "country": country,
            }
        )

    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Reverse geocode error: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/expand-maps-url", methods=["POST"])
def expand_maps_url():
    """Expand shortened Google Maps URLs and extract coordinates."""
    try:
        data = request.json
        short_url = data.get("url")

        if not short_url:
            return jsonify({"success": False, "error": "No URL provided"}), 400

        response = requests.get(short_url, allow_redirects=True, timeout=10)
        full_url = response.url

        print(f"Expanded URL: {full_url}")

        patterns = [
            r"@(-?\d+\.\d+),(-?\d+\.\d+)",
            r"[?&]q=(-?\d+\.\d+),(-?\d+\.\d+)",
            r"[?&]ll=(-?\d+\.\d+),(-?\d+\.\d+)",
            r"/place/[^\/]+/@(-?\d+\.\d+),(-?\d+\.\d+)",
        ]

        for pattern in patterns:
            match = re.search(pattern, full_url)
            if match:
                lat = float(match.group(1))
                lng = float(match.group(2))
                return jsonify(
                    {
                        "success": True,
                        "coordinates": {"lat": lat, "lng": lng},
                        "fullUrl": full_url,
                    }
                )

        return (
            jsonify(
                {
                    "success": False,
                    "error": "Could not extract coordinates from URL",
                }
            ),
            400,
        )

    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Error expanding URL: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/generate-itinerary", methods=["POST"])
def generate_itinerary():  # pylint: disable=too-many-locals
    """Generate AI-powered itinerary based on TikTok trends."""
    try:
        data = request.json
        city = data.get("city")
        country = data.get("country")
        accommodation = data.get("accommodation", {})
        accommodation_address = accommodation.get("address", "City center")
        accommodation_coords = {
            "lat": accommodation.get("lat", 0),
            "lng": accommodation.get("lng", 0),
        }
        length_of_stay = data.get("lengthOfStay")
        group_size = data.get("groupSize")
        wake_up_time = data.get("wakeUpTime", "08:00")
        food_preferences = data.get("foodPreferences", "None specified")
        must_do = data.get("mustDo", "None specified")
        budget = data.get("budget", "Medium")

        print(f"Fetching TikTok trends for {city}, {country}...")
        trending_places = scrape_tiktok_places(city, country)

        for place in trending_places:
            try:
                geocode_result = gmaps.geocode(f"{place['name']}, {city}, {country}")
                if geocode_result:
                    location = geocode_result[0]["geometry"]["location"]
                    place["coordinates"] = {
                        "lat": location["lat"],
                        "lng": location["lng"],
                    }
                    place["address"] = geocode_result[0]["formatted_address"]
            except Exception as e:  # pylint: disable=broad-exception-caught
                print(f"Geocoding error for {place['name']}: {e}")
                place["coordinates"] = {"lat": 0, "lng": 0}
                place["address"] = f"{city}, {country}"

        places_list = "\n".join(
            [
                f"{i+1}. {p['name']} ({p['type']}) - {p.get('views', 0):,} TikTok views"
                for i, p in enumerate(trending_places)
            ]
        )

        prompt = f"""You are a travel expert creating an itinerary based on trending TikTok locations.

Destination: {city}, {country}
Accommodation: {accommodation_address} (coordinates: {accommodation_coords['lat']}, {accommodation_coords['lng']})
Duration: {length_of_stay} days
Group size: {group_size} people
Wake up time: {wake_up_time} (start activities accordingly)
Food preferences: {food_preferences}
Must-do activities: {must_do}
Budget: {budget}

Trending places from TikTok (sorted by popularity):
{places_list}

IMPORTANT: The traveler is staying at {accommodation_address}. Use this as the starting and ending point for EACH day.

Create a {length_of_stay}-day itinerary that:
1. STARTS each day from the accommodation location: {accommodation_address} around {wake_up_time}
2. ENDS each day returning to the accommodation location
3. Groups nearby attractions efficiently to minimize travel time from accommodation
4. Uses geographic clustering (K-means) but considers accommodation as the daily base point
5. Plans routes in logical loops/circuits that return to accommodation
6. Balances different types of activities (culture, food, nature, shopping)
7. Provides realistic timing including travel time to/from accommodation and wake up time
8. Includes the must-do activities if specified
9. Includes food recommendations based on preferences
10. Prioritizes places with higher TikTok engagement
11. Suggests best times to leave accommodation and expected return times based on {wake_up_time} wake up time

Format your response as a JSON object with this structure:
{{
  "itinerary": [
    {{
      "day": 1,
      "theme": "Day theme",
      "activities": [
        {{
          "time": "9:00 AM",
          "name": "Activity name",
          "type": "landmark/food/culture/nature/shopping",
          "duration": "2 hours",
          "description": "Why visit and what to expect",
          "address": "Full address",
          "coordinates": {{"lat": 0, "lng": 0}}
        }}
      ]
    }}
  ],
  "tips": [
    "Tip about efficient routes from accommodation",
    "Local transportation tip",
    "Safety or cultural tip"
  ],
  "accommodationInfo": {{
    "morningStart": "Suggested time to leave accommodation each morning",
    "eveningReturn": "Expected return time to accommodation each evening",
    "transportationTips": "Best way to get around from this location"
  }},
  "estimatedBudget": "Budget estimate per person for entire trip"
}}

IMPORTANT: Return ONLY the JSON object, no other text."""

        response = openai_client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": "You are a travel planning assistant that creates detailed, geographically optimized itineraries. Always respond with valid JSON only.",
                },
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
            temperature=0.8,
        )

        itinerary_data = json.loads(response.choices[0].message.content)

        return jsonify(
            {
                "success": True,
                "data": itinerary_data,
                "trendingPlaces": trending_places,
            }
        )

    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Error generating itinerary: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/refine-itinerary", methods=["POST"])
def refine_itinerary():
    """Refine existing itinerary based on user feedback."""
    try:
        data = request.json
        current_itinerary = data.get("currentItinerary")
        user_feedback = data.get("userFeedback")

        prompt = f"""The user has the following itinerary and wants to make changes:

Current Itinerary:
{json.dumps(current_itinerary, indent=2)}

User Feedback/Changes:
{user_feedback}

Please provide an updated itinerary incorporating their feedback. Maintain the same JSON structure.
Return ONLY the JSON object, no other text."""

        response = openai_client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {
                    "role": "system",
                    "content": "You are a travel planning assistant. Always respond with valid JSON only.",
                },
                {"role": "user", "content": prompt},
            ],
            response_format={"type": "json_object"},
            temperature=0.7,
        )

        refined_itinerary = json.loads(response.choices[0].message.content)

        return jsonify({"success": True, "data": refined_itinerary})

    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"Error refining itinerary: {e}")
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/search-places", methods=["POST"])
def search_places():
    """Search for places using Google Maps Places API."""
    try:
        data = request.json
        query = data.get("query")
        location = data.get("location")

        places_result = gmaps.places(query=query, location=location)

        return jsonify({"success": True, "places": places_result.get("results", [])})

    except Exception as e:  # pylint: disable=broad-exception-caught
        return jsonify({"success": False, "error": str(e)}), 500


if __name__ == "__main__":
    print("Starting Itinera server...")
    app.run(host="0.0.0.0", port=5000, debug=True)
