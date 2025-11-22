# 🌍 Itinera - AI-Powered Travel Itinerary Builder

Itinera creates personalized travel itineraries based on **real TikTok trending locations**, using **ChatGPT** for intelligent planning and **Google Maps** for geographic optimization.

## ✨ Features

- 🎬 **TikTok Integration**: Scrapes trending travel content from TikTok
- 🤖 **ChatGPT AI Planning**: Uses GPT-4 for intelligent, geographically-clustered itineraries
- 🗺️ **Google Maps Integration**: Interactive maps with geocoding and directions
- 📅 **Multi-Day Itineraries**: Plan trips from 1-30 days
- 👥 **Group Customization**: Tailored for solo travelers to large groups
- 🍽️ **Food Preferences**: Accommodate dietary restrictions
- 💰 **Budget Options**: Budget, medium, and luxury travelers
- 🔄 **AI Refinement**: Modify itineraries with natural language
- 📍 **Google Maps Export**: Export routes directly to Google Maps

## 🚀 Quick Start

### Prerequisites

- Python 3.8 or higher
- pip (Python package manager)

### Installation

1. **Clone the repository**
   ```bash
   cd Itinera
   ```

2. **Create a virtual environment** (recommended)
   ```bash
   # Windows
   python -m venv venv
   venv\Scripts\activate

   # macOS/Linux
   python3 -m venv venv
   source venv/bin/activate
   ```

3. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```

4. **Set up environment variables**
   
   Create a `.env` file in the root directory:
   ```bash
   # Windows PowerShell
   Copy-Item .env.example .env

   # macOS/Linux
   cp .env.example .env
   ```

   Edit `.env` and add your API keys:
   ```
   OPENAI_API_KEY=your_openai_api_key_here
   GOOGLE_MAPS_API_KEY=your_google_maps_api_key_here
   TIKTOK_API_KEY=your_tiktok_api_key_here
   ```

### Getting API Keys

#### 1. OpenAI API Key (Required) 🔑
1. Go to [OpenAI Platform](https://platform.openai.com/)
2. Sign up or log in
3. Navigate to **API Keys** section
4. Click **Create new secret key**
5. Copy the key to your `.env` file

#### 2. Google Maps API Key (Required) 🗺️
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable these APIs:
   - **Maps JavaScript API**
   - **Geocoding API**
   - **Places API**
4. Go to **Credentials** → **Create API Key**
5. Copy the key to your `.env` file

#### 3. TikTok API Key (Optional - uses simulation if not provided) 🎬
1. Go to [TikTok Developers](https://developers.tiktok.com/)
2. Create a new app
3. Apply for **Research API** access (required for content search)
4. Get your API token
5. Copy to your `.env` file

**Note**: TikTok Research API requires approval. Without it, the app will use simulated trending data.

### Running the Application

1. **Start the Python server**
   ```bash
   python app.py
   ```

   You should see:
   ```
   🚀 Starting Itinera server...
   📍 Make sure your API keys are set in .env file
   * Running on http://0.0.0.0:5000
   ```

2. **Open your browser**
   
   Navigate to: **http://localhost:5000**

## 📖 How to Use

### 1. Enter Trip Details
- **City & Country**: Your destination
- **Length of Stay**: Number of days (1-30)
- **Group Size**: Number of travelers
- **Budget**: Budget, Medium, or Luxury
- **Food Preferences**: Dietary restrictions or preferences
- **Must-Do Activities**: Specific places you want to visit

### 2. Generate Itinerary
- Click **"Generate Itinerary"**
- AI will:
  - Fetch trending TikTok content for your destination
  - Geocode locations using Google Maps
  - Create optimized day-by-day plans using ChatGPT
  - Apply K-means clustering for geographic optimization

### 3. Explore Your Plan
- **Switch Days**: Use day selector to view different days
- **Interactive Map**: Click markers for activity details
- **View Details**: Time, duration, descriptions for each activity
- **Travel Tips**: AI-generated tips specific to your trip

### 4. Refine Your Itinerary
- Use the feedback box to request changes
- Examples:
  - "Add more food stops"
  - "Less walking, more relaxing activities"
  - "Include more cultural sites"
  - "Swap day 2 and day 3"

### 5. Export to Google Maps
- Click **"Export to Google Maps"** for any day
- Opens Google Maps with all locations as waypoints
- Perfect for navigation during your trip

## 🏗️ Tech Stack

### Backend
- **Python 3.8+**
- **Flask** - Web framework
- **OpenAI API** - GPT-4 for itinerary generation
- **Google Maps API** - Geocoding and mapping
- **TikTok Research API** - Trending content

### Frontend
- **HTML5/CSS3** - Modern responsive design
- **Vanilla JavaScript** - No framework overhead
- **Google Maps JavaScript API** - Interactive maps

## 📁 Project Structure

```
Itinera/
├── app.py              # Flask backend server
├── requirements.txt    # Python dependencies
├── .env               # API keys (create this)
├── .env.example       # Template for .env
├── README.md          # This file
└── public/            # Frontend files
    ├── index.html     # Main page
    ├── styles.css     # Styling
    └── script.js      # Frontend logic
