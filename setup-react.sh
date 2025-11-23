#!/bin/bash

# React + TikTok Setup Script for Itinera
echo "🚀 Setting up Itinera React App with TikTok Integration"
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Step 1: Create React app with Vite
echo -e "${BLUE}Step 1: Creating React + TypeScript app...${NC}"
npm create vite@latest frontend -- --template react-ts

cd frontend

# Step 2: Install React dependencies
echo -e "${BLUE}Step 2: Installing React dependencies...${NC}"
npm install

# Step 3: Install component libraries
echo -e "${BLUE}Step 3: Installing component libraries...${NC}"
npm install rc-calendar moment
npm install @react-google-maps/api
npm install react-select
npm install framer-motion
npm install axios
npm install zustand
npm install react-hot-toast
npm install react-icons

# Step 4: Install dev dependencies
echo -e "${BLUE}Step 4: Installing dev dependencies...${NC}"
npm install -D @types/node

cd ..

# Step 5: Install Python TikTok API
echo -e "${BLUE}Step 5: Installing TikTok API (Python)...${NC}"
pip install TikTokApi
pip install playwright
python -m playwright install

# Step 6: Update requirements.txt
echo -e "${BLUE}Step 6: Updating requirements.txt...${NC}"
echo "TikTokApi==6.5.3" >> requirements.txt
echo "playwright==1.40.0" >> requirements.txt
echo "fastapi==0.109.0" >> requirements.txt
echo "uvicorn[standard]==0.25.0" >> requirements.txt

echo ""
echo -e "${GREEN}✅ Setup complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Add your API keys to .env"
echo "  2. cd frontend && npm run dev    # Start React app"
echo "  3. python app.py                  # Start backend"
echo ""
echo "📖 See REACT_CONVERSION.md for full guide"

