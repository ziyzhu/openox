import Foundation

struct WhatsNewRelease: Identifiable {
    let version: String
    let items: [String]

    var id: String { version }
}

enum WhatsNew {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "1.0.24", items: [
            "See when another conversation finishes with a tappable banner that opens its reply.",
            "Keep the latest website page open when switching conversations, with clearer Done and Cancel controls for handoffs.",
            "Change models during a reply and apply your choice to the next turn.",
            "Use expanded website actions for Chase travel, Google Drive documents, Airbnb wishlists, and Google Maps reviews.",
            "Improved conversation scrolling, package imports, website sign-in, and text sizing, with haptic feedback when you tap Send."
        ]),
        WhatsNewRelease(version: "1.0.23", items: [
            "See release highlights after updating and browse past releases in Settings.",
            "Use more built-in website services, including GitHub, Google Drive, Google Calendar, YouTube, and Tailscale.",
            "Get combined, ranked web search results with duplicate links removed.",
            "Open conversation history at the latest messages and keep inline browsing in place as the conversation continues.",
            "Improved connection stability, website verification handoffs, and handling of malformed responses."
        ]),
        WhatsNewRelease(version: "1.0.22", items: [
            "Open a web address from the message composer in an inline browser, even before setting up a model provider.",
            "Retry a failed reply in the same conversation, keeping its history and completed actions.",
            "See scheduled prompts as compact bubbles labeled with the schedule name.",
            "Send local images to compatible MCP services and view returned images and files in the conversation.",
            "Improved website sign-in handoffs and conversation cards."
        ]),
        WhatsNewRelease(version: "1.0.21", items: [
            "Choose System, Light, or Dark appearance in Settings.",
            "Smoother streaming of responses and reasoning, especially for long replies.",
            "Search Brave, DuckDuckGo, Google, Reddit, X, and Wikipedia in parallel without changing your conversation’s attached services. X search requires sign-in.",
            "Open service and repository details directly from source chips.",
            "Improve website sign-in handling and show live service pages sooner.",
            "Read Reddit posts and comments with the new built-in Reddit service.",
            "Read RSS and Atom feeds as structured entries."
        ]),
        WhatsNewRelease(version: "1.0.20", items: [
            "Open referenced conversations directly from source chips, with clearer conversation titles.",
            "Fix Markdown text and bullet colors in light and dark appearance.",
            "Connect to HTTPS MCP servers over Tailscale."
        ]),
        WhatsNewRelease(version: "1.0.19", items: [
            "Open generated artifacts directly from references in the reasoning trace.",
            "Review website handoffs even when the page stays at the same address, with more reliable browser page updates.",
            "Improves opening external links from conversations and shows clearer feedback when a link cannot be opened.",
            "Keeps unchanged services running when repository sources are refreshed, and improves service sign-in and authoring guidance."
        ]),
        WhatsNewRelease(version: "1.0.18", items: [
            "Preview, edit, and remove new attachments before sending. Shared files now open in a new conversation draft.",
            "Sign-in, browser, human-verification, and payment handoffs now use more consistent controls. Final purchase review and payment remain yours.",
            "Reasoning traces show clearer references to files, skills, services, and web pages.",
            "Adds global Kimi Coding Plan support and improves provider sign-in and model discovery reliability.",
            "Improves bundled website actions and conversation controls, and shows the app version and build in Settings."
        ]),
        WhatsNewRelease(version: "1.0.17", items: [
            "Let Ox prepare purchases for you; it hands the final review and payment to you, then confirms the order went through.",
            "Voice preferences now live in Ox's memory instead of a separate Voice editor; your existing custom voice is carried over.",
            "When a website needs you to sign in, Ox now shows you the page instead of asking in chat.",
            "Ox knows which folders you've granted, asks fewer unnecessary questions, and double-checks unexpected service results.",
            "Large HTML files from your folders now open in the viewer, and website navigation is more reliable."
        ]),
        WhatsNewRelease(version: "1.0.16", items: [
            "Create prompt-based schedules with repeat intervals, conditions, and deadlines, and manage them from a conversation.",
            "Discover and connect remote MCP services and APIs more easily.",
            "Work with selected Files folders using the same file operations as your Profile, with removals sent to native trash when supported.",
            "Enjoy smoother conversation history transitions and clearer skill controls.",
            "Improved service sign-in and file searches when nested folders are unavailable."
        ]),
        WhatsNewRelease(version: "1.0.15", items: [
            "View Mermaid diagrams and SVG drawings directly in chat, and copy diagram source from the full-screen viewer.",
            "Preview files in conversations with clearer filenames and layouts.",
            "Enjoy smoother response streaming, scrolling, and keyboard transitions, with faster conversation history loading.",
            "Control Browser access to signed-in sites with per-site approvals.",
            "Recover more easily when a Profile folder is unavailable, with clearer errors and an option to switch Profiles."
        ]),
        WhatsNewRelease(version: "1.0.14", items: [
            "Open your service repositories in Files to view and edit their contents.",
            "Local services stay enabled, and remote MCP connections are now stored alongside them.",
            "Simplified Settings and service details.",
            "When a ChatGPT session can no longer be refreshed, Ox now asks you to sign in again."
        ]),
        WhatsNewRelease(version: "1.0.13", items: [
            "Open the browser directly: Choose Browser from the composer’s + menu without asking the agent. Typing a domain or URL also offers a direct-open suggestion. The start page includes service websites, with saved services first.",
            "Smoother browsing: Refined address-bar editing, inline clearing, loading progress, navigation controls, and gestures. Improved recovery after canceled navigation.",
            "Refreshed design: Updated Ox icons, neutral grey surfaces, consistent orange controls, and clearer contrast in light and dark themes.",
            "Better conversation flow: Smoother Send transitions, better-timed loading indicators, and simpler conversation actions.",
            "Richer file presentation: File preview cards and collapsible, per-file code diffs. File attachments use one system picker, and mounted folders can be disconnected with confirmation without deleting their contents.",
            "Simpler sign-in: Unified credential entry for providers and services, plus improved web sign-in recovery.",
            "Clearer background progress: Phase-specific Live Activity titles and restored periodic progress updates.",
            "Agent improvements: Bounded generation through configured models, on-demand API/schema discovery, and temporary files for reading large execution outputs."
        ]),
        WhatsNewRelease(version: "1.0.12", items: [
            "Preview files directly from Shoveler cards.",
            "Read diffs in collapsible, per-file sections.",
            "Enjoy smoother message sending and conversation transitions.",
            "Manage files more easily with improved attachments, folder unmounting, and cancellation.",
            "Experience more reliable model requests, simpler provider setup, clearer service controls, and refined browser and speech interactions."
        ]),
        WhatsNewRelease(version: "1.0.11", items: [
            "Browse Profile files in Apple Files, with native previews for supported file types.",
            "Mount folders for a specific Profile and connect service repositories directly from those folders. Existing folder access must be explicitly assigned to a Profile.",
            "View image galleries in conversation replies and open images for a closer look.",
            "Keep the composer visible during service sign-in, and see clearer browser navigation errors.",
            "Load long conversation histories in pages and defer Profile content loading until it is needed.",
            "Simplify Settings and improve the light theme."
        ]),
        WhatsNewRelease(version: "1.0.10", items: [
            "Manage settings through chat: ask Ox to change its language, theme, model, or enabled repositories, subject to normal permissions.",
            "Use files from selected folders: attach images and PDFs, extract text, and analyze images from folders you explicitly grant access to.",
            "Connect from the terminal: access the foreground iOS Host through Tailscale using the Ox CLI. Remote connections are opt-in.",
            "Faster startup: saved chat histories load on demand rather than all being reconstructed at launch.",
            "More reliable conversations: improved interrupted-task recovery, Stop behavior, queued messages, and preservation of keyboard focus and drafts.",
            "Safer website-model handling: better long-conversation handling and clearer uncertain submission outcomes, without automatically resending potentially completed requests.",
            "Storage reliability: fixes for older chat formats, lower-memory migration, and automatic recovery of unavailable optional storage."
        ]),
        WhatsNewRelease(version: "1.0.9", items: [
            "Create or improve reusable website services directly from a chat, with clearer source selection and safer sign-in handoffs.",
            "Start independent chats for background work and see the current execution step while tasks run.",
            "Use new web model actions for Gemini and Doubao, plus smoother concurrent streaming across supported websites.",
            "Export the Local service repository, control whether it is enabled, and attach services more easily.",
            "Enjoy steadier startup and conversation loading, better Markdown and artifact presentation, and more reliable long-chat recovery."
        ]),
        WhatsNewRelease(version: "1.0.8", items: [
            "Use Kimi, Qwen, Grok, or Claude through your existing website account as a model provider.",
            "Search and reopen saved conversations across more AI chat services.",
            "Import reviewed memories from another AI assistant into your current Profile.",
            "Browse an expanded collection of built-in services, with clearer ordering and more reliable icons.",
            "Browser sessions now stay with their chats when you switch conversations.",
            "Improved website sign-in, startup recovery, and general reliability."
        ]),
        WhatsNewRelease(version: "1.0.7", items: [
            "Share or import Ox service packages, connect service repositories, and propose changes from Ox.",
            "Suggested next actions now appear as quick prompts above the message composer.",
            "Ox can now delete chats after asking for your approval.",
            "Settings are easier to navigate, with refreshed model choices and interface refinements."
        ]),
        WhatsNewRelease(version: "1.0.6", items: [
            "Signing in to supported websites is clearer and more reliable, including Facebook and ChatGPT.",
            "When Ox needs you to take over a website action, the page stays available.",
            "Suggested follow-up actions now fit the current conversation."
        ]),
        WhatsNewRelease(version: "1.0.5", items: [
            "Browse and act on websites directly in chat, with live pages displayed in the conversation.",
            "Safe read-only Actions can run automatically, and approval settings are clearer.",
            "Edit sent messages in the composer; pinned and scheduled chats now appear in Recents."
        ]),
        WhatsNewRelease(version: "1.0.4", items: [
            "Connect, refresh, update, and remove MCP servers directly in chat, with approval before changes.",
            "When no existing service fits a website task, Ox can help through Browser and build a local service you can save for reuse.",
            "Improved keyboard handling on iPhone, tighter chat step spacing, and more consistent service icons."
        ]),
        WhatsNewRelease(version: "1.0.3", items: [
            "Setup is simpler, with a clearer model selection step before your first chat.",
            "You can now open web sources directly from chat activity.",
            "Background chat progress is more consistent, and scheduled chats keep questions and permission requests available for you to answer.",
            "This update also improves service access checks, refreshes service icons after updates, and refines the Services picker."
        ]),
        WhatsNewRelease(version: "1.0.2", items: [
            "This update makes chat smoother and more reliable, with steadier streaming text and cleaner message layouts. Custom answers now show clear confirmation, onboarding is simpler, and the sidebar can be resized on iPad."
        ]),
        WhatsNewRelease(version: "1.0.1", items: [
            "Added free model options and easier provider onboarding.",
            "Ox can now organize authorized photos into albums, schedule recurring skills, and use hold-to-talk voice input.",
            "Chat streaming, scrolling, and reliability are improved throughout."
        ])
    ]

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    static var shipped: [WhatsNewRelease] {
        releases.filter { compare($0.version, appVersion) != .orderedDescending }
    }

    static func unseen(since seenVersion: String?) -> [WhatsNewRelease] {
        guard let seenVersion else {
            return shipped.filter { compare($0.version, appVersion) == .orderedSame }
        }
        return shipped.filter { compare($0.version, seenVersion) == .orderedDescending }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}
