import json
import logging
import os
import random
from datetime import datetime

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from flask_cors import CORS
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
import googlemaps
import openai
import requests

load_dotenv()

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("itinera")

app = Flask(__name__)
CORS(app)

limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=["120 per hour"],
    storage_uri=os.getenv("RATELIMIT_STORAGE_URI", "memory://"),
)

# Initialize API clients. Placeholder keys keep the app importable (tests,
# tooling) without secrets; real calls fail at request time with a clear log.
_openai_key = os.getenv("OPENAI_API_KEY")
_gmaps_key = os.getenv("GOOGLE_MAPS_API_KEY")
if not _openai_key:
    logger.warning("OPENAI_API_KEY is not set; itinerary generation will fail")
if not _gmaps_key:
    logger.warning("GOOGLE_MAPS_API_KEY is not set; geocoding will fail")

openai_client = openai.OpenAI(
    api_key=_openai_key or "not-configured", timeout=90, max_retries=1
)
gmaps = googlemaps.Client(key=_gmaps_key or ("AIza" + "0" * 35))
TIKTOK_API_KEY = os.getenv("TIKTOK_API_KEY")

TIKTOK_API_URL = "https://open.tiktokapis.com/v2/"

BUDGET_LEVELS = {"Budget", "Medium", "Luxury"}
MAX_TRIP_DAYS = 14
MAX_GROUP_SIZE = 20

GENERIC_ERROR = "Something went wrong. Please try again."


def _error(message, status):
    return jsonify({"success": False, "error": message}), status


def _validate_generate_request(data):
    """Validate /api/generate-itinerary payload.

    Returns (cleaned_dict, None) on success or (None, error_message).
    """
    if not isinstance(data, dict):
        return None, "Request body must be a JSON object."

    city = data.get("city")
    if not isinstance(city, str) or not city.strip():
        return None, "A destination city is required."
    if len(city) > 100:
        return None, "City name is too long."

    country = data.get("country") or ""
    if not isinstance(country, str) or len(country) > 100:
        return None, "Invalid country."

    length_of_stay = data.get("lengthOfStay")
    if not isinstance(length_of_stay, int) or isinstance(length_of_stay, bool):
        return None, "lengthOfStay must be a whole number of days."
    if not 1 <= length_of_stay <= MAX_TRIP_DAYS:
        return None, f"Trips must be between 1 and {MAX_TRIP_DAYS} days."

    budget = data.get("budget", "Medium")
    if budget not in BUDGET_LEVELS:
        return None, "budget must be one of: " + ", ".join(sorted(BUDGET_LEVELS))

    wake_up_time = data.get("wakeUpTime", "08:00")
    if not isinstance(wake_up_time, str) or len(wake_up_time) != 5:
        return None, "wakeUpTime must be in HH:MM format."
    try:
        datetime.strptime(wake_up_time, "%H:%M")
    except ValueError:
        return None, "wakeUpTime must be in HH:MM format."

    group_size = data.get("groupSize", 2)
    if not isinstance(group_size, int) or isinstance(group_size, bool):
        group_size = 2
    group_size = max(1, min(group_size, MAX_GROUP_SIZE))

    accommodation = data.get("accommodation") or {}
    if not isinstance(accommodation, dict):
        return None, "accommodation must be an object."
    accommodation_address = accommodation.get("address") or "City center"
    if not isinstance(accommodation_address, str) or len(accommodation_address) > 300:
        return None, "Accommodation address is too long."

    def _clip_text(value, limit):
        if not isinstance(value, str):
            return ""
        return value.strip()[:limit]

    return (
        {
            "city": city.strip(),
            "country": country.strip(),
            "length_of_stay": length_of_stay,
            "budget": budget,
            "wake_up_time": wake_up_time,
            "group_size": group_size,
            "accommodation_address": accommodation_address.strip(),
            "accommodation_coords": {
                "lat": accommodation.get("lat", 0),
                "lng": accommodation.get("lng", 0),
            },
            "food_preferences": _clip_text(data.get("foodPreferences"), 500)
            or "None specified",
            "must_do": _clip_text(data.get("mustDo"), 500) or "None specified",
        },
        None,
    )


def scrape_tiktok_places(city, country, num_results=10):
    """Fetch trending places from TikTok for a city, falling back to curated data."""
    if not TIKTOK_API_KEY:
        return simulate_tiktok_data(city, country)

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
            return parse_tiktok_response(response.json(), city, country)

        logger.warning("TikTok API returned status %s", response.status_code)
        return simulate_tiktok_data(city, country)

    except Exception:  # pylint: disable=broad-exception-caught
        logger.exception("Error fetching TikTok trends")
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
    """Return curated fallback place data when trend data is unavailable."""
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
            "description": f"Popular spot in {city}, {country}",
            "views": random.randint(10000, 5000000),
            "engagement": random.randint(1000, 500000),
        }
        for place in place_templates
    ]


