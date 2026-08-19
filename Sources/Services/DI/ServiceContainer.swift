//
//  ServiceContainer.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

enum ObjectScope {
    case transient
    case container
}

final class ServiceContainer {
    private var factories: [String: (ObjectScope, () -> Any)] = [:]
    private var singletons: [String: Any] = [:]

    func register<T>(_ type: T.Type, scope: ObjectScope = .container, factory: @escaping () -> T) {
        let key = String(describing: type)
        factories[key] = (scope, factory)
    }

    func resolve<T>(_ type: T.Type) -> T? {
        let key = String(describing: type)

        if let (scope, factory) = factories[key] {
            switch scope {
            case .container:
                if let instance = singletons[key] as? T {
                    return instance
                }

                let instance = factory()
                singletons[key] = instance

                return instance as? T
            case .transient:
                return factory() as? T
            }
        }

        return nil
    }

    func resolveOrFail<T>(_ serviceType: T.Type) -> T {
        guard let service = self.resolve(serviceType) else {
            preconditionFailure("Service \(serviceType) not found")
        }

        return service
    }
}
