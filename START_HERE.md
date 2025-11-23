# 🚀 How to Run Itinera

## Quick Start (2 Simple Steps)

### Step 1: Start the Backend Server

Open a terminal and run:

```bash
python app.py
```

✅ You should see:
```
* Running on http://127.0.0.1:5000
```

**Keep this terminal running!** This is your backend (Flask server on port 5000).

---

### Step 2: Start the Frontend Server

Open a **NEW/SECOND** terminal and run:

```bash
cd frontend
npm run dev
```

✅ You should see:
```
VITE v5.x.x  ready in XXX ms

➜  Local:   http://localhost:5173/
```

**Keep this terminal running too!** This is your frontend (React app on port 5173).

---

## 🌐 View Your Website

**Open your browser and go to:**

# **http://localhost:5173**

That's it! This is the final website you'll see and interact with.

---

## Why Two Servers?

```
┌─────────────────────────────────────────┐
│  Browser: http://localhost:5173         │
│  (What you see)                         │
└─────────────────┬───────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────┐
│  Frontend: port 5173                    │
│  - React app (UI, map, forms)           │
│  - Runs: npm run dev                    │
└─────────────────┬───────────────────────┘
                  │
                  │ API calls
                  ▼
┌─────────────────────────────────────────┐
│  Backend: port 5000                     │
│  - Python Flask (AI, APIs, data)        │
│  - Runs: python app.py                  │
└─────────────────────────────────────────┘
```

- **Frontend (5173)**: The pretty interface you see - map, forms, buttons
- **Backend (5000)**: The brain - handles ChatGPT, Google Maps APIs, generates itineraries

The frontend automatically sends requests to the backend when needed.

---

## 📋 Checklist Before Starting

### 1. Check API Keys

**Root `.env` file** (for backend):
```bash
OPENAI_API_KEY=your_openai_key
GOOGLE_MAPS_API_KEY=your_google_key
```

**Frontend `.env` file** (for map):
```bash
cd frontend
# Check frontend/.env exists with:
VITE_GOOGLE_MAPS_KEY=your_google_key
```

### 2. Install Dependencies (First Time Only)

```bash
# Backend dependencies
pip install -r requirements.txt

# Frontend dependencies
cd frontend
npm install
```

---

## 🛑 How to Stop

Press `Ctrl+C` in each terminal to stop the servers.

---

## ❓ Troubleshooting

### "Port already in use"
```bash
# Kill the process using the port
# Windows:
netstat -ano | findstr :5000
taskkill /PID <PID_NUMBER> /F

# Mac/Linux:
lsof -ti:5000 | xargs kill -9
```

### "Map not showing"
1. Check `frontend/.env` has `VITE_GOOGLE_MAPS_KEY=...`
2. Restart frontend server
3. Open browser console (F12) for error messages

### "Failed to generate itinerary"
1. Check root `.env` has `OPENAI_API_KEY=...`
2. Check you have OpenAI API credits
3. Check backend terminal for error messages

---

## 📌 Remember

- **Always run BOTH servers**
- **View at**: http://localhost:5173 (NOT 5000!)
- **Backend (5000)**: You won't visit this directly
- **Frontend (5173)**: This is your actual website

---

## Quick Reference

| What | Command | Port | Visit? |
|------|---------|------|--------|
| Backend | `python app.py` | 5000 | ❌ No |
| Frontend | `cd frontend && npm run dev` | 5173 | ✅ **YES!** |

**Your website**: http://localhost:5173

