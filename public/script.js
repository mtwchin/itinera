let map;
let markers = [];
let currentItinerary = null;
let currentDay = 1;
let googleMapsApiKey = '';

// Initialize
document.addEventListener('DOMContentLoaded', async () => {
    // Get Google Maps API key from server
    try {
        const response = await fetch('/api/config');
        const config = await response.json();
        googleMapsApiKey = config.googleMapsApiKey;
        
        // Load Google Maps script
        const script = document.createElement('script');
        script.src = `https://maps.googleapis.com/maps/api/js?key=${googleMapsApiKey}&libraries=places`;
        script.async = true;
        script.defer = true;
        document.head.appendChild(script);
    } catch (error) {
        console.error('Error loading config:', error);
    }

    // Form submission
    document.getElementById('itineraryForm').addEventListener('submit', handleFormSubmit);
});

async function handleFormSubmit(e) {
    e.preventDefault();
    
    const formData = {
        city: document.getElementById('city').value,
        country: document.getElementById('country').value,
        lengthOfStay: parseInt(document.getElementById('lengthOfStay').value),
        groupSize: parseInt(document.getElementById('groupSize').value),
        budget: document.getElementById('budget').value,
        foodPreferences: document.getElementById('foodPreferences').value,
        mustDo: document.getElementById('mustDo').value
    };

    // Show loading state
    const btn = document.getElementById('generateBtn');
    btn.disabled = true;
    btn.querySelector('.btn-text').style.display = 'none';
    btn.querySelector('.btn-loader').style.display = 'inline-flex';

    try {
        const response = await fetch('/api/generate-itinerary', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(formData)
        });

        const result = await response.json();
        
        if (result.success) {
            currentItinerary = result.data;
            displayItinerary(result.data, formData);
        } else {
            alert('Error generating itinerary: ' + result.error);
        }
    } catch (error) {
        console.error('Error:', error);
        alert('Failed to generate itinerary. Please check your API keys and try again.');
    } finally {
        // Reset button
        btn.disabled = false;
        btn.querySelector('.btn-text').style.display = 'inline';
        btn.querySelector('.btn-loader').style.display = 'none';
    }
}

function displayItinerary(data, formData) {
    // Hide form, show results
    document.getElementById('formSection').style.display = 'none';
    document.getElementById('resultsSection').style.display = 'block';

    // Create day selector
    const daySelector = document.getElementById('daySelector');
    daySelector.innerHTML = '';
    
    data.itinerary.forEach((day, index) => {
        const btn = document.createElement('button');
        btn.className = `day-btn ${index === 0 ? 'active' : ''}`;
        btn.textContent = `Day ${day.day}`;
        btn.onclick = () => selectDay(day.day);
        daySelector.appendChild(btn);
    });

    // Display itinerary content
    const itineraryContent = document.getElementById('itineraryContent');
    itineraryContent.innerHTML = '';

    data.itinerary.forEach((day, index) => {
        const dayDiv = document.createElement('div');
        dayDiv.className = `day-itinerary ${index === 0 ? 'active' : ''}`;
        dayDiv.id = `day-${day.day}`;
        
        let activitiesHtml = '';
        day.activities.forEach(activity => {
            activitiesHtml += `
                <div class="activity-card" data-lat="${activity.coordinates.lat}" data-lng="${activity.coordinates.lng}">
                    <div class="activity-header">
                        <span class="activity-time">${activity.time}</span>
                        <span class="activity-type">${activity.type}</span>
                    </div>
                    <h3 class="activity-name">${activity.name}</h3>
                    <p class="activity-duration">⏱️ ${activity.duration}</p>
                    <p class="activity-description">${activity.description}</p>
                    <p class="activity-address">📍 ${activity.address}</p>
                </div>
            `;
        });

        dayDiv.innerHTML = `
            <h3 class="day-theme">🎯 ${day.theme}</h3>
            ${activitiesHtml}
        `;
        
        itineraryContent.appendChild(dayDiv);
    });

    // Display tips
    if (data.tips && data.tips.length > 0) {
        const tipsSection = document.getElementById('tipsSection');
        tipsSection.style.display = 'block';
        const tipsList = document.getElementById('tipsList');
        tipsList.innerHTML = data.tips.map(tip => `<li>${tip}</li>`).join('');
    }

    // Display budget
    if (data.estimatedBudget) {
        const budgetDiv = document.createElement('div');
        budgetDiv.className = 'budget-estimate';
        budgetDiv.innerHTML = `
            <h3>💰 Estimated Budget</h3>
            <p>${data.estimatedBudget}</p>
        `;
        itineraryContent.appendChild(budgetDiv);
    }

    // Initialize map
    currentDay = 1;
    initializeMap(data, formData);
}

