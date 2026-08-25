import Foundation
import Observation
import UIKit

struct ServiceDetailCapabilities {
    enum Authentication {
        case service
        case systemPermission
        case mcp
        case none
    }

    enum AttachmentData {
        case signedIn
        case onDevice
        case remote
    }

    let authentication: Authentication
    let attachmentData: AttachmentData
    let showsDomain: Bool
    let showsSkills: Bool
    let supportsPageInspection: Bool
    let supportsWebsiteDataManagement: Bool
    let supportsFolderAccess: Bool
    let supportsRemoteManagement: Bool
}

@MainActor
@Observable
final class WebService {
    var state: Service.ResolutionState

    init(state: Service.ResolutionState = .idle(nil)) {
        self.state = state
    }

    var detailCapabilities: ServiceDetailCapabilities {
        ServiceDetailCapabilities(
            authentication: .service,
            attachmentData: .signedIn,
            showsDomain: true,
            showsSkills: true,
            supportsPageInspection: true,
            supportsWebsiteDataManagement: true,
            supportsFolderAccess: false,
            supportsRemoteManagement: false
        )
    }
}

@MainActor
final class IOSService {
    typealias NativeInvocation = @MainActor (_ serviceID: String, _ actionID: String, _ args: JSONValue, _ purpose: String?) async throws -> JSONValue?

    private let domain: String
    private let permission: NativePermission?
    var browserState: Service.ResolutionState?

    init(domain: String, permission: NativePermission?) {
        self.domain = domain
        self.permission = permission
        browserState = domain == "ios:browser" ? .idle(Service.Resolved(actions: "", skills: [:])) : nil
    }

    var hasBrowserRuntime: Bool { browserState != nil }

    var detailCapabilities: ServiceDetailCapabilities {
        ServiceDetailCapabilities(
            authentication: permission == nil ? .none : .systemPermission,
            attachmentData: .onDevice,
            showsDomain: false,
            showsSkills: false,
            supportsPageInspection: hasBrowserRuntime,
            supportsWebsiteDataManagement: false,
            supportsFolderAccess: domain == "ios:files",
            supportsRemoteManagement: false
        )
    }

    var requiresPermission: Bool { permission != nil }

    func permissionState() async -> NativePermissionState? {
        guard let permission else { return nil }
        return await permission.state()
    }

    func updatePermission(from state: NativePermissionState?) async -> NativePermissionState? {
        guard let permission else { return nil }
        if state == .notDetermined { return await permission.request() }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return state }
        let opened = await UIApplication.shared.open(url)
        Log.ui.info("IOSService.permission settings permission=\(permission.rawValue) opened=\(opened)")
        return state
    }

    func invoke(
        service: Service,
        actionID: String,
        args: JSONValue,
        purpose: String?,
        approve: @MainActor (_ action: String, _ args: Any?) async -> Bool,
        nativeInvocation: NativeInvocation
    ) async -> Result<JSONValue, Error> {
        let name = "\(service.domain):\(actionID)"
        guard let action = service.definition.action(actionID),
              let inputSchema = action.inputSchema,
              let outputSchema = action.outputSchema else {
            return .failure(Service.InvokeError.unknown(name))
        }
        let definitions = service.definition.definitions
        let inputViolations = JSONSchemaValidator.validate(args, against: inputSchema, definitions: definitions)
        guard inputViolations.isEmpty else {
            return .failure(Service.InvokeError.invalidInput(name, inputViolations))
        }
        if action.requireApproval {
            let allow = await approve(name, args.toAny())
            Log.service.info("IOSService.invoke approval name=\(name) allow=\(allow)")
            guard allow else { return .failure(Service.InvokeError.denied(name)) }
        }
        do {
            let value = try await nativeInvocation(service.domain, actionID, args, purpose) ?? .null
            let outputViolations = JSONSchemaValidator.validate(value, against: outputSchema, definitions: definitions)
            guard outputViolations.isEmpty else {
                return .failure(Service.InvokeError.invalidOutput(name, outputViolations))
            }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }
}
