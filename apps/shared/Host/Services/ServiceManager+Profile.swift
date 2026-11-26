import Foundation

extension ServiceManager {
    func reloadProfileConfiguration() {
        preferences = (try? ServicePreferences.load()) ?? ServicePreferences()
        actionPolicies = Self.loadActionPolicies()
        Log.service.info("ServiceManager.profileConfiguration reloaded names=\(preferences.names.count)")
    }
}
