import Contacts
import Foundation

@MainActor
final class ContactsProvider {
    static let shared = ContactsProvider()

    struct Match {
        let name: String
        let number: String
    }

    struct Card: Encodable {
        let name: String
        let phones: [String]
        let emails: [String]
    }

    enum ContactsError: LocalizedError {
        case denied
        var errorDescription: String? {
            switch self {
            case .denied:
                return "Contacts access is off for Ox, so it can't look up who to text. Ask the user to enable it in Settings › Privacy & Security › Contacts › Ox, or to give you the phone number directly."
            }
        }
    }

    private let store = CNContactStore()
    private init() {}

    func authorized() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return true
        case .notDetermined: return (try? await store.requestAccess(for: .contacts)) ?? false
        case .limited: return true
        default: return false
        }
    }

    func resolve(name query: String) async throws -> [Match] {
        guard await authorized() else { throw ContactsError.denied }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        let matches = contacts.flatMap { contact -> [Match] in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? query
            return contact.phoneNumbers.map { Match(name: name, number: $0.value.stringValue) }
        }
        Log.agent.info("contacts.resolve query=\(query) matches=\(matches.count)")
        return matches
    }

    func search(query: String) async throws -> [Card] {
        guard await authorized() else { throw ContactsError.denied }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: query)
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        let cards = contacts.map { contact -> Card in
            let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            return Card(
                name: formatted.isEmpty ? query : formatted,
                phones: contact.phoneNumbers.map { $0.value.stringValue },
                emails: contact.emailAddresses.map { $0.value as String }
            )
        }
        Log.agent.info("contacts.search query=\(query) cards=\(cards.count)")
        return cards
    }
}
