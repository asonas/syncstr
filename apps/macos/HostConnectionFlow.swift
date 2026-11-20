import Combine
import Foundation

extension HostAddress {
    var displayName: String { port.map { "\(host):\($0)" } ?? host }
}

enum HostInput {
    case text(String), link(URL)

    func address() throws -> HostAddress {
        switch self {
        case .link(let url):
            return try HostAddress(link: url)
        case .text(let input):
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.lowercased().hasPrefix("syncstr:"), let url = URL(string: value) {
                return try HostAddress(link: url)
            }
            return try HostAddress(value.contains("://") ? value : "https://" + value)
        }
    }
}

@MainActor
final class HostConnectionFlow: ObservableObject {
    enum Phase {
        case entry, reading, connecting, connected
        case confirmation(HostAddress, HostLibraryInfo), replacement(HostAddress, HostLibraryInfo)
        case failure(String)
    }

    @Published private(set) var phase = Phase.entry

    static func message(for error: Error) -> String {
        switch error as? HostAPIError {
        case .notHost, .notRunning, .address: error.localizedDescription
        default: "ホストに接続できませんでした。"
        }
    }

    func read(_ input: HostInput, using transfer: LocalTransfer) async {
        phase = .reading
        do {
            let address = try input.address()
            let info = try await transfer.libraryInformation(at: address)
            try Task.checkCancellation()
            phase = .confirmation(address, info)
        } catch {
            if !Task.isCancelled { phase = .failure(Self.message(for: error)) }
        }
    }

    func confirm(using transfer: LocalTransfer, replacing: Bool = false) async {
        let address: HostAddress
        let info: HostLibraryInfo
        switch (phase, replacing) {
        case (.confirmation(let candidate, let information), false),
             (.replacement(let candidate, let information), true):
            address = candidate
            info = information
        default: return
        }
        phase = .connecting
        do {
            switch try await transfer.confirmHost(address, information: info, replacingLibrary: replacing) {
            case .differentLibrary(let id):
                // The catalog may have changed since the person read the library name.
                let current = id == info.library ? info : try await transfer.libraryInformation(at: address)
                guard current.library == id else { throw HostAPIError.notHost }
                phase = .replacement(address, current)
            case .updated, .unchanged:
                phase = .connected
            }
        } catch {
            phase = .failure(Self.message(for: error))
        }
    }
}
