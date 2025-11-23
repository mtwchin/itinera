import { useState } from 'react'
import './App.css'

function App() {
  const [testMessage] = useState('✅ React is working!')

  return (
    <div className="app-container">
      <div style={{
        position: 'fixed',
        top: '50%',
        left: '50%',
        transform: 'translate(-50%, -50%)',
        background: 'white',
        padding: '3rem',
        borderRadius: '12px',
        boxShadow: '0 20px 60px rgba(0,0,0,0.3)',
        textAlign: 'center',
        zIndex: 1000
      }}>
        <h1 style={{ fontSize: '2rem', marginBottom: '1rem' }}>Itinera</h1>
        <p style={{ fontSize: '1.5rem', color: '#10b981' }}>{testMessage}</p>
        <p style={{ marginTop: '2rem', color: '#64748b' }}>
          If you see this, React is running!
        </p>
        <p style={{ marginTop: '1rem', fontSize: '0.875rem', color: '#94a3b8' }}>
          Backend: http://localhost:5000<br />
          Frontend: http://localhost:3001
        </p>
      </div>
    </div>
  )
}

export default App

