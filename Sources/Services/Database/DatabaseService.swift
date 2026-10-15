import SwiftData
import WalletKit

@ModelActor
actor DatabaseService {
    @discardableResult
    func insertBlockchain(_ blockchain: Blockchain) throws -> PersistentIdentifier {
        let serializedBlockchain = try blockchain.asJSONString()
        let predicate = #Predicate<BlockchainModel> { $0.serialized == serializedBlockchain }

        guard try modelContext.fetch(FetchDescriptor(predicate: predicate)).isEmpty else {
            throw Error.alreadyExists
        }

        let model = try BlockchainModel(blockchain: blockchain)
        modelContext.insert(model)
        try modelContext.save()
        return model.persistentModelID
    }
}
