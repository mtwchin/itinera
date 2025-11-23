# 🚀 Quick Start - Running Itinera

## ✅ Good News!
All core dependencies are installed! The TikTok scraping features are **optional** - the app works perfectly without them using simulated data.

## 📍 Where to View Your App

**Open your browser to:**

# http://localhost:5173

This is your live website!

---

## 🎬 Starting the Servers

### Step 1: Start Backend (Terminal 1)
```bash
python app.py
```

Wait for:
```
* Running on http://127.0.0.1:5000
```

### Step 2: Start Frontend (Terminal 2)
```bash
cd frontend
npm run dev
```

Wait for:
```
➜  Local:   http://localhost:5173/
```

### Step 3: Open Browser
Go to **http://localhost:5173**

---

## 🔑 Required Setup

Before using the app, you need API keys:

### 1. Root `.env` file (for backend):
```env
OPENAI_API_KEY=your_openai_api_key_here
GOOGLE_MAPS_API_KEY=your_google_maps_key_here
```

### 2. Frontend `.env` file (for map):
```bash
# Create this file:
cd frontend
# Add to frontend/.env:
VITE_GOOGLE_MAPS_KEY=your_google_maps_key_here
```

**Note:** The Google Maps key needs to be in BOTH files!

---

## 📊 Port Summary

| Server | Port | Visit? | Purpose |
|--------|------|--------|---------|
| **Frontend** | **5173** | **YES! ✅** | **Your website** |
| Backend | 5000 | No | API server |

---

## 🛑 Stopping the Servers

Press `Ctrl+C` in each terminal to stop them.

---

## 🐛 Troubleshooting

### "Module not found" error
```bash
pip install flask flask-cors python-dotenv openai googlemaps requests
```

### "Map not showing"
1. Check `frontend/.env` exists with `VITE_GOOGLE_MAPS_KEY=...`
2. Restart frontend server (`Ctrl+C` then `npm run dev`)
3. Check browser console (F12) for errors

### "Failed to generate itinerary"
1. Check root `.env` has `OPENAI_API_KEY=...`
2. Verify you have OpenAI API credits (separate from ChatGPT Plus)

---

## 💡 What You'll See

When you open **http://localhost:5173**, you should see:

- ✅ **Interactive world map** as the background
- ✅ **Form panel on the left** side
- ✅ **"Click to select destination"** tooltip
- ✅ You can click anywhere on the map OR type a city name

---

## 📝 TikTok Features (Optional)

The app currently uses **simulated TikTok data** which works great for testing!

If you want real TikTok scraping (advanced):
1. Install Microsoft Visual C++ Build Tools
2. Uncomment TikTok lines in `requirements.txt`
3. Run `pip install -r requirements.txt`
4. Run `python -m playwright install`

**But this is NOT required - the app works perfectly without it!**

---

## ✨ Summary

**To run the app:**
1. Terminal 1: `python app.py` (port 5000)
2. Terminal 2: `cd frontend && npm run dev` (port 5173)
3. Browser: **http://localhost:5173**

**That's it!** 🎉

