export const replayCases = [
  {
    "action": "getSignInUrl",
    "name": "trusted",
    "args": {},
    "output": {
      "url": "https://outlook.live.com/mail/"
    }
  },
  {
    "action": "getSignInState",
    "name": "signed-out",
    "args": {},
    "output": {
      "signedIn": false
    }
  },
  {
    "action": "listFolders",
    "name": "visible",
    "args": {},
    "output": {
      "items": [
        {
          "id": "inbox",
          "name": "Inbox",
          "unreadCount": 2
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listMessages",
    "name": "visible",
    "args": {
      "folderId": "inbox",
      "limit": 25,
      "cursor": null
    },
    "output": {
      "items": [
        {
          "id": "fixture-message",
          "conversationId": "fixture-message",
          "subject": "Fixture Subject",
          "sender": "Fixture Sender",
          "receivedText": "Mon 9:00 AM",
          "isUnread": true,
          "preview": "Fixture preview"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "searchMessages",
    "name": "visible",
    "args": {
      "query": "fixture",
      "limit": 25,
      "cursor": null
    },
    "output": {
      "items": [
        {
          "id": "fixture-message",
          "conversationId": "fixture-message",
          "subject": "Fixture Subject",
          "sender": "Fixture Sender",
          "receivedText": "Mon 9:00 AM",
          "isUnread": true,
          "preview": "Fixture preview"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getMessage",
    "name": "visible",
    "args": {
      "id": "fixture-message"
    },
    "output": {
      "id": "fixture-message",
      "subject": "Fixture Subject",
      "sender": "Fixture Sender",
      "recipients": [
        "Fixture Recipient"
      ],
      "receivedText": "Mon 8/24/2026 9:00 AM",
      "bodyText": "Fixture message body",
      "attachmentNames": [
        "Fixture attachment"
      ]
    }
  },
  {
    "action": "listCalendars",
    "name": "visible",
    "args": {},
    "output": {
      "items": [
        {
          "id": "mysbw8",
          "name": "Fixture Calendar",
          "selected": true
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listEvents",
    "name": "visible",
    "args": {
      "start": "2026-08-01T00:00:00-07:00",
      "end": "2026-09-01T00:00:00-07:00",
      "calendarId": null,
      "limit": 50,
      "cursor": null
    },
    "output": {
      "items": [
        {
          "id": "fixture-event",
          "subject": "Fixture Event",
          "startText": "9:00 AM",
          "endText": "9:30 AM",
          "location": "",
          "allDay": false
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getEvent",
    "name": "visible",
    "args": {
      "id": "fixture-event"
    },
    "output": {
      "id": "fixture-event",
      "subject": "Fixture Event",
      "timeText": "9:00 AM to 9:30 AM",
      "location": "Fixture Room",
      "organizer": "Fixture Organizer",
      "attendees": [
        "Fixture Attendee"
      ],
      "bodyText": "Fixture Event 9:00 AM to 9:30 AM Fixture Room Fixture Organizer Fixture Attendee Fixture event body"
    }
  }
];
