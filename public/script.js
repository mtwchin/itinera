let map;
let destinationMap;
let destinationMarker;
let markers = [];
let currentItinerary = null;
let currentDay = 1;
let googleMapsApiKey = '';
let tripData = {};
let autocomplete;

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
                script.onload = initializeAutocomplete;
                document.head.appendChild(script);
        } catch (error) {
                console.error('Error loading config:', error);
        }

    document.getElementById('itineraryForm').addEventListener('submit', handleFormSubmit);
    
    // Add accommodation link listener
    const accommodationInput = document.getElementById('accommodationLink');
    accommodationInput.addEventListener('blur', handleAccommodationLink);
    accommodationInput.addEventListener('paste', (e) => {
        setTimeout(() => handleAccommodationLink(e), 100);
    });
    
    // Initialize must-do list
    initializeMustDoList();
    
    // Set default dates (tomorrow to 3 days later)
    setDefaultDates();
});

function setDefaultDates() {
    const now = new Date();
    const tomorrow = new Date(now);
    tomorrow.setDate(tomorrow.getDate() + 1);
    tomorrow.setHours(14, 0, 0, 0); // 2 PM arrival
    
    const departure = new Date(tomorrow);
    departure.setDate(departure.getDate() + 2); // 3 days total
    departure.setHours(12, 0, 0, 0); // 12 PM departure
    
    document.getElementById('arrivalDate').value = formatDateTimeLocal(tomorrow);
    document.getElementById('departureDate').value = formatDateTimeLocal(departure);
}

function formatDateTimeLocal(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');
    return `${year}-${month}-${day}T${hours}:${minutes}`;
}

function initializeMustDoList() {
    const mustDoList = document.getElementById('mustDoList');
    
    // Add input listeners to all existing inputs
    const inputs = mustDoList.querySelectorAll('.must-do-input');
    inputs.forEach((input, index) => {
        input.addEventListener('input', function() {
            handleMustDoInput(this, index);
        });
    });
}

function handleMustDoInput(input, index) {
    const mustDoList = document.getElementById('mustDoList');
    const allInputs = mustDoList.querySelectorAll('.must-do-input');
    
    // Add checkmark if filled
    if (input.value.trim()) {
        input.classList.add('filled');
    } else {
        input.classList.remove('filled');
    }
    
    // If this is the last input and it has content, add a new one
    if (index === allInputs.length - 1 && input.value.trim()) {
        const newInput = document.createElement('input');
        newInput.type = 'text';
        newInput.className = 'must-do-input';
        newInput.placeholder = 'Add another activity...';
        newInput.addEventListener('input', function() {
            handleMustDoInput(this, allInputs.length);
        });
        mustDoList.appendChild(newInput);
    }
}

function getMustDoActivities() {
    const inputs = document.querySelectorAll('.must-do-input');
    const activities = [];
    inputs.forEach(input => {
        if (input.value.trim()) {
            activities.push(input.value.trim());
        }
    });
    return activities.join('; ');
}

function initializeAutocomplete() {
        // Initialize Places Autocomplete on city search
        const cityInput = document.getElementById('citySearch');

        autocomplete = new google.maps.places.Autocomplete(cityInput, {
                types: ['(cities)'],
                fields: ['address_components', 'geometry', 'name', 'formatted_address']
        });

        autocomplete.addListener('place_changed', () => {
                const place = autocomplete.getPlace();

                if (place.geometry) {
                        updateDestinationFromPlace(place);
                }
        });
}

function updateDestinationFromPlace(place) {
        const addressComponents = place.address_components;
        let city = '';
        let country = '';

        // Extract city and country from address components
        for (let component of addressComponents) {
                if (component.types.includes('locality')) {
                        city = component.long_name;
                } else if (component.types.includes('administrative_area_level_1') && !city) {
                        city = component.long_name;
                }
                if (component.types.includes('country')) {
                        country = component.long_name;
                }
        }

        // Update hidden fields
        document.getElementById('city').value = city || place.name;
        document.getElementById('country').value = country;
        document.getElementById('destinationLat').value = place.geometry.location.lat();
        document.getElementById('destinationLng').value = place.geometry.location.lng();

        // Update display
        document.getElementById('citySearch').value = `${city || place.name}, ${country}`;
}

function toggleMapSelector() {
        const modal = document.getElementById('mapSelectorModal');

        if (modal.style.display === 'none') {
                modal.style.display = 'flex';
                initializeDestinationMap();
        } else {
                modal.style.display = 'none';
        }
}

