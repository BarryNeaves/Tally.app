//
//  Item.swift
//  Tally
//
//  Created by Barry Neaves on 15/06/2026.
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
