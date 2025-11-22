import React from 'react';

interface LoadingSpinnerProps {
  message?: string;
  step?: string;
}

const LoadingSpinner: React.FC<LoadingSpinnerProps> = ({ message, step }) => {
  return (
    <div className="flex flex-col items-center justify-center p-12">
      {/* Spinner */}
      <div className="relative w-24 h-24">
        <div className="absolute top-0 left-0 w-full h-full">
          <div className="w-24 h-24 border-8 border-primary-200 border-t-primary-600 rounded-full animate-spin"></div>
        </div>
        <div className="absolute top-0 left-0 w-full h-full flex items-center justify-center">
          <span className="text-4xl">✈️</span>
        </div>
      </div>

      {/* Message */}
      <h3 className="mt-6 text-xl font-semibold text-gray-900">
        {message || 'Creating your perfect itinerary...'}
      </h3>

      {/* Step */}
      {step && (
        <p className="mt-2 text-sm text-gray-600">{step}</p>
      )}

      {/* Progress Steps */}
      <div className="mt-8 space-y-2 text-sm text-gray-500">
        <div className="flex items-center space-x-2">
          <div className="w-2 h-2 bg-primary-500 rounded-full"></div>
          <span>Discovering trending spots on TikTok</span>
        </div>
        <div className="flex items-center space-x-2">
          <div className="w-2 h-2 bg-primary-500 rounded-full"></div>
          <span>Extracting points of interest with AI</span>
        </div>
        <div className="flex items-center space-x-2">
          <div className="w-2 h-2 bg-primary-500 rounded-full"></div>
          <span>Geocoding locations with Google Maps</span>
        </div>
        <div className="flex items-center space-x-2">
          <div className="w-2 h-2 bg-primary-500 rounded-full"></div>
          <span>Optimizing your daily routes</span>
        </div>
      </div>

      <p className="mt-6 text-xs text-gray-400">
        This usually takes 30-60 seconds
      </p>
    </div>
  );
};

export default LoadingSpinner;

