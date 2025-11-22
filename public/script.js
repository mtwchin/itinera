let map;
let markers = [];
let currentItinerary = null;
let currentDay = 1;
let googleMapsApiKey = '';
let tripData = {};

// Initialize
document.addEventListener('DOMContentLoaded', async () => {
    try {
        const response = await fetch('http://localhost:5000/api/config');
        const config = await response.json();
        googleMapsApiKey = config.googleMapsApiKey;
        
        const script = document.createElement('script');
        script.src = `https://maps.googleapis.com/maps/api/js?key=${googleMapsApiKey}&libraries=places`;
        script.async = true;
        script.defer = true;
        document.head.appendChild(script);
    } catch (error) {
        console.error('Error loading config:', error);
    }

    document.getElementById('itineraryForm').addEventListener('submit', handleFormSubmit);
});

async function handleFormSubmit(e) {
    e.preventDefault();
    
    const formData = {
        city: document.getElementById('city').value,
        country: document.getElementById('country').value,
        homeLocation: document.getElementById('homeLocation').value,
        lengthOfStay: parseInt(document.getElementById('lengthOfStay').value),
        groupSize: parseInt(document.getElementById('groupSize').value),
        budget: document.getElementById('budget').value,
        foodPreferences: document.getElementById('foodPreferences').value,
        mustDo: document.getElementById('mustDo').value
    };

    tripData = formData;

    // Show loading state
    const btn = document.getElementById('generateBtn');
    btn.disabled = true;
    btn.querySelector('.btn-text').style.display = 'none';
    btn.querySelector('.btn-loader').style.display = 'inline-flex';

    try {
        const response = await fetch('http://localhost:5000/api/generate-itinerary', {
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
        btn.disabled = false;
        btn.querySelector('.btn-text').style.display = 'inline';
        btn.querySelector('.btn-loader').style.display = 'none';
    }
}

function displayItinerary(data, formData) {
    // Hide form, show results
    document.getElementById('formSection').style.display = 'none';
    document.getElementById('resultsSection').style.display = 'block';

    // Update header
    document.getElementById('tripTitle').textContent = `${formData.city}, ${formData.country}`;
    document.getElementById('tripSubtitle').textContent = 
        `${formData.lengthOfStay} days • ${formData.groupSize} traveler${formData.groupSize > 1 ? 's' : ''} • From ${formData.homeLocation}`;

    // Create day tabs
    const dayTabs = document.getElementById('dayTabs');
    dayTabs.innerHTML = '';
    
    data.itinerary.forEach((day, index) => {
        const tab = document.createElement('button');
        tab.className = `day-tab ${index === 0 ? 'active' : ''}`;
        tab.textContent = `Day ${day.day}`;
        tab.onclick = () => selectDay(day.day);
        dayTabs.appendChild(tab);
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
                <div class="activity-card">
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
            <h2 class="day-theme">${day.theme}</h2>
            ${activitiesHtml}
        `;
        
        itineraryContent.appendChild(dayDiv);
    });

    // Display tips
    if (data.tips && data.tips.length > 0) {
        const tipsCard = document.getElementById('tipsCard');
        tipsCard.style.display = 'block';
        const tipsList = document.getElementById('tipsList');
        tipsList.innerHTML = data.tips.map(tip => `<li>${tip}</li>`).join('');
    }

    // Display budget and travel info
    if (data.estimatedBudget || data.travelInfo) {
        const budgetInfo = document.getElementById('budgetInfo');
        let html = '';
        if (data.estimatedBudget) {
            html += `<p><strong>Budget:</strong> ${data.estimatedBudget}</p>`;
        }
        if (data.travelInfo) {
            html += `<p><strong>From Home:</strong> ${data.travelInfo.fromHome}</p>`;
            html += `<p><strong>Return:</strong> ${data.travelInfo.toHome}</p>`;
        }
        budgetInfo.innerHTML = html;
    }

    // Initialize map
    currentDay = 1;
    initializeMap(data, formData);
}

function selectDay(day) {
    currentDay = day;
    
    // Update tab states
    document.querySelectorAll('.day-tab').forEach(tab => {
        tab.classList.remove('active');
        if (tab.textContent === `Day ${day}`) {
            tab.classList.add('active');
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
    const firstActivity = data.itinerary[0].activities[0];
    const center = firstActivity.coordinates;

    map = new google.maps.Map(document.getElementById('map'), {
        zoom: 13,
        center: center,
        styles: [
            {
                featureType: "poi",
                elementType: "labels",
                stylers: [{ visibility: "off" }]
            }
        ],
        disableDefaultUI: false,
        zoomControl: true,
        mapTypeControl: false,
        streetViewControl: false,
        fullscreenControl: true
    });

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

    updateMapForDay(currentDay);
}

function updateMapForDay(day) {
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
                fontSize: '12px',
                fontWeight: 'bold'
            },
            animation: google.maps.Animation.DROP
        });

        const infoWindow = new google.maps.InfoWindow({
            content: `
                <div style="padding: 12px; max-width: 200px;">
                    <h3 style="margin: 0 0 8px 0; font-size: 14px; font-weight: 600;">${activity.name}</h3>
                    <p style="margin: 0 0 4px 0; font-size: 12px; color: #666;">${activity.time} • ${activity.duration}</p>
                    <p style="margin: 0; font-size: 13px; color: #333;">${activity.description}</p>
                </div>
            `
        });

        marker.addListener('click', () => {
            infoWindow.open(map, marker);
        });

        markers.push(marker);
        bounds.extend(position);
    });

    if (markers.length > 0) {
        map.fitBounds(bounds);
    }
}

function exportToGoogleMaps() {
    const dayData = currentItinerary.itinerary.find(d => d.day === currentDay);
    if (!dayData) return;

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
        const response = await fetch('http://localhost:5000/api/refine-itinerary', {
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
            displayItinerary(result.data, tripData);
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
    currentItinerary = null;
    currentDay = 1;
    tripData = {};
}
