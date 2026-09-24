export const replayCases = [
  {
    "action": "listProviders",
    "name": "first",
    "args": {
      "limit": 1
    },
    "output": {
      "items": [
        {
          "id": "anthropic",
          "name": "Anthropic",
          "api": null,
          "doc": "https://docs.anthropic.com/en/docs/about-claude/models",
          "npm": "@ai-sdk/anthropic",
          "env": [
            "ANTHROPIC_API_KEY"
          ],
          "modelCount": 2
        }
      ],
      "nextCursor": "google-vertex"
    }
  },
  {
    "action": "listProviders",
    "name": "terminal",
    "args": {
      "limit": 1,
      "cursor": "google-vertex"
    },
    "output": {
      "items": [
        {
          "id": "google-vertex",
          "name": "Vertex",
          "api": null,
          "doc": "https://cloud.google.com/vertex-ai/generative-ai/docs/models",
          "npm": "@ai-sdk/google-vertex",
          "env": [
            "GOOGLE_VERTEX_PROJECT",
            "GOOGLE_VERTEX_LOCATION",
            "GOOGLE_APPLICATION_CREDENTIALS"
          ],
          "modelCount": 1
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listProviders",
    "name": "invalid-cursor",
    "args": {
      "cursor": "missing"
    },
    "error": "Invalid or expired cursor"
  },
  {
    "action": "searchModels",
    "name": "first",
    "args": {
      "query": "claude",
      "provider": "anthropic",
      "limit": 1
    },
    "output": {
      "items": [
        {
          "id": "claude-sonnet-4-6",
          "name": "Claude Sonnet 4.6",
          "providerId": "anthropic",
          "providerName": "Anthropic",
          "family": "claude-sonnet",
          "description": "Claude workhorse for coding agents, careful analysis, and production cost control",
          "modalities": {
            "input": [
              "text",
              "image",
              "pdf"
            ],
            "output": [
              "text"
            ]
          },
          "toolCall": true,
          "reasoning": true,
          "openWeights": false,
          "limit": {
            "context": 1000000,
            "output": 128000
          },
          "cost": {
            "input": 3,
            "output": 15,
            "cache_read": 0.3,
            "cache_write": 3.75
          }
        }
      ],
      "nextCursor": "anthropic/claude-sonnet-5"
    }
  },
  {
    "action": "searchModels",
    "name": "terminal",
    "args": {
      "query": "claude",
      "provider": "anthropic",
      "limit": 1,
      "cursor": "anthropic/claude-sonnet-5"
    },
    "output": {
      "items": [
        {
          "id": "claude-sonnet-5",
          "name": "Claude Sonnet 5",
          "providerId": "anthropic",
          "providerName": "Anthropic",
          "family": "claude-sonnet",
          "description": "Everyday Claude agent model for coding, planning, browsing, and general work",
          "modalities": {
            "input": [
              "text",
              "image",
              "pdf"
            ],
            "output": [
              "text"
            ]
          },
          "toolCall": true,
          "reasoning": true,
          "openWeights": false,
          "limit": {
            "context": 1000000,
            "output": 128000
          },
          "cost": {
            "input": 2,
            "output": 10,
            "cache_read": 0.2,
            "cache_write": 2.5
          }
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "searchModels",
    "name": "empty",
    "args": {
      "query": "no-model-matches-this"
    },
    "output": {
      "items": [],
      "nextCursor": null
    }
  },
  {
    "action": "searchModels",
    "name": "exact-provider",
    "args": {
      "query": "claude",
      "provider": "anth"
    },
    "output": {
      "items": [],
      "nextCursor": null
    }
  },
  {
    "action": "searchModels",
    "name": "invalid-cursor",
    "args": {
      "query": "claude",
      "cursor": "missing"
    },
    "error": "Invalid or expired cursor"
  },
  {
    "action": "getModelDetails",
    "name": "reasoning-options",
    "args": {
      "providerId": "anthropic",
      "modelId": "claude-sonnet-5"
    },
    "output": {
      "provider": {
        "id": "anthropic",
        "name": "Anthropic",
        "api": null,
        "doc": "https://docs.anthropic.com/en/docs/about-claude/models",
        "npm": "@ai-sdk/anthropic",
        "env": [
          "ANTHROPIC_API_KEY"
        ]
      },
      "model": {
        "id": "claude-sonnet-5",
        "name": "Claude Sonnet 5",
        "description": "Everyday Claude agent model for coding, planning, browsing, and general work",
        "family": "claude-sonnet",
        "attachment": true,
        "reasoning": true,
        "reasoning_options": [
          {
            "type": "toggle"
          },
          {
            "type": "effort",
            "values": [
              "low",
              "medium",
              "high",
              "xhigh",
              "max"
            ]
          }
        ],
        "tool_call": true,
        "structured_output": true,
        "temperature": false,
        "knowledge": "2026-01-31",
        "release_date": "2026-06-29",
        "last_updated": "2026-06-30",
        "modalities": {
          "input": [
            "text",
            "image",
            "pdf"
          ],
          "output": [
            "text"
          ]
        },
        "open_weights": false,
        "limit": {
          "context": 1000000,
          "output": 128000
        },
        "cost": {
          "input": 2,
          "output": 10,
          "cache_read": 0.2,
          "cache_write": 2.5
        }
      }
    }
  },
  {
    "action": "getModelDetails",
    "name": "provider-override",
    "args": {
      "providerId": "google-vertex",
      "modelId": "xai/grok-4.1-fast-non-reasoning"
    },
    "output": {
      "provider": {
        "id": "google-vertex",
        "name": "Vertex",
        "api": null,
        "doc": "https://cloud.google.com/vertex-ai/generative-ai/docs/models",
        "npm": "@ai-sdk/google-vertex",
        "env": [
          "GOOGLE_VERTEX_PROJECT",
          "GOOGLE_VERTEX_LOCATION",
          "GOOGLE_APPLICATION_CREDENTIALS"
        ]
      },
      "model": {
        "id": "xai/grok-4.1-fast-non-reasoning",
        "name": "Grok 4.1 Fast",
        "description": "Fast Grok model for responsive chat, tool-assisted work, and low-latency responses",
        "family": "grok",
        "attachment": true,
        "reasoning": false,
        "tool_call": true,
        "structured_output": true,
        "temperature": true,
        "release_date": "2025-11-19",
        "last_updated": "2025-11-19",
        "modalities": {
          "input": [
            "text",
            "image"
          ],
          "output": [
            "text"
          ]
        },
        "open_weights": false,
        "limit": {
          "context": 128000,
          "output": 30000
        },
        "status": "deprecated",
        "provider": {
          "npm": "@ai-sdk/openai-compatible",
          "api": "https://${GOOGLE_VERTEX_ENDPOINT}/v1/projects/${GOOGLE_VERTEX_PROJECT}/locations/${GOOGLE_VERTEX_LOCATION}/endpoints/openapi"
        },
        "cost": {
          "input": 0.2,
          "output": 0.5,
          "cache_read": 0.05
        }
      }
    }
  },
  {
    "action": "getModelDetails",
    "name": "missing-provider",
    "args": {
      "providerId": "missing",
      "modelId": "missing"
    },
    "error": "Provider not found: missing"
  },
  {
    "action": "getModelDetails",
    "name": "missing-model",
    "args": {
      "providerId": "anthropic",
      "modelId": "missing"
    },
    "error": "Model not found: missing under provider anthropic"
  }
];
