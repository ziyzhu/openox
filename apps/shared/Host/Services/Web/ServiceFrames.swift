import CryptoKit
import Foundation
import WebKit

extension Service.ServiceWebPage {
    struct FrameTarget {
        let id: String
        let info: WebPage.FrameInfo?
        let origin: String
        let parentID: String?
        let isMainFrame: Bool

        func guarded(_ source: String) -> String {
            """
            if (window.__oxDocumentID !== \(JSONValue.string(id).jsonString()) || location.origin !== \(JSONValue.string(origin).jsonString())) throw Error('Frame document changed; inspect the page again');
            \(source)
            """
        }
    }

    static let frameIdentityScript = """
    (() => {
      if (!Object.hasOwn(window, '__oxDocumentID')) Object.defineProperty(window, '__oxDocumentID', { value: crypto.randomUUID() });
    })();
    """

    func observeFrames(_ action: WebPage.NavigationAction) {
        if let target = action.target, !target.isMainFrame { frameCandidates.append(target) }
        if !action.source.isMainFrame { frameCandidates.append(action.source) }
        if frameCandidates.count > 64 {
            omittedFrames += frameCandidates.count - 64
            frameCandidates.removeFirst(frameCandidates.count - 64)
        }
    }

    func discoverFrames(owner: Service) async throws -> [FrameTarget] {
        let generation = navigationGeneration
        let candidates: [WebPage.FrameInfo?] = [nil] + frameCandidates.map(Optional.some)
        var found: [String: FrameTarget] = [:]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        for (index, candidate) in candidates.enumerated() {
            if clock.now >= deadline { omittedFrames += candidates.count - index; break }
            try Task.checkCancellation()
            guard owner.owns(self), navigationGeneration == generation else { throw Service.EvalError.contextInvalidated }
            let source = """
            \(Self.frameIdentityScript)
            let parentID = null;
            try { if (window !== top) parentID = parent.__oxDocumentID || null; } catch {}
            return { id: window.__oxDocumentID, origin: location.origin, parentID };
            """
            guard let raw = try? await owner.evalOnce(self, source, timeout: 1, frame: candidate),
                  let fields = JSONValue.from(raw).objectValue,
                  let id = fields["id"]?.stringValue,
                  let origin = fields["origin"]?.stringValue else { continue }
            guard origin != "null", let url = URL(string: origin), BrowserNavigation.allowsServiceNavigation(url) else {
                omittedFrames += 1
                continue
            }
            found[id] = FrameTarget(id: id, info: candidate, origin: origin,
                                    parentID: fields["parentID"]?.stringValue, isMainFrame: candidate == nil)
        }
        guard owner.owns(self), navigationGeneration == generation else { throw Service.EvalError.contextInvalidated }
        frameCandidates = found.values.compactMap(\.info)
        frameTargets = found
        return found.values.sorted { $0.id < $1.id }
    }

    func requireFrame(_ id: String, owner: Service) async throws -> FrameTarget {
        guard frameTargets[id] != nil,
              let target = try await discoverFrames(owner: owner).first(where: { $0.id == id }) else {
            throw OxFunctionError(code: "frame_unavailable", message: "The selected frame document is no longer available.", recovery: "Inspect getPageState again. Do not automatically repeat an action whose outcome is uncertain.")
        }
        return target
    }

    func frameMetadata(_ targets: [FrameTarget], services: [Service], attached: Set<String>) -> JSONValue {
        .array(targets.map { target in
            let host = URL(string: target.origin)?.host ?? ""
            let service = services.filter { $0.isWebService && $0.isServiceHost(host) }.max { $0.domain.count < $1.domain.count }
            return .object([
                "id": .string(target.id),
                "parentId": target.parentID.map(JSONValue.string) ?? .null,
                "origin": .string(target.origin),
                "isMainFrame": .bool(target.isMainFrame),
                "serviceID": service.map { .string($0.definition.actionNamespace) } ?? .null,
                "attached": .bool(service.map { attached.contains($0.domain) } ?? false),
            ])
        })
    }
}

extension Service {
    func installFrameServices(_ services: [Service], on page: ServiceWebPage) async throws {
        guard owns(page), page.secretAttempt?.holdsValues != true else { throw EvalError.contextInvalidated }
        var sources: [String: String] = [:]
        for service in services where service.isWebService {
            try await manager.requireInvocationAccess(for: service)
            await service.loadManifest()
            if let source = service.resolutionState.resolved?.actions { sources[service.domain] = source }
        }
        if isWebService { sources[domain] = page.actions }
        if page.frameServiceSources != sources {
            page.frameServiceSources = sources
            page.scriptMode = nil
            configureScripts(for: page.page.url, in: page)
        }
        let script = frameServicesScript(page)
        for target in try await page.discoverFrames(owner: self) {
            _ = try await evalOnce(page, target.guarded(script), timeout: 3, frame: target.info)
        }
    }

    func frameServicesScript(_ page: ServiceWebPage) -> String {
        var sources = page.frameServiceSources
        if isWebService { sources[domain] = page.actions }
        let domains = sources.keys.sorted { $0.count > $1.count }
        let choices = JSONValue.array(domains.map(JSONValue.string)).jsonString()
        let version = SHA256.hash(data: Data(domains.map { $0 + (sources[$0] ?? "") }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        let installers = domains.map { domain in
            """
            if (domain === \(JSONValue.string(domain).jsonString())) {
              \(ServiceActionRuntime.source(domain: domain))
              \(sources[domain]!)
            }
            """
        }.joined(separator: "\n")
        return """
        (() => {
          const host = location.hostname.toLowerCase();
          const domain = \(choices).find(domain => host === domain || host.endsWith('.' + domain));
          if (!domain || window.__oxInstalledService === domain + ':\(version)') return;
          \(installers)
          window.__oxInstalledService = domain + ':\(version)';
        })();
        """
    }
}