function initializeDestinationMap() {
        if (destinationMap) return; // Already initialized

        destinationMap = new google.maps.Map(document.getElementById('destinationMap'), {
                zoom: 2,
                center: { lat: 20, lng: 0 },
                styles: [
                        {
                                featureType: "poi",
                                elementType: "labels",
                                stylers: [{ visibility: "off" }]
                        }
                ],
                streetViewControl: false,
                mapTypeControl: false
        });

        // Add click listener
        destinationMap.addListener('click', async (e) => {
                const lat = e.latLng.lat();
                const lng = e.latLng.lng();

                // Place marker
                if (destinationMarker) {
                        destinationMarker.setMap(null);
                }

                destinationMarker = new google.maps.Marker({
                        position: { lat, lng },
                        map: destinationMap,
                        animation: google.maps.Animation.DROP
                });

                // Reverse geocode to get city name
                const geocoder = new google.maps.Geocoder();
                try {
                        const result = await new Promise((resolve, reject) => {
                                geocoder.geocode({ location: { lat, lng } }, (results, status) => {
                                        if (status === 'OK' && results[0]) {
                                                resolve(results[0]);
                                        } else {
                                                reject(new Error('Geocoding failed'));
                                        }
                                });
                        });

                        // Extract city and country
                        let city = '';
                        let country = '';

                        for (let component of result.address_components) {
                                if (component.types.includes('locality')) {
                                        city = component.long_name;
                                } else if (component.types.includes('administrative_area_level_1') && !city) {
                                        city = component.long_name;
                                }
                                if (component.types.includes('country')) {
                                        country = component.long_name;
                                }
                        }

                        // Update form fields
                        document.getElementById('city').value = city;
                        document.getElementById('country').value = country;
                        document.getElementById('destinationLat').value = lat;
                        document.getElementById('destinationLng').value = lng;
                        document.getElementById('citySearch').value = `${city}, ${country}`;

                        // Show info window
                        const infoWindow = new google.maps.InfoWindow({
                                content: `
                    <div style="padding: 12px;">
                        <h3 style="margin: 0 0 8px 0; font-size: 14px; font-weight: 600;">${city}, ${country}</h3>
                        <button onclick="toggleMapSelector()" style="background: #2563eb; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 13px;">
                            Select this destination
                        </button>
                    </div>
                `
                        });

                        infoWindow.open(destinationMap, destinationMarker);

                } catch (error) {
                        console.error('Error geocoding:', error);
                }
        });
}

// Close modal when clicking outside
document.addEventListener('click', (e) => {
        const modal = document.getElementById('mapSelectorModal');
        if (e.target === modal) {
                toggleMapSelector();
        }
});

async function handleAccommodationLink(e) {
        const link = e.target.value.trim();
        const preview = document.getElementById('locationPreview');
        const details = document.getElementById('locationDetails');
        const errorDiv = document.getElementById('locationError');
        const errorMsg = document.getElementById('errorMessage');

        // Hide both preview and error initially
        errorDiv.style.display = 'none';
        preview.style.display = 'none';

        if (!link) {
                return;
        }

        try {
                // Check if it's a shortened link
                if (link.includes('goo.gl') || link.includes('maps.app.goo.gl')) {
                        // Try to expand via backend
                        preview.style.display = 'block';
                        details.innerHTML = '<p>Resolving shortened link...</p>';

                        const expandResponse = await fetch('http://localhost:5000/api/expand-maps-url', {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/json' },
                                body: JSON.stringify({ url: link })
                        });

                        const expandResult = await expandResponse.json();

                        if (expandResult.success && expandResult.coordinates) {
                                await displayLocationFromCoordinates(
                                        expandResult.coordinates.lat,
                                        expandResult.coordinates.lng,
                                        e.target,
                                        preview,
                                        details,
                                        errorDiv,
                                        errorMsg
                                );
                                return;
                        }
                }

                // Try to parse regular Google Maps link
                const locationData = parseGoogleMapsLink(link);

                if (locationData) {
                        await displayLocationFromCoordinates(
                                locationData.lat,
                                locationData.lng,
                                e.target,
                                preview,
                                details,
                                errorDiv,
                                errorMsg
                        );
                } else {
                        // Show inline error instead of alert
                        showLocationError(errorDiv, errorMsg, 'Cannot read this link format. Try: Share → Copy link from Google Maps');
                }
        } catch (error) {
                console.error('Error parsing location:', error);
                showLocationError(errorDiv, errorMsg, 'Unable to load location. Please check your internet connection and try again.');
        }
}

