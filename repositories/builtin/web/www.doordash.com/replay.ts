export const replayCases = [
  {
    "action": "getSignInUrl",
    "name": "login",
    "args": {},
    "output": {
      "url": "https://identity.doordash.com/auth?client_id=1666519390426295040&intl=en-US&is_iframe_modal=true&last_login_action=login&last_login_method=google&layout=identity_web_iframe&prompt=none&redirect_uri=https%3A%2F%2Fwww.doordash.com%2Fpost-login%2F&response_type=code&scope=*&state=%2F"
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
    "action": "getStore",
    "name": "available",
    "args": {
      "storeId": "fixture-store"
    },
    "output": {
      "store": {
        "id": "fixture-store",
        "name": "Fixture Market",
        "description": "Groceries and everyday essentials",
        "url": "https://www.doordash.com/store/fixture-store",
        "imageUrl": "https://example.com/store.png",
        "isActive": true,
        "deliveryAvailable": true,
        "eta": "25 min",
        "unavailableReason": null,
        "distance": "1.2 mi",
        "priceRange": "$$",
        "rating": 4.7,
        "ratingCount": 321
      }
    },
    "replay": {
      "ignoreBodyParameters": [
        "query"
      ]
    }
  },
  {
    "action": "searchStoreItems",
    "name": "first-page",
    "args": {
      "storeId": "fixture-store",
      "query": "milk",
      "limit": 2
    },
    "output": {
      "items": [
        {
          "id": "fixture-milk",
          "storeId": "fixture-store",
          "name": "Whole Milk",
          "description": "One gallon",
          "imageUrl": "https://example.com/milk.png",
          "price": {
            "amount": 4.99,
            "currency": "USD",
            "display": "$4.99"
          },
          "unit": "1 gal",
          "rating": 4.8,
          "ratingCount": 90,
          "additionalVariants": null,
          "canQuickAdd": true,
          "defaultQuantity": 1
        },
        {
          "id": "fixture-oat-milk",
          "storeId": "fixture-store",
          "name": "Oat Milk",
          "description": null,
          "imageUrl": null,
          "price": {
            "amount": 5.49,
            "currency": "USD",
            "display": "$5.49"
          },
          "unit": null,
          "rating": null,
          "ratingCount": null,
          "additionalVariants": null,
          "canQuickAdd": false,
          "defaultQuantity": 1
        }
      ],
      "nextCursor": "fixture-next"
    },
    "replay": {
      "ignoreBodyParameters": [
        "query"
      ]
    }
  },
  {
    "action": "getCart",
    "name": "empty",
    "args": {},
    "output": {
      "cart": null
    },
    "replay": {
      "ignoreBodyParameters": [
        "query"
      ]
    }
  },
  {
    "action": "listOrders",
    "name": "recent",
    "args": {
      "limit": 1
    },
    "output": {
      "items": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "url": "https://www.doordash.com/orders/11111111-1111-1111-1111-111111111111",
          "summary": "Fixture Market Delivered July 1, 2026 Total $12.34 View Receipt"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getOrder",
    "name": "receipt",
    "args": {
      "orderCartId": "11111111-1111-1111-1111-111111111111"
    },
    "output": {
      "order": {
        "id": "11111111-1111-1111-1111-111111111111",
        "url": "https://www.doordash.com/orders/11111111-1111-1111-1111-111111111111",
        "storeName": "Fixture Market",
        "commissionMessage": null,
        "disclaimer": null,
        "total": {
          "amount": 12.34,
          "currency": "USD",
          "display": "$12.34"
        },
        "lineItems": [
          {
            "label": "Subtotal",
            "note": null,
            "amount": {
              "amount": 10,
              "currency": "USD",
              "display": "$10.00"
            },
            "originalAmount": null
          },
          {
            "label": "Total",
            "note": null,
            "amount": {
              "amount": 12.34,
              "currency": "USD",
              "display": "$12.34"
            },
            "originalAmount": null
          }
        ],
        "items": [
          {
            "id": "fixture-order-item",
            "itemId": "fixture-milk",
            "name": "Whole Milk",
            "description": "One gallon",
            "quantity": 2,
            "originalQuantity": 2,
            "unitPrice": {
              "amount": 4.99,
              "currency": "USD",
              "display": "$4.99"
            },
            "options": [],
            "specialInstructions": null,
            "substitutionPreference": null
          }
        ]
      }
    },
    "replay": {
      "ignoreBodyParameters": [
        "query"
      ]
    }
  },
  {
    "action": "getPaymentUrl",
    "name": "checkout",
    "args": {},
    "output": {
      "url": "https://www.doordash.com/consumer/checkout/"
    }
  },
  {
    "action": "getPaymentState",
    "name": "unchanged",
    "args": {
      "previousOrderId": "11111111-1111-1111-1111-111111111111"
    },
    "output": {
      "status": "none",
      "reference": null,
      "total": 0,
      "currency": "USD",
      "completedAt": null
    },
    "replay": {
      "ignoreBodyParameters": [
        "query"
      ]
    }
  }
];
