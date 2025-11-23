import { useState } from 'react'
import './App.css'

function App() {
  const [destination, setDestination] = useState('')
  const [accommodation, setAccommodation] = useState('')
  const [arrivalDate, setArrivalDate] = useState('')
  const [departureDate, setDepartureDate] = useState('')
  const [budget, setBudget] = useState('Medium')
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    
    try {
      const response = await fetch('/api/generate-itinerary', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          city: destination.split(',')[0]?.trim(),
          country: destination.split(',')[1]?.trim(),
          accommodation: { address: accommodation },
          arrivalDate,
          departureDate,
          budget
        })
      })
      
      const data = await response.json()
      console.log('Itinerary:', data)
      alert('Itinerary generated! Check console')
    } catch (error) {
      console.error('Error:', error)
      alert('Failed to generate itinerary')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="app">
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
              value={destination}
              onChange={(e) => setDestination(e.target.value)}
              placeholder="e.g., Tokyo, Japan"
              required
            />
          </div>

          <div className="form-section">
            <h2>Where are you staying?</h2>
            <input
              type="text"
              value={accommodation}
              onChange={(e) => setAccommodation(e.target.value)}
              placeholder="Paste Google Maps link or address"
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
                  onChange={(e) => setArrivalDate(e.target.value)}
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
            <h2>Budget</h2>
            <select value={budget} onChange={(e) => setBudget(e.target.value)}>
              <option value="Budget">Budget ($)</option>
              <option value="Medium">Medium ($$)</option>
              <option value="Luxury">Luxury ($$$)</option>
            </select>
          </div>

          <button type="submit" disabled={loading} className="btn-primary">
            {loading ? 'Generating...' : 'Generate Itinerary'}
          </button>
        </form>
      </div>
    </div>
  )
}

export default App