async function displayLocationFromCoordinates(lat, lng, input, preview, details, errorDiv, errorMsg) {
        try {
                preview.style.display = 'block';
                details.innerHTML = '<p>Loading location details...</p>';

                // Geocode to get full address details
                const geocoder = new google.maps.Geocoder();
                const result = await new Promise((resolve, reject) => {
                        geocoder.geocode({
                                location: { lat, lng }
                        }, (results, status) => {
                                if (status === 'OK' && results[0]) {
                                        resolve(results[0]);
                                } else {
                                        reject(new Error('Geocoding failed'));
                                }
                        });
                });

                const formattedAddress = result.formatted_address;

                // Display location details
                details.innerHTML = `
            <p><strong>Address:</strong> ${formattedAddress}</p>
            <p><strong>Coordinates:</strong> ${lat.toFixed(6)}, ${lng.toFixed(6)}</p>
        `;

                // Store for later use
                input.dataset.lat = lat;
                input.dataset.lng = lng;
                input.dataset.address = formattedAddress;

                // Hide error if it was showing
                errorDiv.style.display = 'none';

        } catch (error) {
                console.error('Geocoding error:', error);
                showLocationError(errorDiv, errorMsg, 'Location found but could not load address details. Try a different link.');
                preview.style.display = 'none';
        }
}

function showLocationError(errorDiv, errorMsg, message) {
        errorDiv.style.display = 'flex';
        errorMsg.textContent = message;
        // Auto-hide after 5 seconds
        setTimeout(() => {
                errorDiv.style.display = 'none';
        }, 5000);
}

function parseGoogleMapsLink(link) {
        // Handle different Google Maps URL formats

        // Format 1: maps.google.com/?q=lat,lng
        let match = link.match(/[?&]q=(-?\d+\.?\d*),(-?\d+\.?\d*)/);
        if (match) {
                return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
        }

        // Format 2: @lat,lng (most common)
        match = link.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/);
        if (match) {
                return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
        }

        // Format 3: /place/name/@lat,lng
        match = link.match(/place\/[^\/]+\/@(-?\d+\.\d+),(-?\d+\.\d+)/);
        if (match) {
                return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
        }

        // Format 4: ll=lat,lng
        match = link.match(/[?&]ll=(-?\d+\.\d+),(-?\d+\.\d+)/);
        if (match) {
                return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
        }

        // Format 5: /maps/place/.../@lat,lng,zoom
        match = link.match(/\/maps\/place\/[^@]*@(-?\d+\.\d+),(-?\d+\.\d+),[\d.]+z/);
        if (match) {
                return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
        }

        // Format 6: /maps/@lat,lng,zoom
        match = link.match(/\/maps\/@(-?\d+\.\d+),(-?\d+\.\d+),[\d.]+z/);
        if (match) {
                return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
        }

        return null;
}