@app.route("/")
def index():
    """Service info."""
    return jsonify({"service": "itinera-api", "status": "ok"})


@app.route("/healthz")
def healthz():
    """Health check for load balancers / uptime monitors."""
    return jsonify({"status": "ok"})


@app.route("/reverse_geocode", methods=["GET"])
@limiter.limit("60 per hour")
def reverse_geocode():
    """Reverse geocode coordinates to city/address."""
    try:
        lat = float(request.args.get("lat", ""))
        lng = float(request.args.get("lng", ""))
    except ValueError:
        return _error("lat and lng query parameters are required numbers.", 400)

    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return _error("Coordinates out of range.", 400)

    try:
        result = gmaps.reverse_geocode((lat, lng))

        if not result:
            return _error("Location not found", 404)

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

    except Exception:  # pylint: disable=broad-exception-caught
        logger.exception("Reverse geocode failed")
        return _error(GENERIC_ERROR, 500)


@app.route("/api/generate-itinerary", methods=["POST"])
@limiter.limit("10 per hour")
def generate_itinerary():  # pylint: disable=too-many-locals
    """Generate AI-powered itinerary based on trending places."""
    cleaned, validation_error = _validate_generate_request(
        request.get_json(silent=True)
    )
    if validation_error:
        return _error(validation_error, 400)

    city = cleaned["city"]
    country = cleaned["country"]

    try:
        logger.info("Generating itinerary for %s, %s", city, country)
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
            except Exception:  # pylint: disable=broad-exception-caught
                logger.exception("Geocoding error for %s", place["name"])
                place["coordinates"] = {"lat": 0, "lng": 0}
                place["address"] = f"{city}, {country}"

        places_list = "\n".join(
            [
                f"{i+1}. {p['name']} ({p['type']}) - {p.get('views', 0):,} views"
                for i, p in enumerate(trending_places)
            ]
        )

        prompt = f"""You are a travel expert creating an itinerary based on trending locations.

Destination: {city}, {country}
Accommodation: {cleaned['accommodation_address']} (coordinates: {cleaned['accommodation_coords']['lat']}, {cleaned['accommodation_coords']['lng']})
Duration: {cleaned['length_of_stay']} days
Group size: {cleaned['group_size']} people
Wake up time: {cleaned['wake_up_time']} (start activities accordingly)
Food preferences: {cleaned['food_preferences']}
Must-do activities: {cleaned['must_do']}
Budget: {cleaned['budget']}

Trending places (sorted by popularity):
{places_list}

IMPORTANT: The traveler is staying at {cleaned['accommodation_address']}. Use this as the starting and ending point for EACH day.

Create a {cleaned['length_of_stay']}-day itinerary that:
1. STARTS each day from the accommodation location around {cleaned['wake_up_time']}
2. ENDS each day returning to the accommodation location
3. Groups nearby attractions efficiently to minimize travel time from accommodation
4. Plans routes in logical loops/circuits that return to accommodation
5. Balances different types of activities (culture, food, nature, shopping)
6. Provides realistic timing including travel time to/from accommodation
7. Includes the must-do activities if specified
8. Includes food recommendations based on preferences
9. Prioritizes places with higher engagement

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

    except Exception:  # pylint: disable=broad-exception-caught
        logger.exception("Error generating itinerary")
        return _error(GENERIC_ERROR, 500)


@app.route("/api/refine-itinerary", methods=["POST"])
@limiter.limit("20 per hour")
def refine_itinerary():
    """Refine existing itinerary based on user feedback."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return _error("Request body must be a JSON object.", 400)

    current_itinerary = data.get("currentItinerary")
    user_feedback = data.get("userFeedback")

    if not isinstance(current_itinerary, dict) or not current_itinerary:
        return _error("currentItinerary is required.", 400)
    if not isinstance(user_feedback, str) or not user_feedback.strip():
        return _error("userFeedback is required.", 400)
    if len(user_feedback) > 1000:
        return _error("Feedback is too long (1000 character max).", 400)

    serialized = json.dumps(current_itinerary, indent=2)
    if len(serialized) > 50000:
        return _error("Itinerary is too large to refine.", 400)

    try:
        prompt = f"""The user has the following itinerary and wants to make changes:

Current Itinerary:
{serialized}

User Feedback/Changes:
{user_feedback.strip()}

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

    except Exception:  # pylint: disable=broad-exception-caught
        logger.exception("Error refining itinerary")
        return _error(GENERIC_ERROR, 500)


if __name__ == "__main__":
    debug = os.getenv("FLASK_DEBUG", "").lower() in {"1", "true", "yes"}
    logger.info("Starting Itinera server (debug=%s)...", debug)
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5000")), debug=debug)
