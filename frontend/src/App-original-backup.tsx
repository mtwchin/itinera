import { useState, useEffect } from 'react'
import './App.css'

// Declare Google Maps types
declare global {
        interface Window {
                google: any;
                initAutocomplete: () => void;
        }
}

interface Activity {
        time: string
        name: string
        type: string
        duration: string
        description: string
        address: string
}

interface DayItinerary {
        day: number
        theme: string
        activities: Activity[]
}

interface Itinerary {
        itinerary: DayItinerary[]
        tips?: string[]
        estimatedBudget?: string
}

function App() {
        const [destination, setDestination] = useState('')
        const [accommodation, setAccommodation] = useState('')
        const [arrivalDate, setArrivalDate] = useState('')
        const [departureDate, setDepartureDate] = useState('')
        const [budget, setBudget] = useState('Medium')
        const [wakeUpTime, setWakeUpTime] = useState('08:00')
        const [loading, setLoading] = useState(false)
        const [itinerary, setItinerary] = useState<Itinerary | null>(null)
        const [currentDay, setCurrentDay] = useState(1)
        const [mapInstance, setMapInstance] = useState<any>(null)
        const [mapMarker, setMapMarker] = useState<any>(null)
        const [mapLoaded, setMapLoaded] = useState(false)

        // Initialize Google Maps and Places Autocomplete
        useEffect(() => {
                // Check if already loaded
                if (window.google?.maps) {
                        initializeMapAndAutocomplete()
                        return
                }

                const script = document.createElement('script')
                script.src = `https://maps.googleapis.com/maps/api/js?key=${import.meta.env.VITE_GOOGLE_MAPS_KEY || ''}&libraries=places`
                script.async = true
                script.defer = true

                script.onload = () => {
                        console.log('Google Maps loaded')
                        initializeMapAndAutocomplete()
                }

                script.onerror = () => {
                        console.error('Failed to load Google Maps script')
                }

                document.head.appendChild(script)

                return () => {
                        // Don't remove script on cleanup to avoid issues
                }
        }, [])

        const initializeMapAndAutocomplete = () => {
                if (!window.google?.maps) {
                        console.error('Google Maps not available - check API key in .env')
                        return
                }

                // Initialize background map first
                const mapElement = document.getElementById('background-map')
                if (mapElement && !mapInstance) {
                        console.log('Initializing map...', 'API Key:', import.meta.env.VITE_GOOGLE_MAPS_KEY ? 'Present' : 'Missing')
                        const map = new window.google.maps.Map(mapElement, {
                                center: { lat: 20, lng: 0 },
                                zoom: 2.5,
                                disableDefaultUI: false,
                                zoomControl: true,
                                mapTypeControl: false,
                                streetViewControl: false,
                                fullscreenControl: false,
                                gestureHandling: 'greedy',
                                styles: [
                                        {
                                                featureType: 'poi',
                                                elementType: 'labels',
                                                stylers: [{ visibility: 'off' }]
                                        }
                                ]
                        })

                        setMapInstance(map)
                        setMapLoaded(true)
                        console.log('Map initialized successfully!')

                        // Add click listener to map
                        map.addListener('click', async (e: any) => {
                                const lat = e.latLng.lat()
                                const lng = e.latLng.lng()

                                console.log('Map clicked:', lat, lng)

                                // Reverse geocode to get city name
                                try {
                                        const response = await fetch(`/reverse_geocode?lat=${lat}&lng=${lng}`)
                                        const data = await response.json()

                                        if (data.success && data.address) {
                                                setDestination(data.address)

                                                // Add or update marker
                                                if (mapMarker) {
                                                        mapMarker.setPosition(e.latLng)
                                                        mapMarker.setTitle(data.address)
                                                } else {
                                                        const newMarker = new window.google.maps.Marker({
                                                                position: e.latLng,
                                                                map: map,
                                                                title: data.address,
                                                                animation: window.google.maps.Animation.DROP
                                                        })
                                                        setMapMarker(newMarker)
                                                }
                                        }
                                } catch (error) {
                                        console.error('Reverse geocoding error:', error)
                                }
                        })
                }

                // Initialize autocomplete
                const input = document.getElementById('destination-input') as HTMLInputElement
                if (input && window.google?.maps?.places) {
                        const autocomplete = new window.google.maps.places.Autocomplete(input, {
                                types: ['(cities)']
                        })

                        autocomplete.addListener('place_changed', () => {
                                const place = autocomplete.getPlace()
                                if (place.formatted_address) {
                                        setDestination(place.formatted_address)

                                        // Center map on selected place
                                        if (place.geometry && mapInstance) {
                                                mapInstance.setCenter(place.geometry.location)
                                                mapInstance.setZoom(10)

                                                // Add or update marker
                                                if (mapMarker) {
                                                        mapMarker.setPosition(place.geometry.location)
                                                        mapMarker.setTitle(place.formatted_address)
                                                } else {
                                                        const newMarker = new window.google.maps.Marker({
                                                                position: place.geometry.location,
                                                                map: mapInstance,
                                                                title: place.formatted_address,
                                                                animation: window.google.maps.Animation.DROP
                                                        })
                                                        setMapMarker(newMarker)
                                                }
                                        }
                                }
                        })
                }
        }

        const handleSubmit = async (e: React.FormEvent) => {
                e.preventDefault()
                setLoading(true)

                try {
                        const arrival = new Date(arrivalDate)
                        const departure = new Date(departureDate)
                        const days = Math.ceil((departure.getTime() - arrival.getTime()) / (1000 * 60 * 60 * 24))

                        const response = await fetch('/api/generate-itinerary', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify({
                                        city: destination.split(',')[0]?.trim(),
                                        country: destination.split(',')[1]?.trim(),
                                        accommodation: { address: accommodation, lat: 0, lng: 0 },
                                        arrivalDate,
                                        departureDate,
                                        budget,
                                        lengthOfStay: days || 3,
                                        wakeUpTime,
                                        foodPreferences: '',
                                        mustDo: ''
                                })
                        })

                        const result = await response.json()
                        console.log('Full response:', result)

                        if (result.success && result.data) {
                                setItinerary(result.data)
                        } else {
                                alert('Error: ' + (result.error || 'Unknown error'))
                        }
                } catch (error) {
                        console.error('Error:', error)
                        alert('Failed to generate itinerary')
                } finally {
                        setLoading(false)
                }
        }

        const handleArrivalChange = (value: string) => {
                setArrivalDate(value)
                // Auto-set departure to same month if not set
                if (!departureDate && value) {
                        const arrival = new Date(value)
                        const departure = new Date(arrival)
                        departure.setDate(arrival.getDate() + 3)
                        departure.setHours(12, 0, 0, 0)
                        setDepartureDate(departure.toISOString().slice(0, 16))
                }
        }

        const exportToGoogleMaps = () => {
                if (!itinerary) return
                const dayData = itinerary.itinerary.find(d => d.day === currentDay)
                if (!dayData) return

                const waypoints = dayData.activities
                        .map(a => `${encodeURIComponent(a.address)}`)
                        .join('/')

                const url = `https://www.google.com/maps/dir/${waypoints}`
                window.open(url, '_blank')
        }

        const resetForm = () => {
                setItinerary(null)
                setCurrentDay(1)
        }

        if (itinerary) {
                const dayData = itinerary.itinerary.find(d => d.day === currentDay)

                return (
                        <div className="app-container">
                                {/* Background Map */}
                                <div id="background-map" className="background-map"></div>

                                <div className="itinerary-overlay">
                                        <div className="results-container">
                                                <div className="results-header">
                                                        <div>
                                                                <h1>{destination}</h1>
                                                                <p>{itinerary.itinerary.length} days itinerary</p>
                                                        </div>
                                                        <button onClick={resetForm} className="btn-secondary">New Trip</button>
                                                </div>

                                                <div className="day-tabs">
                                                        {itinerary.itinerary.map(day => (
                                                                <button
                                                                        key={day.day}
                                                                        className={`day-tab ${currentDay === day.day ? 'active' : ''}`}
                                                                        onClick={() => setCurrentDay(day.day)}
                                                                >
                                                                        Day {day.day}
                                                                </button>
                                                        ))}
                                                </div>

                                                {dayData && (
                                                        <div className="day-content">
                                                                <h2 className="day-theme">{dayData.theme}</h2>

                                                                <div className="activities">
                                                                        {dayData.activities.map((activity, idx) => (
                                                                                <div key={idx} className="activity-card">
                                                                                        <div className="activity-header">
                                                                                                <span className="activity-time">{activity.time}</span>
                                                                                                <span className="activity-type">{activity.type}</span>
                                                                                        </div>
                                                                                        <h3>{activity.name}</h3>
                                                                                        <p className="duration">{activity.duration}</p>
                                                                                        <p className="description">{activity.description}</p>
                                                                                        <p className="address">{activity.address}</p>
                                                                                </div>
                                                                        ))}
                                                                </div>
                                                        </div>
                                                )}

                                                {itinerary.tips && itinerary.tips.length > 0 && (
                                                        <div className="tips-section">
                                                                <h3>Tips</h3>
                                                                <ul>
                                                                        {itinerary.tips.map((tip, idx) => (
                                                                                <li key={idx}>{tip}</li>
                                                                        ))}
                                                                </ul>
                                                        </div>
                                                )}

                                                {itinerary.estimatedBudget && (
                                                        <div className="budget-section">
                                                                <strong>Budget:</strong> {itinerary.estimatedBudget}
                                                        </div>
                                                )}

                                                <div className="export-section">
                                                        <button onClick={exportToGoogleMaps} className="btn-primary">
                                                                Export Day {currentDay} to Google Maps
                                                        </button>
                                                </div>
                                        </div>
                                </div>
                        </div>
                )
        }

        return (
                <div className="app-container">
                        {/* Background Map */}
                        <div id="background-map" className="background-map">
                                {!mapLoaded && (
                                        <div className="map-loading">
                                                <div className="loading-spinner"></div>
                                                <p>Loading map...</p>
                                                {!import.meta.env.VITE_GOOGLE_MAPS_KEY && (
                                                        <p style={{ color: '#ef4444', fontSize: '0.875rem' }}>
                                                                ⚠️ Google Maps API key not found. Check your .env file.
                                                        </p>
                                                )}
                                        </div>
                                )}
                        </div>

                        {/* Map Instructions */}
                        {mapLoaded && !destination && (
                                <div className="map-instructions">
                                        👆 Click anywhere on the map to select your destination
                                </div>
                        )}

                        {/* Form Overlay */}
                        <div className="form-overlay">
                                <div className="form-container">
                                        <div className="logo">
                                                <h1>Itinera</h1>
                                                <p>AI-powered travel planning from TikTok trends</p>
                                        </div>

                                        <form onSubmit={handleSubmit} className="trip-form">
                                                <div className="form-section">
                                                        <h2>Where are you going?</h2>
                                                        <input
                                                                type="text"
                                                                id="destination-input"
                                                                value={destination}
                                                                onChange={(e) => setDestination(e.target.value)}
                                                                placeholder="Click the map or type to search..."
                                                                required
                                                        />
                                                </div>

                                                <div className="form-section">
                                                        <h2>Where are you staying?</h2>
                                                        <input
                                                                type="text"
                                                                value={accommodation}
                                                                onChange={(e) => setAccommodation(e.target.value)}
                                                                placeholder="Hotel name or address"
                                                                required
                                                        />
                                                </div>

                                                <div className="form-section">
                                                        <h2>Trip dates</h2>
                                                        <div className="date-grid">
                                                                <div>
                                                                        <label>Arrival</label>
                                                                        <input
                                                                                type="datetime-local"
                                                                                value={arrivalDate}
                                                                                onChange={(e) => handleArrivalChange(e.target.value)}
                                                                                required
                                                                        />
                                                                </div>
                                                                <div>
                                                                        <label>Departure</label>
                                                                        <input
                                                                                type="datetime-local"
                                                                                value={departureDate}
                                                                                onChange={(e) => setDepartureDate(e.target.value)}
                                                                                required
                                                                        />
                                                                </div>
                                                        </div>
                                                </div>

                                                <div className="form-section">
                                                        <h2>Preferences</h2>
                                                        <div className="preferences-grid">
                                                                <div>
                                                                        <label>Wake up time</label>
                                                                        <input
                                                                                type="time"
                                                                                value={wakeUpTime}
                                                                                onChange={(e) => setWakeUpTime(e.target.value)}
                                                                        />
                                                                </div>
                                                                <div>
                                                                        <label>Budget</label>
                                                                        <select value={budget} onChange={(e) => setBudget(e.target.value)}>
                                                                                <option value="Budget">Budget ($)</option>
                                                                                <option value="Medium">Medium ($$)</option>
                                                                                <option value="Luxury">Luxury ($$$)</option>
                                                                        </select>
                                                                </div>
                                                        </div>
                                                </div>

                                                <button type="submit" disabled={loading} className="btn-primary">
                                                        {loading ? 'Generating...' : 'Generate Itinerary'}
                                                </button>
                                        </form>
                                </div>
                        </div>
                </div>
        )
}

export default App
