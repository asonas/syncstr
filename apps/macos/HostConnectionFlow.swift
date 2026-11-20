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

    private var operation: Task<Void, Never>?

    func editAddress() { phase = .entry }
    func scannerFailed() { phase = .failure("カメラを起動できませんでした。アドレスを入力してください。") }

    static func message(for error: Error) -> String {
        switch error as? HostAPIError {
        case .notHost, .notRunning, .address: error.localizedDescription
        default: "ホストに接続できませんでした。"
        }
    }

    func read(_ input: HostInput, using transfer: LocalTransfer) async {
        guard !Task.isCancelled else { return }
        let previous = operation
        previous?.cancel()
        phase = .reading
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await readInformation(input, using: transfer)
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func readInformation(_ input: HostInput, using transfer: LocalTransfer) async {
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
        guard !Task.isCancelled else { return }
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
        let task = Task {
            await connect(address, info: info, transfer: transfer, replacing: replacing)
        }
        operation = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func connect(_ address: HostAddress, info: HostLibraryInfo, transfer: LocalTransfer, replacing: Bool) async {
        do {
            switch try await transfer.confirmHost(address, information: info, replacingLibrary: replacing) {
            case .differentLibrary(let id):
                // The catalog may have changed since the person read the library name.
                let current = id == info.library ? info : try await transfer.libraryInformation(at: address)
                guard current.library == id else { throw HostAPIError.notHost }
                try Task.checkCancellation()
                phase = .replacement(address, current)
            case .updated, .unchanged:
                try Task.checkCancellation()
                phase = .connected
            }
        } catch {
            if !Task.isCancelled { phase = .failure(Self.message(for: error)) }
        }
    }
}