function selectDay(day) {
    currentDay = day;
    
    // Update button states
    document.querySelectorAll('.day-btn').forEach(btn => {
        btn.classList.remove('active');
        if (btn.textContent === `Day ${day}`) {
            btn.classList.add('active');
        }
    });

    // Update itinerary display
    document.querySelectorAll('.day-itinerary').forEach(div => {
        div.classList.remove('active');
    });
    document.getElementById(`day-${day}`).classList.add('active');

    // Update map markers
    updateMapForDay(day);
}

function initializeMap(data, formData) {
    // Get first day's first activity for center
    const firstActivity = data.itinerary[0].activities[0];
    const center = firstActivity.coordinates;

    map = new google.maps.Map(document.getElementById('map'), {
        zoom: 13,
        center: center,
        styles: [
            {
                "elementType": "geometry",
                "stylers": [{ "color": "#1e293b" }]
            },
            {
                "elementType": "labels.text.fill",
                "stylers": [{ "color": "#8b9db8" }]
            },
            {
                "elementType": "labels.text.stroke",
                "stylers": [{ "color": "#0f172a" }]
            },
            {
                "featureType": "road",
                "elementType": "geometry",
                "stylers": [{ "color": "#334155" }]
            },
            {
                "featureType": "water",
                "elementType": "geometry",
                "stylers": [{ "color": "#0f172a" }]
            }
        ]
    });

    // Geocode and add markers for all activities
    geocodeActivities(data);
}

async function geocodeActivities(data) {
    const geocoder = new google.maps.Geocoder();
    
    for (let dayData of data.itinerary) {
        for (let activity of dayData.activities) {
            try {
                const result = await new Promise((resolve, reject) => {
                    geocoder.geocode({ address: activity.address }, (results, status) => {
                        if (status === 'OK') {
                            resolve(results[0].geometry.location);
                        } else {
                            // Use city center as fallback
                            const dayItinerary = data.itinerary.find(d => d.day === dayData.day);
                            resolve(new google.maps.LatLng(
                                dayItinerary.activities[0].coordinates.lat,
                                dayItinerary.activities[0].coordinates.lng
                            ));
                        }
                    });
                });
                
                activity.coordinates = {
                    lat: result.lat(),
                    lng: result.lng()
                };
            } catch (error) {
                console.error('Geocoding error:', error);
            }
        }
    }

    // Update map for current day
    updateMapForDay(currentDay);
}

function updateMapForDay(day) {
    // Clear existing markers
    markers.forEach(marker => marker.setMap(null));
    markers = [];

    const dayData = currentItinerary.itinerary.find(d => d.day === day);
    if (!dayData) return;

    const bounds = new google.maps.LatLngBounds();

    dayData.activities.forEach((activity, index) => {
        const position = new google.maps.LatLng(
            activity.coordinates.lat,
            activity.coordinates.lng
        );

        const marker = new google.maps.Marker({
            position: position,
            map: map,
            title: activity.name,
            label: {
                text: (index + 1).toString(),
                color: 'white',
                fontSize: '14px',
                fontWeight: 'bold'
            },
            animation: google.maps.Animation.DROP
        });

        const infoWindow = new google.maps.InfoWindow({
            content: `
                <div style="color: #0f172a; padding: 10px; max-width: 200px;">
                    <h3 style="margin: 0 0 5px 0; font-size: 16px;">${activity.name}</h3>
                    <p style="margin: 0; font-size: 12px;">${activity.time} - ${activity.duration}</p>
                    <p style="margin: 5px 0 0 0; font-size: 13px;">${activity.description}</p>
                </div>
            `
        });

        marker.addListener('click', () => {
            infoWindow.open(map, marker);
        });

        markers.push(marker);
        bounds.extend(position);
    });

    // Fit map to markers
    if (markers.length > 0) {
        map.fitBounds(bounds);
    }
}

function exportToGoogleMaps() {
    const dayData = currentItinerary.itinerary.find(d => d.day === currentDay);
    if (!dayData) return;

    // Create Google Maps URL with waypoints
    const baseUrl = 'https://www.google.com/maps/dir/';
    const waypoints = dayData.activities.map(activity => 
        `${activity.coordinates.lat},${activity.coordinates.lng}`
    ).join('/');

    const url = baseUrl + waypoints;
    window.open(url, '_blank');
}

async function refineItinerary() {
    const feedback = document.getElementById('refineFeedback').value;
    if (!feedback.trim()) {
        alert('Please enter your feedback or changes.');
        return;
    }

    try {
        const response = await fetch('/api/refine-itinerary', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                currentItinerary,
                userFeedback: feedback
            })
        });

        const result = await response.json();
        
        if (result.success) {
            currentItinerary = result.data;
            displayItinerary(result.data, {});
            document.getElementById('refineFeedback').value = '';
        } else {
            alert('Error refining itinerary: ' + result.error);
        }
    } catch (error) {
        console.error('Error:', error);
        alert('Failed to refine itinerary.');
    }
}

function resetForm() {
    document.getElementById('formSection').style.display = 'block';
    document.getElementById('resultsSection').style.display = 'none';
    document.getElementById('itineraryForm').reset();
    currentItinerary = null;
    currentDay = 1;
}

