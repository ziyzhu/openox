# Virtual Machine + Virtual File System

```text
OX DEPLOYMENT MODEL

Ox Client
└── Host contract
    └── Ox Host
        ├── Profile
        ├── model provider adapter
        ├── platform and service adapters
        └── Ox VM
            ├── session binding
            ├── skills
            ├── virtual filesystem
            └── ox.* capabilities

current iOS app
└── OxClient
    └── OxHost
        └── IOSHost
            └── JavaScriptCore Ox VM

Ox CLI
└── WebSocketOxHostTransport
    └── OxHostProtocol
        └── OxHost
            └── IOSHost
```

Clients target Hosts rather than depending on a VM engine. A Host owns VM
lifecycle, Profile access, capability implementations, and session selection.
The same Client can target another compatible Host, and a Host can replace its
VM implementation while preserving the observable VM contract.

The CLI expresses those resources as `--host <ws-url>` and
`--chat <chat-id>`. Direct Profile administration instead uses
`--profile <path>` and does not imply a Host connection or chat-backed VM.

The iOS Client calls the `OxHost` contract in process and preserves the
observable Swift models used by the native interface. That in-process path is
direct Swift dispatch: it does not serialize local operations or create a
loopback network dependency. `WebSocketOxHostTransport` carries the same Host
protocol to the CLI and dispatches to the same `IOSHost`; it does not own a
second runtime or select Host state through the view hierarchy.
Simulator-only view and composer automation remains behind `DebugUIAPI`.

The iOS Host currently exposes version 1 of the control protocol from DEBUG
Simulator builds over its loopback WebSocket. It supports Host and VM
inspection, chat discovery, function discovery, structured `ox.*` calls,
and arbitrary development evaluation. `ox vm call` is the stable operation
surface; `ox vm eval` is a development escape hatch.

```text
HOST CONTROL PROTOCOL V1

request envelope
├── kind
├── id
├── protocolVersion: 1
├── sessionId?                  chat-bound execution context
└── operation fields

operations
├── vm-inspect                  Host, VM, session, and visible VFS roots
├── vm-functions                complete catalog or one function contract
├── vm-call                     catalogued function + JSON object arguments
└── vm-eval                     arbitrary JavaScript development escape hatch

response envelope
├── kind
├── id
├── ok
├── protocolVersion: 1
├── value?
├── logs?
└── error?
```

`vm-call` accepts only exact names advertised by `vm-functions`. The Host
serializes arguments, runs the function through the selected chat bridge, and
therefore preserves the same schema validation, authorization, approval, and
service attachment behavior as agent execution.

```text
MODEL-TO-NATIVE EXECUTION

LLM
└── execute { source }
    ├── source limit: 100,000 characters
    └── ChatJavaScriptTool
        ├── beginExecution(source)
        ├── VirtualMachine.run(source, bridge: Chat)
        │   └── serialized tail
        │       ├── wait for the preceding execution
        │       └── VirtualMachineRuntime.run
        │           ├── shared thread: agent-javascript
        │           ├── reusable JSVirtualMachine
        │           ├── reusable JSContext
        │           ├── current weak bridge -> calling Chat
        │           ├── wrap source
        │           │   └── (async () => { <source> })()
        │           │       └── .then(__nativeResolve, __nativeReject)
        │           ├── JavaScript
        │           │   ├── standard JavaScriptCore language/runtime
        │           │   ├── frozen console
        │           │   ├── non-writable globalThis.ox binding
        │           │   ├── no DOM
        │           │   ├── no Node.js
        │           │   ├── no shell
        │           │   ├── no direct native filesystem
        │           │   └── no direct network API
        │           └── Swift bridge promises
        │               ├── execute bridge work on MainActor
        │               ├── resolve/reject back on agent-javascript
        │               └── cancel tracked bridge tasks when settled
        ├── finishExecution(output, isError)
        └── ToolResult
            ├── model-visible text <- console.* logs
            ├── diagnosticContent <- structured logs + error
            ├── transient attachments <- execution attachments
            └── JavaScript return value <- discarded by execute
```

