import Foundation

extension Itinerary {
    static let preview = Itinerary(
        itinerary: [
            ItineraryDay(
                day: 1,
                theme: "Tiles, viewpoints & old Lisbon",
                activities: [
                    Activity(
                        time: "09:00",
                        name: "Miradouro da Senhora do Monte",
                        type: "nature",
                        duration: "1 hr",
                        description: "Start above the terracotta rooftops with one of the city's widest views.",
                        address: "Largo Monte, Lisbon",
                        coordinates: Coordinates(lat: 38.7191, lng: -9.1327)
                    ),
                    Activity(
                        time: "11:00",
                        name: "Alfama lanes",
                        type: "culture",
                        duration: "2 hrs",
                        description: "Follow tiled facades, small squares, and the sound of morning fado rehearsals.",
                        address: "Alfama, Lisbon",
                        coordinates: Coordinates(lat: 38.7112, lng: -9.1293)
                    ),
                    Activity(
                        time: "13:30",
                        name: "Prado",
                        type: "food",
                        duration: "1.5 hrs",
                        description: "Seasonal Portuguese plates in a bright former canning factory.",
                        address: "Tv. Pedras Negras 2, Lisbon",
                        coordinates: Coordinates(lat: 38.7102, lng: -9.1343)
                    )
                ]
            ),
            ItineraryDay(
                day: 2,
                theme: "Belém by the river",
                activities: [
                    Activity(
                        time: "09:30",
                        name: "Jerónimos Monastery",
                        type: "culture",
                        duration: "2 hrs",
                        description: "Explore the cloisters before the riverside crowds arrive.",
                        address: "Praça do Império, Lisbon",
                        coordinates: Coordinates(lat: 38.6979, lng: -9.2065)
                    ),
                    Activity(
                        time: "12:00",
                        name: "Pastéis de Belém",
                        type: "food",
                        duration: "45 min",
                        description: "Try the original custard tart while it is still warm.",
                        address: "R. de Belém 84 92, Lisbon",
                        coordinates: Coordinates(lat: 38.6975, lng: -9.2032)
                    )
                ]
            ),
            ItineraryDay(
                day: 3,
                theme: "Markets & modern Lisbon",
                activities: [
                    Activity(
                        time: "10:00",
                        name: "LX Factory",
                        type: "shopping",
                        duration: "2 hrs",
                        description: "Browse independent shops and studios beneath the bridge.",
                        address: "R. Rodrigues de Faria 103, Lisbon",
                        coordinates: Coordinates(lat: 38.7037, lng: -9.1785)
                    )
                ]
            )
        ],
        tips: [
            "Wear shoes with grip—the calçada streets become slick after rain.",
            "Keep a reusable transit card for the trams and metro."
        ],
        accommodationInfo: AccommodationInfo(
            morningStart: "Leave by 08:30",
            eveningReturn: "Back around 21:00",
            transportationTips: "Use the metro for longer hops and walk the historic center."
        ),
        estimatedBudget: "€180–€240 per person"
    )
}
