//
//  Result+Extensions.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 06.01.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension Result {
    var isSuccess: Bool {
        guard case .success = self else {
            return false
        }

        return true
    }

    var isFailure: Bool {
        !isSuccess
    }
}
