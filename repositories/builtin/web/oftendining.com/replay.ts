export const replayCases = [
  {
    "action": "getProfile",
    "name": "default",
    "args": {},
    "output": {
      "firstName": "Alex",
      "lastName": "Morgan",
      "phone": "(555) 010-0123",
      "vehicle": {
        "make": "",
        "model": "",
        "color": "",
        "licensePlate": ""
      }
    }
  },
  {
    "action": "listOrders",
    "name": "default",
    "args": {},
    "output": {
      "items": [
        {
          "id": "42424000",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 01",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20
        },
        {
          "id": "42424001",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 02",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.1
        },
        {
          "id": "42424002",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 03",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.2
        },
        {
          "id": "42424003",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 04",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.6
        },
        {
          "id": "42424004",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 05",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.6
        },
        {
          "id": "42424005",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 06",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.5
        },
        {
          "id": "42424006",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 07",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.6
        },
        {
          "id": "42424007",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 08",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.7
        },
        {
          "id": "42424008",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 09",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.8
        },
        {
          "id": "42424009",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 10",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 20.9
        }
      ],
      "nextCursor": "10"
    }
  },
  {
    "action": "listOrders",
    "name": "next-page",
    "args": {
      "cursor": "10"
    },
    "output": {
      "items": [
        {
          "id": "42424010",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "Jan 11",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 21
        },
        {
          "id": "42424011",
          "storeId": "13620",
          "typeId": 101,
          "orderedOn": "01-15-2025",
          "restaurant": "Fixture Restaurant",
          "status": "Confirmed",
          "total": 21.1
        }
      ],
      "nextCursor": null
    }
  }
];
