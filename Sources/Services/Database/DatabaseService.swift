import SwiftData
import WalletKit

struct AccountPage<Row: Sendable>: Sendable {
    let rows: [Row]
    let hasMore: Bool
}

@ModelActor
actor DatabaseService {
    @discardableResult
    func insertBlockchain(_ blockchain: Blockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }

        guard try modelContext.fetch(FetchDescriptor(predicate: predicate)).isEmpty else {
            throw ReefrError.alreadyExists
        }

        let model = try BlockchainModel(blockchain: blockchain)
        modelContext.insert(model)
        try modelContext.save()
        return model.persistentModelID
    }
}

extension ModelContainer {
    /// A fresh context sees the latest saved rows and binds its executor off the main queue.
    func readSnapshot<Value: Sendable>(
        _ read: @escaping @Sendable (DatabaseService) async throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let reader = DatabaseService(modelContainer: self)
            return try await read(reader)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Run once on entry, then coalesce saves that affect the requested snapshot.
    @MainActor
    func observeSaves(affecting entities: Set<String>, refresh: () async throws -> Void) async {
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { notification in
            guard (notification.object as? ModelContext)?.container === self else {
                return
            }

            let keys: [ModelContext.NotificationKey] = [
                .insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers, .invalidatedAllIdentifiers
            ]

            if keys.contains(where: { key in
                let ids = notification.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
                return ids.contains { entities.contains($0.entityName) }
            }) {
                continuation.yield(())
            }
        }

        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        continuation.yield(())
        for await _ in updates {
            do {
                try Task.checkCancellation()
                try await refresh()
                try await Task.sleep(for: .milliseconds(500))
            } catch is CancellationError {
                return
            } catch {
                printError(error)
            }
        }
    }
}
