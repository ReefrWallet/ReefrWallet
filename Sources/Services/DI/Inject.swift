//
//  ServiceInject.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 22.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

protocol ModuleInjecting {
    func inject<Dependency>(_ serviceType: Dependency.Type) -> Dependency?
    func injectOrFail<Dependency>(_ serviceType: Dependency.Type) -> Dependency
}

extension ServiceContainer: ModuleInjecting {
    func inject<Dependency>(_ serviceType: Dependency.Type) -> Dependency? {
        return self.resolve(serviceType)
    }

    func injectOrFail<Dependency>(_ serviceType: Dependency.Type) -> Dependency {
        return self.resolveOrFail(serviceType)
    }
}

enum Inject {
    enum InjectionMode {
        case standard
        case test
    }

    static var container: ServiceContainer = Inject.buildDefaultContainer()

    static var mode: InjectionMode = .standard {
        didSet {
            switch mode {
            case .standard:
                container = Inject.buildDefaultContainer()
            case .test:
                container = Inject.buildTestContainer()
            }
        }
    }

    fileprivate static func buildDefaultContainer() -> ServiceContainer {
        let container = ServiceContainer()
            .registerModelContainer()
            .registerCore()

        return container
    }

    public static var buildTestContainer: () -> ServiceContainer = {
        let container = ServiceContainer()
            .registerModelContainer(useInMemoryStore: true)
            .registerCore()

        return container
    }
}

var DI: ModuleInjecting {
    Inject.container
}
