export const replayCases = [
  {
    "action": "getCurrentUser",
    "name": "authenticated",
    "args": {},
    "output": {
      "login": "fixture-user",
      "avatarUrl": "https://github.com/fixture-user.png",
      "url": "https://github.com/fixture-user"
    }
  },
  {
    "action": "getCurrentUser",
    "name": "signed-out",
    "args": {},
    "error": "requires sign-in"
  },
  {
    "action": "listBranches",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server"
    },
    "output": {
      "items": [
        {
          "name": "main",
          "isDefault": true,
          "author": "fixture-user"
        }
      ],
      "nextCursor": "2"
    }
  },
  {
    "action": "listCommits",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "ref": "main"
    },
    "output": {
      "items": [
        {
          "oid": "1111111111111111111111111111111111111111",
          "message": "Fixture commit",
          "author": "fixture-user",
          "authoredDate": "2026-01-02T03:04:05Z",
          "url": "https://github.com/github/github-mcp-server/commit/1111111111111111111111111111111111111111"
        }
      ],
      "nextCursor": "3778a41476e31a072430cfee7c5d31c5f72def60 34"
    }
  },
  {
    "action": "listReleases",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server"
    },
    "output": {
      "items": [
        {
          "tag": "v1.0.0",
          "name": "Fixture release",
          "url": "https://github.com/github/github-mcp-server/releases/tag/v1.0.0"
        }
      ],
      "nextCursor": "/github/github-mcp-server/releases?page=2"
    }
  },
  {
    "action": "listPullRequestFiles",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "number": "2983"
    },
    "output": {
      "items": [
        {
          "path": "fixture.ts",
          "status": "modified",
          "additions": 3,
          "deletions": 1,
          "isBinary": false,
          "isTooBig": false,
          "truncatedReason": null
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listPullRequestCommits",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "number": "2983"
    },
    "output": {
      "items": [
        {
          "oid": "2222222222222222222222222222222222222222",
          "message": "Fixture pull request commit",
          "author": "fixture-author",
          "authoredDate": "2026-01-03T03:04:05Z",
          "url": "https://github.com/github/github-mcp-server/commit/2222222222222222222222222222222222222222"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listPullRequestChecks",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "number": "2983"
    },
    "output": {
      "items": [
        {
          "name": "Fixture job",
          "workflow": "Fixture CI",
          "status": "succeeded",
          "runId": "30587316903",
          "jobId": "91021671171",
          "url": "https://github.com/github/github-mcp-server/actions/runs/30587316903/job/91021671171"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listPullRequestReviewThreads",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "number": "2983"
    },
    "output": {
      "items": [
        {
          "id": "thread-1",
          "subjectType": "LINE",
          "isResolved": false,
          "resolvedBy": null,
          "comments": [
            {
              "id": "comment-1",
              "author": "fixture-reviewer",
              "body": "Fixture review comment",
              "createdAt": "2026-01-02T03:04:05Z",
              "url": "https://github.com/github/github-mcp-server/pull/2983#discussion_fixture"
            }
          ]
        }
      ],
      "nextCursor": "/github/github-mcp-server/pull/2983/page_data/threads?after=2510469723"
    }
  },
  {
    "action": "listPullRequestReviewThreads",
    "name": "pagination",
    "args": {
      "repo": "github/github-mcp-server",
      "number": "2983",
      "cursor": "/github/github-mcp-server/pull/2983/page_data/threads?after=2510469723"
    },
    "output": {
      "items": [
        {
          "id": "thread-2",
          "subjectType": "LINE",
          "isResolved": true,
          "resolvedBy": "fixture-maintainer",
          "comments": [
            {
              "id": "comment-2",
              "author": "fixture-reviewer",
              "body": "Fixture paginated review comment",
              "createdAt": "2026-01-04T03:04:05Z",
              "url": "https://github.com/github/github-mcp-server/pull/2983#discussion_fixture_2"
            }
          ]
        }
      ],
      "nextCursor": "/github/github-mcp-server/pull/2983/page_data/threads?after=2510468175&page=2"
    }
  },
  {
    "action": "listWorkflowRuns",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server"
    },
    "output": {
      "items": [
        {
          "runId": "30693303910",
          "title": "Fixture run",
          "workflow": "Fixture workflow",
          "status": "completed successfully",
          "branch": "main",
          "createdAt": "2026-01-05T03:04:05Z",
          "duration": "25s",
          "url": "https://github.com/github/github-mcp-server/actions/runs/30693303910"
        }
      ],
      "nextCursor": "/github/github-mcp-server/actions?page=2"
    }
  },
  {
    "action": "getWorkflowRun",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "runId": "30693303910"
    },
    "output": {
      "runId": "30693303910",
      "title": "Fixture run",
      "workflow": "Fixture workflow",
      "status": "Success",
      "event": "schedule",
      "branch": "main",
      "commitSha": "3333333333333333333333333333333333333333",
      "createdAt": "2026-01-05T03:04:05Z",
      "duration": "25s",
      "jobs": [
        {
          "jobId": "91351791568",
          "name": "fixture-job",
          "status": "completed successfully",
          "duration": "15s",
          "url": "https://github.com/github/github-mcp-server/actions/runs/30693303910/job/91351791568"
        }
      ],
      "url": "https://github.com/github/github-mcp-server/actions/runs/30693303910"
    }
  },
  {
    "action": "getWorkflowJob",
    "name": "default",
    "args": {
      "repo": "github/github-mcp-server",
      "runId": "30693303910",
      "jobId": "91351791568"
    },
    "output": {
      "runId": "30693303910",
      "jobId": "91351791568",
      "name": "fixture-job",
      "status": "succeeded",
      "startedAt": "2026-01-05T03:04:05Z",
      "completedAt": "2026-01-05T03:04:20Z",
      "duration": "15s",
      "steps": [
        {
          "number": 1,
          "name": "Set up job",
          "conclusion": "success",
          "startedAt": "2026-01-05T03:04:05Z",
          "completedAt": "2026-01-05T03:04:06Z"
        },
        {
          "number": 2,
          "name": "Run fixture",
          "conclusion": "success",
          "startedAt": "2026-01-05T03:04:06Z",
          "completedAt": "2026-01-05T03:04:20Z"
        }
      ],
      "url": "https://github.com/github/github-mcp-server/actions/runs/30693303910/job/91351791568"
    }
  },
  {
    "action": "listBranches",
    "name": "pagination",
    "args": {
      "repo": "github/github-mcp-server",
      "cursor": "2"
    },
    "output": {
      "items": [
        {
          "name": "fixture-page-2",
          "isDefault": false,
          "author": "fixture-user-2"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listCommits",
    "name": "pagination",
    "args": {
      "repo": "github/github-mcp-server",
      "ref": "main",
      "cursor": "3778a41476e31a072430cfee7c5d31c5f72def60 34"
    },
    "output": {
      "items": [
        {
          "oid": "4444444444444444444444444444444444444444",
          "message": "Fixture commit page two",
          "author": "fixture-user-2",
          "authoredDate": "2026-01-06T03:04:05Z",
          "url": "https://github.com/github/github-mcp-server/commit/4444444444444444444444444444444444444444"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "listReleases",
    "name": "pagination",
    "args": {
      "repo": "github/github-mcp-server",
      "cursor": "/github/github-mcp-server/releases?page=2"
    },
    "output": {
      "items": [
        {
          "tag": "v0.9.0",
          "name": "Fixture release page two",
          "url": "https://github.com/github/github-mcp-server/releases/tag/v0.9.0"
        }
      ],
      "nextCursor": null
    }
  },
  {
    "action": "getFileContent",
    "name": "public",
    "args": {
      "repo": "octocat/Hello-World",
      "path": "README"
    },
    "output": {
      "repo": "octocat/Hello-World",
      "path": "README",
      "ref": "HEAD",
      "content": "Hello World!\n"
    }
  }
];
