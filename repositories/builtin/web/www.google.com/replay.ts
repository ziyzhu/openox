export const replayCases = [
  {
    "action": "searchPlaces",
    "name": "default",
    "args": {
      "query": "coffee near Pike Place Market",
      "limit": 10
    },
    "output": {
      "items": [
        {
          "id": "fixture-cafe",
          "name": "Example Cafe",
          "url": "https://www.google.com/maps/place/Example+Cafe/@47.61,-122.33,16z/data=!4m2!3m1!1sfixture-cafe",
          "rating": 4.7,
          "reviewCount": 321,
          "details": [
            "Cafe",
            "200 Sample St",
            "Open"
          ],
          "imageUrl": null,
          "latitude": 47.61,
          "longitude": -122.33
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getPlace",
    "name": "default",
    "args": {
      "query": "Synthetic Landmark"
    },
    "output": {
      "id": "fixture-landmark",
      "name": "Synthetic Landmark",
      "url": "https://www.google.com/maps/place/Synthetic+Landmark/@47.6205,-122.3493,17z/data=!4m4!3m3!1sfixture-landmark!3d47.6206!4d-122.3494",
      "address": "100 Example Ave, Seattle, WA",
      "category": "Landmark",
      "rating": 4.6,
      "reviewCount": 12345,
      "priceLevel": "$$",
      "openStatus": "Open",
      "hours": "Open daily, 9 AM to 8 PM",
      "phone": "+1 206-555-0100",
      "website": "https://example.com/landmark",
      "imageUrl": null,
      "latitude": 47.6206,
      "longitude": -122.3494
    }
  },
  {
    "action": "getDirectionsUrl",
    "name": "default",
    "args": {
      "origin": "Pike Place Market",
      "destination": "Space Needle",
      "travelMode": "walking"
    },
    "output": {
      "url": "https://www.google.com/maps/dir/?api=1&destination=Space+Needle&travelmode=walking&origin=Pike+Place+Market"
    }
  }
];
