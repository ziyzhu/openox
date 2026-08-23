export const replayCases = [
  {
    "action": "getSignInUrl",
    "name": "default",
    "args": {},
    "output": {
      "url": "https://frontierdermpartners.modmedapp.com/ema/patient-login"
    }
  },
  {
    "action": "getSignInState",
    "name": "default",
    "args": {},
    "output": {
      "signedIn": true
    }
  },
  {
    "action": "getPatientProfile",
    "name": "default",
    "args": {},
    "output": {
      "firstName": "Alex",
      "lastName": "Morgan",
      "dateOfBirth": "1990-01-15",
      "sex": "Not specified",
      "genderIdentity": "Not specified",
      "sexualOrientation": "Not specified",
      "email": "fixture-patient@example.com",
      "phone": "(555) 010-0123",
      "city": "Sample City",
      "state": "[REDACTED]",
      "postalCode": "98101",
      "country": "United States",
      "preferredContactMethod": "Fixture preferredContactMethod",
      "preferredPhoneType": "(555) 010-0123",
      "language": "English",
      "maritalStatus": "ACTIVE",
      "ethnicity": "Not specified",
      "races": [
        "Fixture races"
      ]
    }
  },
  {
    "action": "listPastAppointments",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "id": "fixture-id",
          "date": "2026-01-10T16:00:00Z",
          "finalized": true,
          "provider": "Dr. Rowan Ellis",
          "biller": "Fixture Dermatology",
          "attendees": "Fixture attendees",
          "additionalAttendees": "Fixture additionalAttendees",
          "impressions": "Fixture visit impression",
          "facility": {
            "id": "4242",
            "name": "Fixture Dermatology Clinic",
            "address": "100 Example Ave",
            "phone": "(555) 010-0123",
            "timeZone": "America/Los_Angeles"
          },
          "visitNoteUrl": "https://frontierdermpartners.modmedapp.com/ema/ws/v3/visits/43434343/visit-note"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getMedicationHistory",
    "name": "default",
    "args": {},
    "output": {
      "noneReported": false,
      "items": [
        {
          "id": "4242",
          "name": "Fixture Medication",
          "genericName": "fixture generic",
          "strength": "10",
          "units": "mg",
          "doseForm": "tablet",
          "frequency": "daily",
          "route": "oral",
          "status": "ACTIVE",
          "startedAt": "2026-01-01",
          "duringVisit": false,
          "deletableByPatient": false
        }
      ]
    }
  },
  {
    "action": "listProblems",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "id": "4242",
          "description": "Fixture skin condition"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getAllergySummary",
    "name": "default",
    "args": {},
    "output": {
      "noneKnown": true,
      "otherAllergies": "Fixture contact allergy",
      "recordedAllergyCount": 0
    }
  },
  {
    "action": "getBillingSummary",
    "name": "default",
    "args": {},
    "output": {
      "accounts": [
        {
          "id": "fixture-id",
          "facility": "Fixture locationDisplayName",
          "address": "100 Example Ave",
          "billingType": "Fixture type",
          "outstandingBalance": 25,
          "unallocatedAmount": null,
          "paymentType": "Fixture type"
        }
      ],
      "recentStatements": [
        {
          "id": "4242",
          "statementNumber": "fixture-id",
          "date": "2026-01-01",
          "status": "ACTIVE",
          "totalDue": 1,
          "oldestAgingBalance": "Fixture oldestAgingBalance"
        }
      ]
    }
  },
  {
    "action": "listInsurancePlans",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "id": "4242",
          "company": "Fixture insuranceCompanyName",
          "planType": "Fixture type",
          "active": true,
          "eligibilityActive": true,
          "copayAmount": 25,
          "referralNeeded": false,
          "ranking": 1,
          "insuredName": "Alex Morgan",
          "policyholderName": "Alex Morgan"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listPharmacies",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "id": "4242",
          "name": "Fixture Pharmacy",
          "phone": "(555) 010-0123",
          "fax": "(555) 010-0123",
          "address": "100 Example Ave, 100 Example Ave, Sample City, [REDACTED], 98101",
          "electronicPrescribing": true,
          "default": true
        }
      ],
      "nextCursor": null
    }
  }
];
