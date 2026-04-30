//
//  Item.swift
//  yprompt
//
//  Created by Giuseppe Cosenza on 30/04/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
