export const replayCases = [
  {
    "action": "getSignInUrl",
    "name": "default",
    "args": {},
    "output": {
      "url": "https://www.facebook.com/login/"
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
    "action": "listGroupPosts",
    "name": "default",
    "args": {
      "groupId": "123456789",
      "limit": 5
    },
    "output": {
      "items": [
        {
          "id": "fixture-post-1",
          "author": "Fixture Person",
          "message": "Fixture group post",
          "createdAt": 1700000000,
          "url": "https://www.facebook.com/groups/123456789/posts/fixture-post-1/",
          "imageUrl": "https://static.xx.fbcdn.net/fixture-post.png"
        }
      ],
      "nextCursor": "fixture-group-cursor"
    }
  },
  {
    "action": "listGroupPosts",
    "name": "pagination",
    "args": {
      "groupId": "123456789",
      "cursor": "fixture-group-cursor",
      "limit": 5
    },
    "output": {
      "items": [
        {
          "id": "fixture-post-2",
          "author": "Fixture Person",
          "message": "Fixture next group post",
          "createdAt": 1700000000,
          "url": "https://www.facebook.com/groups/123456789/posts/fixture-post-2/",
          "imageUrl": "https://static.xx.fbcdn.net/fixture-post.png"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listFriendSuggestions",
    "name": "default",
    "args": {
      "limit": 20
    },
    "output": {
      "items": [
        {
          "id": "fixture-person-1",
          "name": "Fixture Friend",
          "mutualContext": "2 mutual friends",
          "profilePictureUrl": "https://static.xx.fbcdn.net/fixture-person-1.png",
          "url": "https://www.facebook.com/profile.php?id=fixture-person-1"
        }
      ],
      "nextCursor": "fixture-friends-cursor"
    }
  },
  {
    "action": "listFriendSuggestions",
    "name": "pagination",
    "args": {
      "cursor": "fixture-friends-cursor",
      "limit": 20
    },
    "output": {
      "items": [
        {
          "id": "fixture-person-2",
          "name": "Fixture Next Friend",
          "mutualContext": "2 mutual friends",
          "profilePictureUrl": "https://static.xx.fbcdn.net/fixture-person-2.png",
          "url": "https://www.facebook.com/profile.php?id=fixture-person-2"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listMarketplace",
    "name": "default",
    "args": {
      "latitude": 40,
      "longitude": -75,
      "radiusKm": 65,
      "limit": 12
    },
    "output": {
      "items": [
        {
          "id": "fixture-listing-1",
          "title": "Fixture Lamp",
          "price": "$25",
          "location": "Fixture City, FS",
          "sellerName": "Fixture Seller",
          "createdAt": 1700000000,
          "imageUrl": "https://static.xx.fbcdn.net/fixture-listing-1.png",
          "url": "https://www.facebook.com/marketplace/item/fixture-listing-1/"
        }
      ],
      "nextCursor": "fixture-market-cursor"
    }
  },
  {
    "action": "listMarketplace",
    "name": "pagination",
    "args": {
      "latitude": 40,
      "longitude": -75,
      "radiusKm": 65,
      "cursor": "fixture-market-cursor",
      "limit": 12
    },
    "output": {
      "items": [
        {
          "id": "fixture-listing-2",
          "title": "Fixture Chair",
          "price": "25 USD",
          "location": "Fixture City, FS",
          "sellerName": "Fixture Seller",
          "createdAt": 1700000000,
          "imageUrl": "https://static.xx.fbcdn.net/fixture-listing-2.png",
          "url": "https://www.facebook.com/marketplace/item/fixture-listing-2/"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "searchMarketplace",
    "name": "default",
    "args": {
      "query": "fixture bicycle",
      "latitude": 40,
      "longitude": -75,
      "radiusKm": 65,
      "limit": 24
    },
    "output": {
      "items": [
        {
          "id": "fixture-listing-3",
          "title": "Fixture Bicycle",
          "price": "$25",
          "location": "Fixture City, FS",
          "sellerName": "Fixture Seller",
          "createdAt": 1700000000,
          "imageUrl": "https://static.xx.fbcdn.net/fixture-listing-3.png",
          "url": "https://www.facebook.com/marketplace/item/fixture-listing-3/"
        }
      ],
      "nextCursor": "fixture-search-cursor"
    }
  },
  {
    "action": "searchMarketplace",
    "name": "pagination",
    "args": {
      "query": "fixture bicycle",
      "latitude": 40,
      "longitude": -75,
      "radiusKm": 65,
      "cursor": "fixture-search-cursor",
      "limit": 24
    },
    "output": {
      "items": [
        {
          "id": "fixture-listing-4",
          "title": "Fixture Next Bicycle",
          "price": "$25",
          "location": "Fixture City, FS",
          "sellerName": "Fixture Seller",
          "createdAt": 1700000000,
          "imageUrl": "https://static.xx.fbcdn.net/fixture-listing-4.png",
          "url": "https://www.facebook.com/marketplace/item/fixture-listing-4/"
        }
      ],
      "nextCursor": null
    }
  }
];