async function handleFormSubmit(e) {
        e.preventDefault();

        // Validate destination is selected
        const city = document.getElementById('city').value;
        const country = document.getElementById('country').value;

        if (!city || !country) {
                alert('Please select a destination using the search box or map.');
                return;
        }

        const accommodationInput = document.getElementById('accommodationLink');
        const accommodationData = {
                link: accommodationInput.value,
                lat: parseFloat(accommodationInput.dataset.lat),
                lng: parseFloat(accommodationInput.dataset.lng),
                address: accommodationInput.dataset.address
        };

        if (!accommodationData.lat || !accommodationData.lng) {
                alert('Please wait for accommodation location to be verified.');
                return;
        }

    // Calculate length of stay from dates
    const arrivalDate = new Date(document.getElementById('arrivalDate').value);
    const departureDate = new Date(document.getElementById('departureDate').value);
    const lengthOfStay = Math.ceil((departureDate - arrivalDate) / (1000 * 60 * 60 * 24));
    
    if (lengthOfStay < 1) {
        alert('Departure date must be after arrival date.');
        return;
    }
    
    const formData = {
        city: city,
        country: country,
        accommodation: accommodationData,
        arrivalDate: arrivalDate.toISOString(),
        departureDate: departureDate.toISOString(),
        lengthOfStay: lengthOfStay,
        budget: document.getElementById('budget').value,
        foodPreferences: document.getElementById('foodPreferences').value,
        mustDo: getMustDoActivities()
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
    const arrivalDate = new Date(formData.arrivalDate);
    const departureDate = new Date(formData.departureDate);
    const dateStr = `${arrivalDate.toLocaleDateString('en-US', {month: 'short', day: 'numeric'})} - ${departureDate.toLocaleDateString('en-US', {month: 'short', day: 'numeric', year: 'numeric'})}`;
    
    document.getElementById('tripTitle').textContent = `${formData.city}, ${formData.country}`;
    document.getElementById('tripSubtitle').textContent = 
        `${dateStr} • ${formData.lengthOfStay} days • ${formData.accommodation.address.split(',')[0]}`;

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

        // Display budget and accommodation info
        if (data.estimatedBudget || data.accommodationInfo) {
                const budgetInfo = document.getElementById('budgetInfo');
                let html = '';
                if (data.estimatedBudget) {
                        html += `<p><strong>Budget:</strong> ${data.estimatedBudget}</p>`;
                }
                if (data.accommodationInfo) {
                        html += `<p><strong>Morning Start:</strong> ${data.accommodationInfo.morningStart}</p>`;
                        html += `<p><strong>Evening Return:</strong> ${data.accommodationInfo.eveningReturn}</p>`;
                        if (data.accommodationInfo.transportationTips) {
                                html += `<p><strong>Getting Around:</strong> ${data.accommodationInfo.transportationTips}</p>`;
                        }
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

        // Add accommodation marker (home base)
        if (tripData.accommodation) {
                const accommodationMarker = new google.maps.Marker({
                        position: {
                                lat: tripData.accommodation.lat,
                                lng: tripData.accommodation.lng
                        },
                        map: map,
                        title: 'Your Accommodation',
                        icon: {
                                path: google.maps.SymbolPath.CIRCLE,
                                scale: 10,
                                fillColor: '#2563eb',
                                fillOpacity: 1,
                                strokeColor: '#ffffff',
                                strokeWeight: 3
                        },
                        zIndex: 1000
                });

                const accommodationInfo = new google.maps.InfoWindow({
                        content: `
                <div style="padding: 12px; max-width: 200px;">
                    <h3 style="margin: 0 0 8px 0; font-size: 14px; font-weight: 600; color: #2563eb;">🏠 Your Accommodation</h3>
                    <p style="margin: 0; font-size: 13px; color: #333;">${tripData.accommodation.address}</p>
                </div>
            `
                });

                accommodationMarker.addListener('click', () => {
                        accommodationInfo.open(map, accommodationMarker);
                });

                markers.push(accommodationMarker);
                bounds.extend({
                        lat: tripData.accommodation.lat,
                        lng: tripData.accommodation.lng
                });
        }

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

    // Create Google Maps List URL format
    const listName = `${tripData.city} - Day ${currentDay}`;
    const places = dayData.activities.map((activity, index) => {
        return {
            name: activity.name,
            lat: activity.coordinates.lat,
            lng: activity.coordinates.lng,
            description: activity.description
        };
    });
    
    // Generate shareable Google Maps list
    // Format: https://www.google.com/maps/d/edit?mid=...
    // Since we can't programmatically create My Maps, we'll create a directions link
    // and provide instructions for creating a list
    
    const baseUrl = 'https://www.google.com/maps/dir/';
    const waypoints = dayData.activities.map(activity => 
        `${activity.coordinates.lat},${activity.coordinates.lng}`
    ).join('/');

    const directionsUrl = baseUrl + waypoints;
    
    // Also create a text export for manual list creation
    const listText = `${listName}\n\n` + 
        dayData.activities.map((activity, i) => 
            `${i + 1}. ${activity.name}\n   ${activity.description}\n   ${activity.address}\n`
        ).join('\n');
    
    // Show modal with export options
    showExportModal(directionsUrl, listText, listName);
}

function showExportModal(directionsUrl, listText, listName) {
    const modal = document.createElement('div');
    modal.className = 'export-modal';
    modal.innerHTML = `
        <div class="export-modal-content">
            <div class="export-modal-header">
                <h3>Export Day ${currentDay}</h3>
                <button class="btn-close" onclick="this.closest('.export-modal').remove()">
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <line x1="18" y1="6" x2="6" y2="18"></line>
                        <line x1="6" y1="6" x2="18" y2="18"></line>
                    </svg>
                </button>
            </div>
            <div class="export-modal-body">
                <div class="export-option">
                    <h4>📍 Open Directions</h4>
                    <p>View route with turn-by-turn directions</p>
                    <button class="btn-secondary" onclick="window.open('${directionsUrl}', '_blank')">
                        Open in Google Maps
                    </button>
                </div>
                <div class="export-option">
                    <h4>📋 Copy List</h4>
                    <p>Copy to create your own Google Maps list</p>
                    <textarea readonly style="width: 100%; height: 150px; padding: 10px; border: 1px solid var(--border); border-radius: 8px; font-size: 13px; font-family: monospace;">${listText}</textarea>
                    <button class="btn-secondary" onclick="navigator.clipboard.writeText(\`${listText.replace(/`/g, '\\`')}\`).then(() => alert('Copied to clipboard!'))">
                        Copy to Clipboard
                    </button>
                </div>
                <div class="export-option">
                    <h4>💾 Download</h4>
                    <p>Download as a text file</p>
                    <button class="btn-secondary" onclick="downloadDayItinerary('${listName}', \`${listText.replace(/`/g, '\\`')}\`)">
                        Download .txt
                    </button>
                </div>
            </div>
        </div>
    `;
    document.body.appendChild(modal);
}

function downloadDayItinerary(filename, content) {
    const blob = new Blob([content], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${filename}.txt`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
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
