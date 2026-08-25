export const replayCases = [
  {
    "action": "getDomainAvailability",
    "name": "registered",
    "args": {
      "domain": "openchat.com"
    },
    "output": {
      "domain": "openchat.com",
      "available": false,
      "premium": false,
      "lookupType": "EPP",
      "reason": "Domain exists",
      "createdYear": 1999,
      "registrar": "GoDaddy Online Services Cayman Islands Ltd.",
      "registrationPrice": null,
      "renewalPrice": null,
      "currency": null,
      "url": "https://www.namecheap.com/domains/registration/results/?domain=openchat.com"
    }
  },
  {
    "action": "getDomainAvailability",
    "name": "available",
    "args": {
      "domain": "openchat.ink"
    },
    "output": {
      "domain": "openchat.ink",
      "available": true,
      "premium": false,
      "lookupType": "EPP",
      "reason": null,
      "createdYear": 2024,
      "registrar": "NameCheap, Inc.",
      "registrationPrice": null,
      "renewalPrice": null,
      "currency": null,
      "url": "https://www.namecheap.com/domains/registration/results/?domain=openchat.ink"
    }
  },
  {
    "action": "getDomainAvailability",
    "name": "premium",
    "args": {
      "domain": "openchat.tech"
    },
    "output": {
      "domain": "openchat.tech",
      "available": true,
      "premium": true,
      "lookupType": "EPP",
      "reason": null,
      "createdYear": null,
      "registrar": null,
      "registrationPrice": 81.25,
      "renewalPrice": 325,
      "currency": "USD",
      "url": "https://www.namecheap.com/domains/registration/results/?domain=openchat.tech"
    }
  }
];