```text
RUNTIME OWNERSHIP + LIFETIME

Ox Host process
├── VirtualMachineThread.shared
│   └── one long-lived CFRunLoop thread for JavaScriptCore work
└── ChatManager
    ├── active Profile scope
    ├── one VirtualMachine actor
    │   ├── one VirtualMachineRuntime
    │   ├── one reusable JSVirtualMachine
    │   └── one reusable JSContext
    ├── Chat A ─┐
    ├── Chat B ─┼── share the ChatManager VirtualMachine
    └── Chat C ─┘

execution N
├── bridge -> Chat that initiated execution N
├── async-function locals die with execution N
└── explicit globalThis mutations can survive into execution N+1

active Profile scope changes
└── ChatManager replaces VirtualMachine
    └── JSVirtualMachine + JSContext + explicit globals reset
```

```text
EXECUTION STATE MACHINE

queued
└── wait for previous tail
    └── running
        ├── sync exception
        │   └── failed + captured console logs
        ├── rejected promise
        │   └── failed + captured console logs
        ├── task cancellation
        │   ├── mark settled
        │   ├── cancel timeout task
        │   ├── cancel bridge tasks
        │   └── CancellationError
        ├── active-time budget exhausted
        │   └── timeout after 60 seconds + captured console logs
        └── resolved promise
            └── completed + captured console logs

60-second active-time clock
├── normally running during bridge calls
└── suspended during
    ├── ox.service.invoke
    ├── ox.service.signIn
    ├── ox.service.solve
    ├── ox.service.pay
    └── ox.user.choose
```

```text
JAVASCRIPT CAPABILITY TREE

ox
├── app
│   ├── inspect
│   └── renameChat
├── artifact
│   ├── attach
│   ├── import
│   ├── present
│   └── rename
├── fs
│   ├── delete
│   ├── edit
│   ├── glob
│   ├── grep
│   ├── list
│   ├── read
│   └── write
├── service
│   ├── attach
│   ├── copy
│   ├── create
│   ├── delete
│   ├── detach
│   ├── find
│   ├── git
│   │   ├── checkout
│   │   ├── commit
│   │   ├── diff
│   │   ├── log
│   │   ├── restore
│   │   ├── revert
│   │   ├── show
│   │   └── status
│   ├── inspect
│   ├── invoke
│   ├── listAttached
│   ├── pay
│   ├── signIn
│   └── solve
├── skill
│   ├── copy
│   ├── create
│   └── delete
├── user
│   ├── choose
│   └── reportProgress
├── web
│   ├── fetch
│   └── search
└── widget
    ├── shoveler
    └── video

every ox.* function
├── requires options.purpose
│   ├── string
│   ├── 1..80 characters
│   └── user-visible step label
├── validates input against its closed schema
│   ├── required fields
│   ├── value types
│   ├── enums
│   ├── ranges
│   ├── array constraints
│   └── unknown top-level fields rejected
└── exposes non-enumerable function.help()
    └── description + input schema + output schema
```

```text
BRIDGE CALL FLOW

JavaScript
└── ox.<namespace>.<function>(options)
    ├── __oxOptions
    │   ├── require one options object
    │   └── validate against __oxHelpCatalog
    └── __native<Function>(...)
        └── OxFunctionEnvironment.call
            └── JavaScript Promise
                ├── Task @MainActor
                │   └── OxFunctionBridge
                │       └── Chat
                │           ├── authorization
                │           ├── approval / user handoff when required
                │           ├── app inspection / storage / service / web operation
                │           ├── structured diagnostic log
                │           └── JSONValue result or localized error
                └── agent-javascript thread
                    ├── resolve(JSON-compatible value)
                    └── reject(JavaScript Error)
```

