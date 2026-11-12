// Results that read many files (kept runs, curves) or draw a picture, kept between SwiftUI
// redraws: a view's body runs on every change, so it shouldn't redo that work each time.

import Foundation

/// A value worked out at most once every `maxAge` seconds, or again after `clear()`.
struct Cached<Value> {
    private var value: Value?
    private var made = Date.distantPast
    let maxAge: TimeInterval

    init(maxAge: TimeInterval = 2) { self.maxAge = maxAge }

    mutating func get(_ make: () -> Value) -> Value {
        if let value, Date().timeIntervalSince(made) < maxAge { return value }
        let fresh = make()
        (value, made) = (fresh, Date())
        return fresh
    }

    mutating func clear() { value = nil }
}

/// A value worked out again only when its key changes.
struct Memo<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?

    mutating func get(_ key: Key, _ make: () -> Value) -> Value {
        if let value, self.key == key { return value }
        let fresh = make()
        (self.key, value) = (key, fresh)
        return fresh
    }
}
