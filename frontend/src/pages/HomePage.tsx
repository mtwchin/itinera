import React from 'react';
import TripWizard from '../components/TripWizard';

const HomePage: React.FC = () => {
  return (
    <div className="min-h-screen bg-gradient-to-br from-primary-50 via-white to-orange-50">
      {/* Hero Section */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        <div className="text-center mb-12">
          <h1 className="text-5xl font-bold text-gray-900 mb-4">
            AI-Powered Travel Planning
          </h1>
          <p className="text-xl text-gray-600 max-w-3xl mx-auto">
            Discover trending destinations from TikTok, powered by AI to create
            your perfect multi-day itinerary with optimized routes
          </p>
        </div>

        {/* Features */}
        <div className="grid md:grid-cols-3 gap-6 mb-12">
          <div className="bg-white rounded-lg p-6 shadow-sm">
            <div className="text-4xl mb-3">🎵</div>
            <h3 className="text-lg font-semibold text-gray-900 mb-2">
              TikTok-Powered Discovery
            </h3>
            <p className="text-gray-600 text-sm">
              Find trending spots and hidden gems from real travelers sharing
              their experiences
            </p>
          </div>

          <div className="bg-white rounded-lg p-6 shadow-sm">
            <div className="text-4xl mb-3">🤖</div>
            <h3 className="text-lg font-semibold text-gray-900 mb-2">
              AI Curation
            </h3>
            <p className="text-gray-600 text-sm">
              GPT-4 extracts and summarizes the best points of interest with
              smart deduplication
            </p>
          </div>

          <div className="bg-white rounded-lg p-6 shadow-sm">
            <div className="text-4xl mb-3">🗺️</div>
            <h3 className="text-lg font-semibold text-gray-900 mb-2">
              Smart Routing
            </h3>
            <p className="text-gray-600 text-sm">
              Geographic clustering ensures each day is walkable and
              geographically coherent
            </p>
          </div>
        </div>

        {/* Trip Wizard */}
        <TripWizard />

        {/* How It Works */}
        <div className="mt-16 text-center">
          <h2 className="text-3xl font-bold text-gray-900 mb-8">
            How It Works
          </h2>
          <div className="grid md:grid-cols-4 gap-8 max-w-5xl mx-auto">
            <div>
              <div className="w-12 h-12 bg-primary-500 text-white rounded-full flex items-center justify-center text-xl font-bold mx-auto mb-3">
                1
              </div>
              <h4 className="font-semibold text-gray-900 mb-2">
                Enter Destination
              </h4>
              <p className="text-sm text-gray-600">
                Tell us where you want to go and for how long
              </p>
            </div>

            <div>
              <div className="w-12 h-12 bg-primary-500 text-white rounded-full flex items-center justify-center text-xl font-bold mx-auto mb-3">
                2
              </div>
              <h4 className="font-semibold text-gray-900 mb-2">
                AI Discovery
              </h4>
              <p className="text-sm text-gray-600">
                We scan TikTok for trending content and extract POIs
              </p>
            </div>

            <div>
              <div className="w-12 h-12 bg-primary-500 text-white rounded-full flex items-center justify-center text-xl font-bold mx-auto mb-3">
                3
              </div>
              <h4 className="font-semibold text-gray-900 mb-2">
                Smart Clustering
              </h4>
              <p className="text-sm text-gray-600">
                Locations are grouped into walkable daily itineraries
              </p>
            </div>

            <div>
              <div className="w-12 h-12 bg-primary-500 text-white rounded-full flex items-center justify-center text-xl font-bold mx-auto mb-3">
                4
              </div>
              <h4 className="font-semibold text-gray-900 mb-2">
                Customize & Go
              </h4>
              <p className="text-sm text-gray-600">
                Review on a map, reorder stops, and start exploring
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
};

export default HomePage;