```text
VIRTUAL FILESYSTEM TREE

.
├── MEMORY.md                                      [profile mutation rules]
├── SOUL.md                                        [profile mutation rules]
├── artifacts/                                     [profile mutation rules]
│   └── <validated-filename>                       [file]
├── skills/                                        [mixed sources]
│   ├── system:manage-artifacts/                   [read-only]
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── canvas.md
│   │       └── note.md
│   ├── system:manage-skills/                      [read-only]
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── service-skill.md
│   │       └── user-skill.md
│   ├── system:manage-services/                    [read-only]
│   │   ├── SKILL.md
│   │   └── references/
│   │       └── web-service.md
│   ├── <user-skill>/                              [writable outside temporary chats]
│   │   └── SKILL.md
│   └── service:<domain>:<skill>/                  [read-only; attached services only]
│       └── SKILL.md
├── services/                                      [source-aware]
│   ├── web/
│   │   └── <domain>/
│   │       ├── manifest.json                      [all sources]
│   │       └── <source descendants>               [Local only]
│   ├── ios/
│   │   └── <service-id>/
│   │       └── manifest.json
│   └── mcp/
│       └── <service-id>/
│           └── manifest.json
├── chats/                                         [read-only]
│   └── <chat-uuid>/
│       ├── chat.json                              [stored metadata]
│       └── turns.jsonl                            [stored transcript]
└── files/                                         [ios:files attachment required]
    └── <folder-grant-id>/
        └── <selected external folder descendants>

conditional branches
├── artifacts/*                  <- active Profile contents
├── skills/<user-skill>/*        <- active Profile contents
├── skills/service:*/*           <- attached service skills
├── services/<kind>/*            <- current MonoRepository; Local source expands
├── chats/*                       <- active Profile persisted chats
└── files/*                      <- user-selected security-scoped grants
```

```text
VIRTUAL PATH GRAMMAR

accepted
├── MEMORY.md
├── SOUL.md
├── artifacts
├── artifacts/<validated-filename>
├── skills
├── skills/<local-kebab-name>
├── skills/<local-kebab-name>/SKILL.md
├── skills/system:<local-kebab-name>
├── skills/system:<local-kebab-name>/SKILL.md
├── skills/service:<domain>:<local-kebab-name>
├── skills/service:<domain>:<local-kebab-name>/SKILL.md
├── services
├── services/<web|ios|mcp>
├── services/<web|ios|mcp>/<service-id>
├── services/<web|ios|mcp>/<service-id>/<non-hidden-descendant...>
├── chats
├── chats/<chat-uuid>
├── chats/<chat-uuid>/chat.json
├── chats/<chat-uuid>/turns.jsonl
├── files
├── files/<folder-grant-id>
└── files/<folder-grant-id>/<descendant...>

rejected
├── empty path                              except list/glob default root
├── /absolute/path
├── path/
├── path\component
├── ./component
├── ../component
├── component/../component
└── any shape outside the grammar above
```

```text
VIRTUAL PATH -> BACKING SOURCE

MEMORY.md
└── UserMemory.shared

SOUL.md
└── Soul.shared

artifacts/<name>
└── ProfileRepository
    └── active ProfileScope

skills/<user-name>/SKILL.md
└── ProfileRepository
    └── active ProfileScope

skills/system:<name>/SKILL.md
└── app bundle
    └── SystemSkills.bundle/<name>/SKILL.md
        ├── parse local name: <name>
        ├── reject service dependencies
        ├── namespace in memory: system:<name>
        └── serialize into the virtual file

skills/service:<domain>:<name>/SKILL.md
└── attached Service
    └── service package skill

services/<kind>/<id>/<path...>
└── ServiceManager
    ├── Bundled, Development, or Remote candidate
    │   └── normalized manifest only; read-only
    └── Local candidate
        └── expanded repository source; writable at the live tip

chats/<chat-uuid>/chat.json
└── ProfileRepository
    └── canonical stored metadata

chats/<chat-uuid>/turns.jsonl
└── ProfileRepository
    └── canonical stored transcript

files/<grant-id>/<path...>
└── DeviceFolderStore
    ├── security-scoped bookmark
    ├── coordinated access
    ├── hidden files skipped during listing/search
    └── symbolic links excluded during listing/search
```

