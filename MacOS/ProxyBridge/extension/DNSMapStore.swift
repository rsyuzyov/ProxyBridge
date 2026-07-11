import Foundation

// Shared IP -> domain map, populated by the DNS proxy and read by the transparent
// proxy. The two providers can run in separate processes, so the map lives in a
// file in the app group container. Each process keeps an in-memory copy; the
// reader reloads only when the file's mtime changes.
final class DNSMapStore {
    static let shared = DNSMapStore()

    private let appGroup = "group.com.interceptsuite.ProxyBridge"
    private let fileURL: URL?
    private let lock = NSLock()
    private var map: [String: Set<String>] = [:]   // ip -> domains
    private var order: [String] = []               // insertion order for eviction
    private let maxEntries = 1024
    private var lastMtime: Date?

    private init() {
        fileURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("dnsmap.json")
    }

    // wipe the map and its file. called on start so browsing domains don't
    // linger on disk across sessions.
    func clear() {
        lock.lock()
        map.removeAll()
        order.removeAll()
        lastMtime = nil
        lock.unlock()
        if let fileURL = fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // writer side (DNS proxy): remember that these IPs resolved for this domain
    func record(domain: String, ips: [String]) {
        let name = domain.lowercased()
        guard !name.isEmpty, !ips.isEmpty else { return }

        var changed = false
        lock.lock()
        for ip in ips {
            if map[ip] == nil {
                map[ip] = []
                order.append(ip)
                changed = true
                if order.count > maxEntries {
                    let evicted = order.removeFirst()
                    map[evicted] = nil
                }
            }
            if map[ip]?.insert(name).inserted == true { changed = true }
        }
        // only touch the file when something actually changed, most resolutions
        // are repeats of already-known domains
        let snapshot = changed ? map : nil
        lock.unlock()

        if let snapshot = snapshot { persist(snapshot) }
    }

    // reader side (transparent proxy): domains that resolved to this ip, if any
    func domains(forIP ip: String) -> [String] {
        reloadIfChanged()
        lock.lock()
        defer { lock.unlock() }
        return Array(map[ip] ?? [])
    }

    private func persist(_ snapshot: [String: Set<String>]) {
        guard let fileURL = fileURL else { return }
        let plain = snapshot.mapValues { Array($0) }
        guard let data = try? JSONSerialization.data(withJSONObject: plain) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func reloadIfChanged() {
        guard let fileURL = fileURL else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        lock.lock()
        let needsReload = mtime != nil && mtime != lastMtime
        if needsReload { lastMtime = mtime }
        lock.unlock()

        guard needsReload,
              let data = try? Data(contentsOf: fileURL),
              let plain = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else {
            return
        }
        lock.lock()
        map = plain.mapValues { Set($0) }
        lock.unlock()
    }
}
