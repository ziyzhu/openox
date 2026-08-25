export const replayCases = [
  {
    "action": "getSignInUrl",
    "name": "default",
    "args": {},
    "output": {
      "url": "https://www.usvisascheduling.com/en-US/schedule/"
    }
  },
  {
    "action": "getSignInState",
    "name": "signed-in",
    "args": {},
    "output": {
      "signedIn": true
    }
  },
  {
    "action": "getAppointmentAvailability",
    "name": "none-available",
    "args": {},
    "output": {
      "post": "Fixture Consular Post",
      "applicantCount": 1,
      "visaClasses": [
        "Fixture Visa Class"
      ],
      "available": false,
      "dates": []
    },
    "replay": {
      "ignoreQueryParameters": [
        "cacheString"
      ]
    }
  }
];
