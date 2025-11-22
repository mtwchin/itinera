<<<<<<< HEAD
# ITINERA
a travel itinerary builder using top tiktoks and k-means clustering
  to build efficient and intelligent planning paths!
=======
# 🌍 Itinera - AI-Powered Travel Itinerary Builder

Itinera creates personalized travel itineraries based on trending TikTok locations, using AI to intelligently cluster activities by day and optimize your travel experience.

## Features

- 🎯 **AI-Powered Planning**: Uses ChatGPT to create intelligent, geographically-clustered itineraries
- 📍 **Google Maps Integration**: Interactive maps with markers for each activity
- 🗓️ **Multi-Day Itineraries**: Plan trips from 1-30 days
- 👥 **Group Customization**: Tailored for solo travelers to large groups
- 🍽️ **Food Preferences**: Accommodate dietary restrictions and preferences
- 💰 **Budget Options**: Plans for budget, medium, and luxury travelers
- 🔄 **AI Refinement**: Ask ChatGPT to modify your itinerary on the fly
- 🗺️ **Google Maps Export**: Export each day's route directly to Google Maps

## Setup Instructions

### Prerequisites

- Node.js (v14 or higher)
- OpenAI API key
- Google Maps API key

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd Itinera
   ```

2. **Install dependencies**
   ```bash
   npm install
   ```

3. **Set up environment variables**
   
   Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

   Edit `.env` and add your API keys:
   ```
   OPENAI_API_KEY=your_openai_api_key_here
   GOOGLE_MAPS_API_KEY=your_google_maps_api_key_here
   PORT=3000
   ```

### Getting API Keys

#### OpenAI API Key
1. Go to [OpenAI Platform](https://platform.openai.com/)
2. Sign up or log in
3. Navigate to API Keys section
4. Create a new API key
5. Copy the key to your `.env` file

#### Google Maps API Key
1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Enable the following APIs:
   - Maps JavaScript API
   - Geocoding API
   - Places API
4. Go to Credentials
5. Create an API key
6. Copy the key to your `.env` file

### Running the Application

1. **Start the server**
   ```bash
   npm start
   ```

   For development with auto-reload:
   ```bash
   npm run dev
   ```

2. **Open your browser**
   
   Navigate to `http://localhost:3000`

## Usage

1. **Enter Trip Details**
   - City and country
   - Length of stay (days)
   - Group size
   - Budget level
   - Food preferences
   - Must-do activities

2. **Generate Itinerary**
   - Click "Generate Itinerary"
   - Wait for AI to create your personalized plan

3. **Explore Your Itinerary**
   - Switch between days using the day selector
   - View activities on the interactive map
   - Read descriptions and timing for each activity

4. **Refine Your Plan**
   - Use the feedback box to request changes
   - AI will adjust your itinerary based on your input

5. **Export to Google Maps**
   - Click "Export to Google Maps" for the current day
   - Opens Google Maps with all locations as waypoints

## Technology Stack

- **Frontend**: HTML5, CSS3, Vanilla JavaScript
- **Backend**: Node.js, Express
- **AI**: OpenAI GPT-4
- **Maps**: Google Maps JavaScript API
- **Styling**: Custom CSS with modern design

## Future Enhancements

- [ ] Real TikTok API integration
- [ ] User authentication and saved itineraries
- [ ] Weather integration
- [ ] Booking integration (hotels, restaurants, activities)
- [ ] Collaborative trip planning
- [ ] Mobile app
- [ ] Multi-language support
- [ ] Cost estimator with real pricing data
- [ ] Transportation recommendations

## Notes on TikTok Integration

The current MVP uses simulated TikTok data. To implement real TikTok scraping, you would need to:

1. Use TikTok's official API (if you have access)
2. Implement web scraping (check TikTok's Terms of Service)
3. Use third-party TikTok data services

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues.

## License

MIT License - feel free to use this project for personal or commercial purposes.

## Support

For issues or questions, please open a GitHub issue or contact the maintainers.

---

Made with ❤️ by the Itinera team

>>>>>>> c72d659 (reset)