```

## 🔧 API Endpoints

### `GET /api/config`
Returns configuration (Google Maps API key for frontend)

### `POST /api/generate-itinerary`
Generates AI itinerary based on TikTok trends

**Request Body:**
```json
{
  "city": "Tokyo",
  "country": "Japan",
  "lengthOfStay": 3,
  "groupSize": 2,
  "budget": "Medium",
  "foodPreferences": "Vegetarian",
  "mustDo": "Visit temples"
}
```

### `POST /api/refine-itinerary`
Refines existing itinerary based on feedback

**Request Body:**
```json
{
  "currentItinerary": {...},
  "userFeedback": "Add more food options"
}
```

## 🎯 How It Works

### TikTok Integration
1. **Search Query**: Builds search query from city name + travel keywords
2. **API Call**: Fetches trending videos from TikTok Research API
3. **Content Analysis**: Extracts place names, categories from descriptions
4. **Engagement Sorting**: Prioritizes high-view/high-engagement content

### AI Clustering (K-means)
1. **Geocoding**: Gets coordinates for all trending places
2. **ChatGPT Analysis**: AI analyzes geographic distribution
3. **Day Clustering**: Groups nearby attractions for each day
4. **Route Optimization**: Creates logical flow for each day

### Smart Features
- **Time Allocation**: Realistic timing based on activity type
- **Category Balance**: Mixes food, culture, nature, shopping
- **Preference Matching**: Respects dietary and activity preferences
- **Budget Awareness**: Adjusts recommendations to budget level

## 🚧 Troubleshooting

### "TikTok API Error"
- App falls back to simulated data automatically
- To use real data, get TikTok Research API access

### "Geocoding Error"
- Check Google Maps API key is valid
- Ensure Geocoding API is enabled in Google Cloud

### "OpenAI API Error"
- Verify API key is correct
- Check you have credits in your OpenAI account
- Ensure GPT-4 access is enabled

### Port Already in Use
```bash
# Change port in app.py, line 297:
app.run(host='0.0.0.0', port=5001, debug=True)
```

## 🔮 Future Enhancements

- [ ] User authentication and saved trips
- [ ] Real-time collaboration
- [ ] Hotel booking integration
- [ ] Restaurant reservations
- [ ] Weather forecasts
- [ ] Transportation recommendations
- [ ] Cost tracking and budgeting
- [ ] Mobile app (React Native)
- [ ] Multi-language support
- [ ] Offline mode

## 📝 Notes

### TikTok API Access
The TikTok Research API requires approval and is primarily for academic/research use. For production:
- Apply through TikTok Developer Portal
- Alternative: Use TikTok Content API (limited access)
- Fallback: App uses intelligent simulation based on common travel patterns

### API Costs
- **OpenAI**: ~$0.01-0.03 per itinerary (GPT-4)
- **Google Maps**: Free tier includes 28,000 map loads/month
- **TikTok**: Free for approved researchers

## 🤝 Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📄 License

MIT License - Free for personal and commercial use

## 💬 Support

- **Issues**: Open a GitHub issue
- **Questions**: Check existing issues or create new one

---

**Built with ❤️ using Python, Flask, ChatGPT, and TikTok trends**

Happy travels! ✈️🌍
