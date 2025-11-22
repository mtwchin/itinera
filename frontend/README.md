# Itinera Frontend

Modern React + TypeScript frontend for the Itinera AI travel planner.

## Features

- **Trip Creation Wizard**: Multi-step form with preference sliders
- **Real-time Status Updates**: Polling for background job completion
- **Interactive Map**: Google Maps integration with custom markers
- **Day-by-Day View**: Beautiful cards showing optimized routes
- **Responsive Design**: Works on desktop, tablet, and mobile

## Tech Stack

- React 18 with TypeScript
- Tailwind CSS for styling
- React Router for navigation
- Google Maps JavaScript API
- Axios for API communication

## Getting Started

### Prerequisites

- Node.js 18+ and npm

### Installation

```bash
npm install
```

### Environment Variables

Create a `.env` file:

```env
REACT_APP_API_URL=http://localhost:8000
REACT_APP_GOOGLE_MAPS_API_KEY=your_google_maps_api_key
```

### Development

```bash
npm start
```

Open [http://localhost:3000](http://localhost:3000) to view in browser.

### Build

```bash
npm run build
```

Builds the app for production to the `build` folder.

## Project Structure

```
src/
├── components/        # Reusable UI components
│   ├── Header.tsx
│   ├── TripWizard.tsx
│   ├── MapView.tsx
│   ├── DayCard.tsx
│   ├── POICard.tsx
│   └── LoadingSpinner.tsx
├── pages/            # Route pages
│   ├── HomePage.tsx
│   └── ItineraryPage.tsx
├── services/         # API integration
│   └── api.ts
├── App.tsx           # Main app component
└── index.tsx         # Entry point
```

## API Integration

The frontend communicates with the FastAPI backend through a REST API. See `src/services/api.ts` for endpoint definitions.

## License

MIT

