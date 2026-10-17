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

struct Inject {
    enum InjectionMode {
        case preview
        case standard
        case test
    }

    static var container: ServiceContainer = Inject.buildDefaultContainer()

    /// An on-disk store that replaces the default (or test-mode in-memory) one — lets UI
    /// tests relaunch the app onto the same database. Set before the container resolves.
    static var storeURLOverride: URL?

    static var mode: InjectionMode = .standard {
        didSet {
            switch mode {
            case .preview:
                printDebug("Using preview DI mode")
                container = Inject.buildInMemoryContainer()
            case .standard:
                printDebug("Using standard DI mode")
                container = Inject.buildDefaultContainer()
            case .test:
                printDebug("Using test DI mode")
                container = Inject.buildInMemoryContainer()
            }
        }
    }

    private static func buildDefaultContainer() -> ServiceContainer {
        let container = ServiceContainer()
            .registerModelContainer()
            .registerCore()
            .registerDapps()
        return container
    }

    private static var buildInMemoryContainer: () -> ServiceContainer = {
        let container = ServiceContainer()
            .registerModelContainer(useInMemoryStore: true)
            .registerCore()
            .registerDapps()
        return container
    }
}

var DI: ModuleInjecting {
    Inject.container
}
