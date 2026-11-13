import Foundation
import WebKit

extension BrowserSession {
    func advancePage(_ session: BrowserSession) {
        guard owns(session) else {
            failQueuedInvocations(in: session, error: EvalError.notActive)
            return
        }
        if case .pending(let lease) = session.navigationPhase,
           activeInvocationCount(in: session) == 0 {
            if transitionNavigation(.reserved(lease), on: session) {
                Log.webView.info("Service.navigation reserved domain=\(domain) session=\(session.logLabel) id=\(lease.id.uuidString.prefix(8)) label=\(lease.label) queued=\(queuedInvocationCount(in: session))")
            }
            return
        }
        guard session.isReady else { return }
        manager.actionScheduler.advance(session)
    }

    func failQueuedInvocations(in session: BrowserSession, error: any Error) {
        manager.actionScheduler.failPending(on: session, error: error)
    }

    func evalAsync(
        _ session: BrowserSession,
        _ js: String,
        context: String,
        timeout: TimeInterval = 30
    ) async throws -> Any? {
        let generation = session.navigationGeneration
        do {
            return try await evalOnce(session, js, timeout: timeout)
        } catch EvalError.contextInvalidated {
            Log.service.warning("Service.eval context-invalidated context=\(context) session=\(session.logLabel) nav=\(generation)->\(session.navigationGeneration)/\(session.finishedNavigationGeneration)")
            throw EvalError.contextInvalidated
        }
    }

    func evalOnce(_ session: BrowserSession, _ js: String, timeout: TimeInterval, frame: WebPage.FrameInfo? = nil) async throws -> Any? {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, any Error>) in
                let timeoutTask = Task { @MainActor [weak session] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    session?.finishEvaluation(id, with: .failure(EvalError.timeout(timeout)))
                }
                let evaluationTask = Task { @MainActor [weak session] in
                    guard let session else { return }
                    do {
                        let value = try await session.page.callJavaScript(
                            js,
                            arguments: [:],
                            in: frame,
                            contentWorld: .page
                        )
                        session.finishEvaluation(id, with: .success(value))
                    } catch {
                        session.finishEvaluation(id, with: .failure(Self.evalError(error)))
                    }
                }
                session.pendingEvaluations[id] = BrowserSession.PendingEvaluation(
                    continuation: continuation,
                    timeout: timeoutTask,
                    evaluation: evaluationTask
                )
            }
        } onCancel: {
            Task { @MainActor [weak session] in
                session?.finishEvaluation(id, with: .failure(CancellationError()))
            }
        }
    }

    nonisolated private static func evalError(_ error: any Error) -> any Error {
        let nsError = error as NSError
        let message = (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String)
            ?? (nsError.userInfo[NSLocalizedDescriptionKey] as? String)
            ?? error.localizedDescription
        if message.localizedCaseInsensitiveContains("completion handler for function call is no longer reachable") {
            return EvalError.contextInvalidated
        }
        return EvalError.js(message)
    }

}
