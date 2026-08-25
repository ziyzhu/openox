export const replayCases = [
  {
    "action": "getPayTransferUrl",
    "name": "default",
    "args": {},
    "output": {
      "url": "https://secure.bankofamerica.com/pay-transfer-pay-portal/"
    }
  },
  {
    "action": "getSignInUrl",
    "name": "default",
    "args": {},
    "output": {
      "url": "https://secure.bankofamerica.com/auth/signon/"
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
    "action": "listAccounts",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "accountToken": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "name": "EVERYDAY CHECKING 1234",
          "mask": "1234",
          "balance": "$1,234.56"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getAccount",
    "name": "default",
    "args": {
      "accountToken": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    },
    "output": {
      "accountToken": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "name": "EVERYDAY CHECKING 1234",
      "mask": "1234",
      "balance": "$1,234.56"
    }
  },
  {
    "action": "getPaymentActivityFilters",
    "name": "default",
    "args": {},
    "output": {
      "fromAccounts": [
        {
          "identifier": "fixture-from-account",
          "displayName": "Everyday Checking",
          "accountName": "EVERYDAY CHECKING 1234",
          "activityTypes": [
            "TRANSFERS",
            "M2M"
          ]
        }
      ],
      "toAccounts": [
        {
          "identifier": "fixture-to-account",
          "displayName": "Sample Recipient",
          "accountName": "Fixture recipient",
          "activityTypes": [
            "TRANSFERS"
          ]
        }
      ],
      "statuses": [
        "COMPLETED",
        "CANCELLED",
        "FAILED",
        "EXPIRED"
      ],
      "dateOptions": [
        "THREEMONTHS",
        "SIXMONTHS",
        "TWELVEMONTHS",
        "EIGHTEENMONTHS"
      ],
      "activityTypes": [
        "BILLPAY_ALL",
        "ONUS",
        "OFFUS",
        "RFP",
        "TRANSFERS",
        "WIRES_ALL",
        "WIRES",
        "ACH",
        "ZELLE",
        "INTAC",
        "M2M"
      ],
      "fromDate": "2025-08-03",
      "toDate": "2026-08-03"
    }
  },
  {
    "action": "listPaymentActivities",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "id": "fixture-instruction-1",
          "confirmationNumber": "fixture-confirmation-1",
          "source": "EVERYDAY CHECKING 1234",
          "target": "Sample Recipient",
          "amount": 42.5,
          "status": "COMPLETED",
          "type": "M2M",
          "direction": "OUTBOUND",
          "transactionDate": "2026-07-15",
          "createdAt": "2026-07-14",
          "updatedAt": "2026-07-15",
          "category": "TRANSFERS",
          "transferType": "ONE_TIME",
          "memo": "Fixture transfer",
          "cancelEligible": false,
          "editEligible": false,
          "approveEligible": false
        }
      ],
      "nextCursor": null
    }
  }
];