```text
FILESYSTEM OPERATIONS + MUTATION BOUNDARIES

ox.fs
├── list
│   └── directory only
├── read
│   └── file only; bounded text or typed unsupported result
├── glob
│   └── paths only
├── grep
│   └── searchable text content only
├── write
│   ├── MEMORY.md
│   ├── SOUL.md
│   ├── artifacts/<name>
│   ├── skills/<user-name>/SKILL.md
│   ├── services/<kind>/<id>/<Local-source-file>
│   └── files/<grant-id>/<existing-parent>/<file>
├── edit
│   ├── exact unique replacements
│   ├── non-overlapping edits
│   └── one standalone append when oldText is empty
└── delete
    ├── artifacts/<name>                    [approval required]
    ├── skills/<user-name>[/SKILL.md]
    ├── services/<kind>/<id>/<Local-source-path>
    └── files/<grant-id>/<regular-file>      [approval required]

always read-only
├── skills/system:*/*
├── skills/service:*/*
├── Bundled, Development, and Remote service source
├── chats/*
├── virtual directories
└── external directories

temporary chat
├── MEMORY.md mutation                      [denied]
├── SOUL.md mutation                        [denied]
├── artifacts/* mutation                    [denied]
├── user skills mutation                    [denied]
└── files/<grant-id> mutation               [allowed only through ios:files + approval]
```

```text
FILESYSTEM CALL PIPELINE

ox.fs.<operation>
└── VirtualFileSystem.location(rawPath)
    ├── normalize + validate path grammar
    └── typed Location
        ├── Chat.authorizeFileAccess
        │   ├── Profile-owned, chat, and service areas
        │   │   └── no Files-service authorization
        │   └── files/<grant-id>
        │       ├── require attached ios:files service
        │       ├── require existing folder grant
        │       └── require approval for write/edit/delete
        └── operation
            ├── read/list/search
            │   └── backing source -> bounded JSON result
            └── write/edit/delete
                ├── require writable source
                │   ├── Profile-owned mutable path
                │   ├── Local service source at its live tip
                │   └── regular file under a folder grant
                ├── require non-temporary chat when Profile-backed
                ├── serialize through per-path mutation coordinator
                ├── persist through the backing source
                ├── update chat artifact/skill presentation
                └── return virtual item metadata
```

```text
HARD LIMITS

execute
├── source                       <= 100,000 characters
├── active execution time       <= 60 seconds
├── model-visible console text  <= 16,000 characters
│   └── truncated output keeps a 4,000-character tail
├── ox.web.fetch calls       <= 8 per execution
├── fetched bytes               <= 20 MiB per execution
├── transient attachments       <= 4 per execution
└── transient attachment bytes  <= 20 MiB per execution

ox.fs
├── text read default           <= 20,000 bytes
├── text read/write maximum     <= 200 KiB
├── search files                <= 1,000
├── search bytes                <= 2 MiB normally
├── explicit chat search bytes  <= 16 MiB
├── displayed search line       <= 500 characters
├── list result default/max     <= 50 / 100 items
├── glob result default/max     <= 100 / 1,000 paths
├── grep result default/max     <= 100 / 200 matches
└── grep context                <= 5 lines per side
```

```text
FAILURE + OBSERVABILITY FLOW

failure source
├── path validation
├── schema validation
├── authorization / approval
├── backing storage
├── service / web operation
├── JavaScript exception
├── rejected bridge promise
├── timeout
└── cancellation
    └── error boundary
        ├── localized model-visible error
        ├── console logs preserved on JavaScript failure/timeout
        ├── structured Chat tool diagnostic content
        └── user-owned on-device logs
            ├── Agent: VM lifecycle, timeout, exception, cancellation
            └── Session: bridge operation, purpose, path/count/size/outcome
```
