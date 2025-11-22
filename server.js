const express = require('express');
const cors = require('cors');
const dotenv = require('dotenv');
const OpenAI = require('openai');
const path = require('path');

dotenv.config();

const app = express();
const PORT = process.env.PORT || 3000;

// Initialize OpenAI
const openai = new OpenAI({
  apiKey: process.env.OPENAI_API_KEY
});

app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// Simulated TikTok scraper (in real implementation, you'd use TikTok API or web scraping)
function simulateTikTokScrape(city, country) {
  // This is a mock function. In production, you'd scrape actual TikTok data
  const mockPlaces = [
    { name: 'Historic Downtown', type: 'landmark', lat: 0, lng: 0 },
    { name: 'Local Food Market', type: 'food', lat: 0, lng: 0 },
    { name: 'Scenic Viewpoint', type: 'nature', lat: 0, lng: 0 },
    { name: 'Art Museum', type: 'culture', lat: 0, lng: 0 },
    { name: 'Beach Boardwalk', type: 'nature', lat: 0, lng: 0 },
    { name: 'Traditional Restaurant', type: 'food', lat: 0, lng: 0 },
    { name: 'Shopping District', type: 'shopping', lat: 0, lng: 0 },
    { name: 'Historic Temple', type: 'culture', lat: 0, lng: 0 },
    { name: 'Night Market', type: 'food', lat: 0, lng: 0 },
    { name: 'Waterfront Park', type: 'nature', lat: 0, lng: 0 }
  ];
  
  return mockPlaces.map(place => ({
    ...place,
    city,
    country,
    description: `Popular spot in ${city}, ${country} trending on TikTok`
  }));
}

// Endpoint to generate itinerary
app.post('/api/generate-itinerary', async (req, res) => {
  try {
    const { 
      city, 
      country, 
      lengthOfStay, 
      groupSize, 
      foodPreferences, 
      mustDo,
      budget
    } = req.body;

    // Step 1: Get trending places (simulated TikTok scrape)
    const trendingPlaces = simulateTikTokScrape(city, country);

    // Step 2: Use ChatGPT to create intelligent itinerary with clustering
    const prompt = `You are a travel expert creating an itinerary based on trending TikTok locations.

Location: ${city}, ${country}
Duration: ${lengthOfStay} days
Group size: ${groupSize} people
Food preferences: ${foodPreferences || 'None specified'}
Must-do activities: ${mustDo || 'None specified'}
Budget: ${budget || 'Medium'}

Trending places from TikTok:
${trendingPlaces.map((p, i) => `${i + 1}. ${p.name} (${p.type})`).join('\n')}

Create a ${lengthOfStay}-day itinerary that:
1. Groups nearby attractions for each day (use geographic clustering logic)
2. Balances different types of activities
3. Considers the group size and preferences
4. Includes the must-do activities if specified
5. Provides realistic timing (morning, afternoon, evening)
6. Includes food recommendations based on preferences

Format your response as a JSON object with this structure:
{
  "itinerary": [
    {
      "day": 1,
      "theme": "Day theme",
      "activities": [
        {
          "time": "9:00 AM",
          "name": "Activity name",
          "type": "landmark/food/culture/nature/shopping",
          "duration": "2 hours",
          "description": "Why visit and what to expect",
          "address": "Approximate address in ${city}",
          "coordinates": {"lat": 0, "lng": 0}
        }
      ]
    }
  ],
  "tips": ["Tip 1", "Tip 2", "Tip 3"],
  "estimatedBudget": "Budget estimate per person"
}

IMPORTANT: Return ONLY the JSON object, no other text.`;

    const completion = await openai.chat.completions.create({
      model: "gpt-4-turbo-preview",
      messages: [
        { 
          role: "system", 
          content: "You are a travel planning assistant that creates detailed, geographically optimized itineraries. Always respond with valid JSON only." 
        },
        { role: "user", content: prompt }
      ],
      response_format: { type: "json_object" },
      temperature: 0.8
    });

    const itineraryData = JSON.parse(completion.choices[0].message.content);

    res.json({
      success: true,
      data: itineraryData,
      trendingPlaces
    });

  } catch (error) {
    console.error('Error generating itinerary:', error);
    res.status(500).json({ 
      success: false, 
      error: error.message 
    });
  }
});

// Endpoint to get Google Maps API key for frontend
app.get('/api/config', (req, res) => {
  res.json({
    googleMapsApiKey: process.env.GOOGLE_MAPS_API_KEY
  });
});

// Endpoint to refine itinerary with ChatGPT
app.post('/api/refine-itinerary', async (req, res) => {
  try {
    const { currentItinerary, userFeedback } = req.body;

    const prompt = `The user has the following itinerary and wants to make changes:

Current Itinerary:
${JSON.stringify(currentItinerary, null, 2)}

User Feedback/Changes:
${userFeedback}

Please provide an updated itinerary incorporating their feedback. Maintain the same JSON structure.
Return ONLY the JSON object, no other text.`;

    const completion = await openai.chat.completions.create({
      model: "gpt-4-turbo-preview",
      messages: [
        { 
          role: "system", 
          content: "You are a travel planning assistant. Always respond with valid JSON only." 
        },
        { role: "user", content: prompt }
      ],
      response_format: { type: "json_object" },
      temperature: 0.7
    });

    const refinedItinerary = JSON.parse(completion.choices[0].message.content);

    res.json({
      success: true,
      data: refinedItinerary
    });

  } catch (error) {
    console.error('Error refining itinerary:', error);
    res.status(500).json({ 
      success: false, 
      error: error.message 
    });
  }
});

app.listen(PORT, () => {
  console.log(`🚀 Itinera server running on http://localhost:${PORT}`);
  console.log(`📍 Make sure to set your API keys in .env file`);
});

