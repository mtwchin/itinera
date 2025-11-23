# React + TikTok Setup Script for Itinera (PowerShell)
Write-Host "🚀 Setting up Itinera React App with TikTok Integration" -ForegroundColor Cyan
Write-Host ""

# Step 1: Create React app with Vite
Write-Host "Step 1: Creating React + TypeScript app..." -ForegroundColor Blue
npm create vite@latest frontend -- --template react-ts

Set-Location frontend

# Step 2: Install React dependencies
Write-Host "Step 2: Installing React dependencies..." -ForegroundColor Blue
npm install

# Step 3: Install component libraries
Write-Host "Step 3: Installing component libraries..." -ForegroundColor Blue
npm install rc-calendar moment
npm install @react-google-maps/api
npm install react-select
npm install framer-motion
npm install axios
npm install zustand
npm install react-hot-toast
npm install react-icons

# Step 4: Install dev dependencies
Write-Host "Step 4: Installing dev dependencies..." -ForegroundColor Blue
npm install -D @types/node

Set-Location ..

# Step 5: Install Python TikTok API
Write-Host "Step 5: Installing TikTok API (Python)..." -ForegroundColor Blue
pip install TikTokApi
pip install playwright
python -m playwright install

# Step 6: Update requirements.txt
Write-Host "Step 6: Updating requirements.txt..." -ForegroundColor Blue
Add-Content -Path requirements.txt -Value "TikTokApi==6.5.3"
Add-Content -Path requirements.txt -Value "playwright==1.40.0"
Add-Content -Path requirements.txt -Value "fastapi==0.109.0"
Add-Content -Path requirements.txt -Value "uvicorn[standard]==0.25.0"

Write-Host ""
Write-Host "✅ Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Add your API keys to .env"
Write-Host "  2. cd frontend; npm run dev    # Start React app"
Write-Host "  3. python app.py               # Start backend"
Write-Host ""
Write-Host "📖 See REACT_CONVERSION.md for full guide"

