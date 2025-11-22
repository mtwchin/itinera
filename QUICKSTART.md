# 🚀 Quick Start Guide

## Get Up and Running in 5 Minutes!

### Step 1: Install Python Dependencies
```bash
pip install -r requirements.txt
```

### Step 2: Get Your API Keys

#### OpenAI (Required)
1. Visit: https://platform.openai.com/api-keys
2. Create account → New API key
3. Copy the key

#### Google Maps (Required)
1. Visit: https://console.cloud.google.com/
2. Create project → Enable APIs:
   - Maps JavaScript API
   - Geocoding API
   - Places API
3. Credentials → Create API Key
4. Copy the key

#### TikTok (Optional)
1. Visit: https://developers.tiktok.com/
2. Create app → Apply for Research API
3. Copy the key (or skip - app will use simulation)

### Step 3: Configure Environment
Open `.env` file and paste your keys:
```
OPENAI_API_KEY=sk-your-key-here
GOOGLE_MAPS_API_KEY=AIza-your-key-here
TIKTOK_API_KEY=your-key-here-or-leave-blank
```

### Step 4: Run the App
```bash
python app.py
```

### Step 5: Open Browser
Navigate to: **http://localhost:5000**

## 🎉 That's It!

Now you can:
1. Enter a destination (e.g., "Paris, France")
2. Set your preferences
3. Click "Generate Itinerary"
4. Get AI-powered travel plans with TikTok trends!

## 💡 Pro Tips

- **No TikTok API?** No problem! App uses smart simulation
- **First time?** Try "Tokyo, Japan" for 3 days
- **Export routes** to Google Maps for navigation
- **Refine itinerary** using natural language feedback

## ⚠️ Troubleshooting

**Port in use?**
```python
# Change in app.py (last line)
app.run(host='0.0.0.0', port=5001, debug=True)
```

**API errors?**
- Check keys in `.env` are correct
- Verify OpenAI account has credits
- Ensure Google Maps APIs are enabled

**Import errors?**
```bash
pip install --upgrade -r requirements.txt
```

## 📚 Need More Help?
See full README.md for detailed documentation.

---
Happy travels! ✈️

