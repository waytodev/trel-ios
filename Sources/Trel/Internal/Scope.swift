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
    private var contexts: [String: String] = [:]
    private var runtime: [String: Any] = [:]
    private var screenName: String?
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

    func setScreen(_ name: String?) {
        lock.lock(); defer { lock.unlock() }
        screenName = name.map { String($0.prefix(120)) }
    }

    func setContext(_ name: String, _ json: String?) {
        let key = String(name.trimmingCharacters(in: .whitespaces).prefix(64))
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if let json = json { contexts[key] = String(json.prefix(8000)) } else { contexts.removeValue(forKey: key) }
    }

    func setRuntime(_ values: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        runtime = values
    }

    func apply(to attrs: inout [String: Any]) {
        lock.lock()
        let screen = screenName
        let ctx = contexts
        let run = runtime
        lock.unlock()
        if let screen = screen { attrs[Attr.screenName] = screen }
        for (k, v) in ctx { attrs[Attr.contextPrefix + k] = v }
        for (k, v) in run { attrs[k] = v }
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
