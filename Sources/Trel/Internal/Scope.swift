import Foundation

struct User {
    var id: String?
    var email: String?
    var name: String?

    var isEmpty: Bool { id == nil && email == nil && name == nil }

    func apply(to attrs: inout [String: Any]) {
        if let id = id { attrs[Attr.userId] = id }
        if let email = email { attrs[Attr.userEmail] = email }
        if let name = name { attrs[Attr.userName] = name }
    }
}

/// Per-process mutable context: user, tags, breadcrumb ring buffer. Thread-safe.
final class Scope {
    private let lock = NSLock()
    private let maxBreadcrumbs: Int
    private var crumbs: [Breadcrumb] = []
    private var tagMap: [String: String] = [:]
    private var userValue = User()

    init(maxBreadcrumbs: Int) {
        self.maxBreadcrumbs = max(1, min(100, maxBreadcrumbs))
    }

    var user: User {
        lock.lock(); defer { lock.unlock() }
        return userValue
    }

    var tags: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return tagMap
    }

    func setUser(id: String?, email: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        userValue = User(id: id, email: email, name: name)
    }

    func setTag(_ key: String, _ value: String?) {
        let k = String(key.trimmingCharacters(in: .whitespaces).prefix(64))
        guard !k.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let value = value {
            if tagMap.count < 20 || tagMap[k] != nil { tagMap[k] = String(value.prefix(200)) }
        } else {
            tagMap.removeValue(forKey: k)
        }
    }

    func add(_ b: Breadcrumb) {
        lock.lock(); defer { lock.unlock() }
        crumbs.append(b)
        if crumbs.count > maxBreadcrumbs { crumbs.removeFirst(crumbs.count - maxBreadcrumbs) }
    }

    func breadcrumbs() -> [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return crumbs
    }
}
