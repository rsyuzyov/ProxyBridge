import NetworkExtension
import Foundation

enum RuleProtocol: String, Codable {
    case tcp = "TCP"
    case udp = "UDP"
    case both = "BOTH"
}

struct ProxyRule: Codable {
    var ruleId: UInt32
    let processNames: String
    let targetHosts: String
    let targetPorts: String
    let ruleProtocol: RuleProtocol
    let action: String  // "DIRECT", "BLOCK", or a proxy config UUID
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case ruleId
        case processNames
        case targetHosts
        case targetPorts
        case ruleProtocol
        case action = "ruleAction"
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ruleId = try container.decodeIfPresent(UInt32.self, forKey: .ruleId) ?? 0
        self.processNames = try container.decode(String.self, forKey: .processNames)
        self.targetHosts = try container.decode(String.self, forKey: .targetHosts)
        self.targetPorts = try container.decode(String.self, forKey: .targetPorts)
        self.ruleProtocol = try container.decode(RuleProtocol.self, forKey: .ruleProtocol)
        self.action = try container.decode(String.self, forKey: .action)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    init(ruleId: UInt32, processNames: String, targetHosts: String, targetPorts: String, ruleProtocol: RuleProtocol, action: String, enabled: Bool) {
        self.ruleId = ruleId
        self.processNames = processNames
        self.targetHosts = targetHosts
        self.targetPorts = targetPorts
        self.ruleProtocol = ruleProtocol
        self.action = action
        self.enabled = enabled
    }
    
    func matchesProcess(bundleId: String, processName: String?) -> Bool {
        if Self.matchProcessList(processNames, processPath: bundleId) {
            return true
        }
        
        if let procName = processName {
            if Self.matchProcessList(processNames, processPath: procName) {
                return true
            }
        }
        
        return false
    }
    
    func matchesIP(_ ipString: String) -> Bool {
        return Self.matchIPList(targetHosts, ipString: ipString)
    }
    
    func matchesPort(_ port: UInt16) -> Bool {
        return Self.matchPortList(targetPorts, port: port)
    }
    
    private static func matchProcessList(_ processList: String, processPath: String) -> Bool {
        if processList.isEmpty || processList == "*" {
            return true
        }
        
        let filename = (processPath as NSString).lastPathComponent
        let patterns = processList.components(separatedBy: CharacterSet(charactersIn: ",;"))
        
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchProcessPattern(trimmed, processPath: processPath, filename: filename) {
                return true
            }
        }
        return false
    }
    
    private static func matchProcessPattern(_ pattern: String, processPath: String, filename: String) -> Bool {
        if pattern.isEmpty || pattern == "*" {
            return true
        }
        
        let isFullPathPattern = pattern.contains("/") || pattern.contains("\\")
        let matchTarget = isFullPathPattern ? processPath : filename
        
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return matchTarget.lowercased().hasPrefix(prefix.lowercased())
        }
        
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return matchTarget.lowercased().hasSuffix(suffix.lowercased())
        }
        
        if let starIndex = pattern.firstIndex(of: "*") {
            let prefix = String(pattern[..<starIndex])
            let suffix = String(pattern[pattern.index(after: starIndex)...])
            let lower = matchTarget.lowercased()
            return lower.hasPrefix(prefix.lowercased()) && lower.hasSuffix(suffix.lowercased())
        }
        
        return matchTarget.lowercased() == pattern.lowercased()
    }
    
    private static func matchIPList(_ ipList: String, ipString: String) -> Bool {
        if ipList.isEmpty || ipList == "*" {
            return true
        }
        
        let patterns = ipList.components(separatedBy: ";")
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchIPPattern(trimmed, ipString: ipString) {
                return true
            }
        }
        return false
    }
    
    private static func ipToInteger(_ ipString: String) -> UInt32? {
        let octets = ipString.components(separatedBy: ".")
        guard octets.count == 4 else { return nil }
        
        var result: UInt32 = 0
        for octet in octets {
            guard let value = UInt8(octet) else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }
    
    private static func matchIPPattern(_ pattern: String, ipString: String) -> Bool {
        if pattern.isEmpty || pattern == "*" {
            return true
        }
        
        // ip range, e.g. 192.168.1.1-192.168.1.254
        if pattern.contains("-") {
            let parts = pattern.components(separatedBy: "-")
            if parts.count == 2 {
                let startIP = parts[0].trimmingCharacters(in: .whitespaces)
                let endIP = parts[1].trimmingCharacters(in: .whitespaces)
                
                if let startInt = ipToInteger(startIP),
                   let endInt = ipToInteger(endIP),
                   let targetInt = ipToInteger(ipString) {
                    return targetInt >= startInt && targetInt <= endInt
                }
            }
            return false
        }
        
        // wildcard, e.g. 192.168.1.*
        let patternOctets = pattern.components(separatedBy: ".")
        let ipOctets = ipString.components(separatedBy: ".")
        
        if patternOctets.count != 4 || ipOctets.count != 4 {
            return false
        }
        
        for i in 0..<4 {
            if patternOctets[i] == "*" {
                continue
            }
            if patternOctets[i] != ipOctets[i] {
                return false
            }
        }
        return true
    }
    
    private static func matchPortList(_ portList: String, port: UInt16) -> Bool {
        if portList.isEmpty || portList == "*" {
            return true
        }
        
        let patterns = portList.components(separatedBy: CharacterSet(charactersIn: ",;"))
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if matchPortPattern(trimmed, port: port) {
                return true
            }
        }
        return false
    }
    
    private static func matchPortPattern(_ pattern: String, port: UInt16) -> Bool {
        if pattern.isEmpty || pattern == "*" {
            return true
        }
        
        if let dashIndex = pattern.firstIndex(of: "-") {
            let startStr = String(pattern[..<dashIndex])
            let endStr = String(pattern[pattern.index(after: dashIndex)...])
            
            if let start = UInt16(startStr), let end = UInt16(endStr) {
                return port >= start && port <= end
            }
            return false
        }
        
        if let patternPort = UInt16(pattern) {
            return port == patternPort
        }
        return false
    }
}

class AppProxyProvider: NETransparentProxyProvider {
    
    // one log entry, kept as an enum so we don't allocate a dictionary per line,
    // the dict is only built when the gui drains a batch
    private enum LogEntry {
        case connection(proto: String, process: String, destination: String, port: String, proxy: String)
        case activity(timestamp: String, level: String, message: String)

        func toDict() -> [String: String] {
            switch self {
            case let .connection(proto, process, destination, port, proxy):
                return ["type": "connection", "protocol": proto, "process": process,
                        "destination": destination, "port": port, "proxy": proxy]
            case let .activity(timestamp, level, message):
                return ["type": "activity", "timestamp": timestamp, "level": level, "message": message]
            }
        }
    }

    // circular buffer for logs, avoids shifting the whole array on every pop
    private static let logCapacity = 1000
    private var logBuffer = [LogEntry?](repeating: nil, count: AppProxyProvider.logCapacity)
    private var logHead = 0
    private var logTail = 0
    private var logCount = 0
    private let logQueueLock = NSLock()
    private let dateFormatter: ISO8601DateFormatter = ISO8601DateFormatter()
    
    // cache by pid so we don't call proc_pidpath on every connection
    private var pidCache: [pid_t: String] = [:]
    private let pidCacheLock = NSLock()
    private static let pidCacheMaxSize = 256
    
    private func getProcessName(from metaData: NEFlowMetaData) -> String? {
        guard let auditTokenData = metaData.sourceAppAuditToken else {
            return nil
        }
        guard auditTokenData.count == MemoryLayout<audit_token_t>.size else {
            return nil
        }
        
        let pid = auditTokenData.withUnsafeBytes { ptr -> pid_t in
            guard let baseAddress = ptr.baseAddress else { return 0 }
            let token = baseAddress.assumingMemoryBound(to: UInt32.self)
            return pid_t(token[5])
        }
        
        guard pid > 0 else { return nil }
        
        pidCacheLock.lock()
        if let cached = pidCache[pid] {
            pidCacheLock.unlock()
            return cached
        }
        pidCacheLock.unlock()

        var pathBuffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN)) > 0 else {
            return nil
        }
        
        let fullPath = String(cString: pathBuffer)
        let processName = (fullPath as NSString).lastPathComponent
        
        // store in cache, evict everything if full - processes rarely hit this
        pidCacheLock.lock()
        if pidCache.count >= AppProxyProvider.pidCacheMaxSize {
            pidCache.removeAll(keepingCapacity: true)
        }
        pidCache[pid] = processName
        pidCacheLock.unlock()
        
        return processName
    }
    
    // guarded by its own lock, the old OSAtomic compare-and-swap setter could
    // silently no-op if the stored value wasn't the exact expected one
    private var _trafficLoggingEnabled = true
    private let trafficLoggingLock = NSLock()
    private var trafficLoggingEnabled: Bool {
        get { trafficLoggingLock.lock(); defer { trafficLoggingLock.unlock() }; return _trafficLoggingEnabled }
        set { trafficLoggingLock.lock(); _trafficLoggingEnabled = newValue; trafficLoggingLock.unlock() }
    }
    
    private var rules: [ProxyRule] = []
    private let rulesLock = NSLock()
    private var nextRuleId: UInt32 = 1
    
    private struct StoredProxyConfig {
        let type: String
        let host: String
        let port: Int
        let username: String?
        let password: String?
    }
    private var storedProxyConfigs: [String: StoredProxyConfig] = [:]
    private let proxyLock = NSLock()
    
    private func log(_ message: String, level: String = "INFO") {
        appendLog(.activity(timestamp: dateFormatter.string(from: Date()), level: level, message: message))
    }

    private func appendLog(_ entry: LogEntry) {
        logQueueLock.lock()
        logBuffer[logTail] = entry
        logTail = (logTail + 1) % AppProxyProvider.logCapacity
        if logCount < AppProxyProvider.logCapacity {
            logCount += 1
        } else {
            // buffer full, bump head to drop the oldest entry
            logHead = (logHead + 1) % AppProxyProvider.logCapacity
        }
        logQueueLock.unlock()
    }

    override func startProxy(options: [String : Any]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        
        let allTrafficRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .any,
            direction: .outbound
        )
        
        settings.includedNetworkRules = [allTrafficRule]
        
        self.setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }
    
    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        udpLock.lock()
        let all = Array(udpAssociations.values)
        udpAssociations.removeAll()
        udpLock.unlock()
        for a in all {
            a.controlConnection.cancel()
            a.udpSession.cancel()
        }
        completionHandler()
    }
    
    // one association per udp flow, holds both channels so we tear the whole thing
    // down together when any side goes away
    private final class UDPAssociation {
        let clientFlow: NEAppProxyUDPFlow
        let controlConnection: NWTCPConnection  // socks5 tcp control channel, keeps the association alive
        let udpSession: NWUDPSession            // relay channel to the socks server
        let processPath: String
        var loggedDestinations = Set<String>()  // dedupe connection logs, bounded
        var isTornDown = false

        init(clientFlow: NEAppProxyUDPFlow, controlConnection: NWTCPConnection, udpSession: NWUDPSession, processPath: String) {
            self.clientFlow = clientFlow
            self.controlConnection = controlConnection
            self.udpSession = udpSession
            self.processPath = processPath
        }
    }
    private var udpAssociations: [NEAppProxyUDPFlow: UDPAssociation] = [:]
    private let udpLock = NSLock()
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }
        
        switch action {
        case "getLogs":
            logQueueLock.lock()
            if logCount > 0 {
                let batchSize = min(100, logCount)
                var logsToSend: [[String: String]] = []
                logsToSend.reserveCapacity(batchSize)
                for _ in 0..<batchSize {
                    if let entry = logBuffer[logHead] {
                        logsToSend.append(entry.toDict())
                    }
                    logBuffer[logHead] = nil  // release the drained entry
                    logHead = (logHead + 1) % AppProxyProvider.logCapacity
                    logCount -= 1
                }
                logQueueLock.unlock()
                completionHandler?(try? JSONSerialization.data(withJSONObject: logsToSend))
            } else {
                logQueueLock.unlock()
                completionHandler?(nil)
            }
        case "setTrafficLogging":
            if let enabled = message["enabled"] as? Bool {
                trafficLoggingEnabled = enabled
                let response = ["status": "ok"]
                completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            } else {
                completionHandler?(nil)
            }
        case "setProxyConfigs":
            if let configs = message["configs"] as? [[String: Any]] {
                proxyLock.lock()
                storedProxyConfigs = [:]
                for configDict in configs {
                    guard let id = configDict["id"] as? String,
                          let type = configDict["proxyType"] as? String,
                          let host = configDict["proxyHost"] as? String,
                          let port = configDict["proxyPort"] as? Int else { continue }
                    storedProxyConfigs[id] = StoredProxyConfig(
                        type: type, host: host, port: port,
                        username: configDict["proxyUsername"] as? String,
                        password: configDict["proxyPassword"] as? String
                    )
                }
                proxyLock.unlock()
                log("Proxy configs updated: \(storedProxyConfigs.count) config(s)")
            }
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "ok"]))

        case "addRule":
            if let ruleData = try? JSONSerialization.data(withJSONObject: message),
               var rule = try? JSONDecoder().decode(ProxyRule.self, from: ruleData) {
                rulesLock.lock()
                rule.ruleId = nextRuleId
                nextRuleId += 1
                rules.append(rule)
                rulesLock.unlock()
                
                log("Added rule #\(rule.ruleId): \(rule.processNames) -> \(rule.action)")

                let response: [String: Any] = [
                    "status": "ok",
                    "ruleId": rule.ruleId,
                    "processNames": rule.processNames,
                    "targetHosts": rule.targetHosts,
                    "targetPorts": rule.targetPorts,
                    "protocol": rule.ruleProtocol.rawValue,
                    "action": rule.action,
                    "enabled": rule.enabled
                ]
                completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            } else {
                let response = ["status": "error", "message": "Invalid rule format"]
                completionHandler?(try? JSONSerialization.data(withJSONObject: response))
            }
        
        case "clearRules":
            rulesLock.lock()
            let count = rules.count
            rules.removeAll()
            rulesLock.unlock()
            log("Cleared all rules (\(count) rules)")
            let response: [String: Any] = ["status": "ok", "cleared": count]
            completionHandler?(try? JSONSerialization.data(withJSONObject: response))
        
        case "clearConfig":
            // drop the stored proxy configs so credentials don't sit in memory after stop
            proxyLock.lock()
            storedProxyConfigs.removeAll()
            proxyLock.unlock()
            completionHandler?(try? JSONSerialization.data(withJSONObject: ["status": "ok"]))
        default:
            completionHandler?(nil)
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    override func wake() {
    }
    
    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handleTCPFlow(tcpFlow)
        } else if let udpFlow = flow as? NEAppProxyUDPFlow {
            return handleUDPFlow(udpFlow)
        }
        return false
    }
    
    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) -> Bool {
        let metaData = flow.metaData
        let processPath = metaData.sourceAppSigningIdentifier
        
        // never proxy our own traffic, it would loop
        if processPath == "com.interceptsuite.ProxyBridge" || processPath == "com.interceptsuite.ProxyBridge.extension" {
            return false
        }

        let remoteEndpoint = flow.remoteEndpoint
        var destination = ""
        var portNum: UInt16 = 0
        var portStr = ""
        
        if let remoteHost = remoteEndpoint as? NWHostEndpoint {
            destination = remoteHost.hostname
            portStr = remoteHost.port
            portNum = UInt16(portStr) ?? 0
        } else {
            destination = String(describing: remoteEndpoint)
            portStr = "unknown"
        }
        
        let processName = getProcessName(from: metaData)
        let displayName = processName ?? processPath
        
        proxyLock.lock()
        let hasProxyConfig = !storedProxyConfigs.isEmpty
        proxyLock.unlock()

        if !hasProxyConfig {
            sendLogToApp(protocol: "TCP", process: displayName, destination: destination, port: portStr, proxy: "Direct")
            return false
        }

        let matchedRule = findMatchingRule(bundleId: processPath, processName: processName, destination: destination, port: portNum, connectionProtocol: .tcp, checkIpPort: true)

        if let rule = matchedRule {
            let action = rule.action
            sendLogToApp(protocol: "TCP", process: displayName, destination: destination, port: portStr, proxy: action)

            switch action {
            case "DIRECT":
                return false
            case "BLOCK":
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
                return true
            default:
                proxyLock.lock()
                let config = storedProxyConfigs[action]
                proxyLock.unlock()
                guard let config = config else { return false }
                proxyTCPFlow(flow, destination: destination, port: portNum, config: config)
                return true
            }
        } else {
            sendLogToApp(protocol: "TCP", process: displayName, destination: destination, port: portStr, proxy: "Direct")
            return false
        }
    }
    
    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) -> Bool {
        var processPath = "unknown"
        var processName: String?
        if let metaData = flow.metaData as? NEFlowMetaData {
            processPath = metaData.sourceAppSigningIdentifier
            processName = getProcessName(from: metaData)
        }
        
        let displayName = processName ?? processPath
        
        if processPath == "com.interceptsuite.ProxyBridge" || processPath == "com.interceptsuite.ProxyBridge.extension" {
            return false
        }
        
        proxyLock.lock()
        let hasAnySocks5 = storedProxyConfigs.values.contains { $0.type.lowercased() == "socks5" }
        proxyLock.unlock()

        if !hasAnySocks5 {
            return false
        }

        let matchedRule = findMatchingRule(bundleId: processPath, processName: processName, destination: "", port: 0, connectionProtocol: .udp, checkIpPort: false)

        if let rule = matchedRule {
            let action = rule.action
            switch action {
            case "DIRECT":
                sendLogToApp(protocol: "UDP", process: displayName, destination: "unknown", port: "unknown", proxy: "Direct")
                return false
            case "BLOCK":
                sendLogToApp(protocol: "UDP", process: displayName, destination: "unknown", port: "unknown", proxy: "BLOCK")
                return true
            default:
                proxyLock.lock()
                let matched = storedProxyConfigs[action]
                proxyLock.unlock()
                guard let socks5Config = matched, socks5Config.type.lowercased() == "socks5" else { return false }
                flow.open(withLocalEndpoint: nil) { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.log("Failed to open UDP flow: \(error.localizedDescription)", level: "ERROR")
                        return
                    }
                    self.proxyUDPFlowViaSOCKS5(flow, processPath: processPath, socksHost: socks5Config.host, socksPort: socks5Config.port)
                }
                return true
            }
        } else {
            sendLogToApp(protocol: "UDP", process: displayName, destination: "unknown", port: "unknown", proxy: "Direct")
            return false
        }
    }
    
    // handshake failed before an association existed, so drop the control
    // connection and close the flow instead of leaking them
    private func failUDPHandshake(_ clientFlow: NEAppProxyUDPFlow, _ tcpConnection: NWTCPConnection, _ reason: String) {
        log(reason, level: "ERROR")
        tcpConnection.cancel()
        clientFlow.closeReadWithError(nil)
        clientFlow.closeWriteWithError(nil)
    }

    private func proxyUDPFlowViaSOCKS5(_ clientFlow: NEAppProxyUDPFlow, processPath: String, socksHost: String, socksPort: Int) {
        let proxyEndpoint = NWHostEndpoint(hostname: socksHost, port: String(socksPort))
        let tcpConnection = createTCPConnection(to: proxyEndpoint, enableTLS: false, tlsParameters: nil, delegate: nil)

        let greetingData = Data([0x05, 0x01, 0x00])

        tcpConnection.write(greetingData) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP greeting failed: \(error.localizedDescription)")
                return
            }

            tcpConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }

                if let error = error {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP greeting response failed: \(error.localizedDescription)")
                    return
                }

                guard let data = data, data.count == 2, data[1] == 0x00 else {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP greeting response invalid")
                    return
                }

                self.sendSOCKS5UDPAssociate(clientFlow: clientFlow, tcpConnection: tcpConnection, socksHost: socksHost, processPath: processPath)
            }
        }
    }

    private func sendSOCKS5UDPAssociate(clientFlow: NEAppProxyUDPFlow, tcpConnection: NWTCPConnection, socksHost: String, processPath: String) {
        var request = Data()
        request.append(0x05)
        request.append(0x03)
        request.append(0x00)
        request.append(0x01)
        request.append(contentsOf: [0, 0, 0, 0])
        request.append(contentsOf: [0, 0])
        
        tcpConnection.write(request) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE failed: \(error.localizedDescription)")
                return
            }

            tcpConnection.readMinimumLength(10, maximumLength: 512) { [weak self] data, error in
                guard let self = self else { return }

                if let error = error {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE response error: \(error.localizedDescription)")
                    return
                }

                guard let data = data, data.count >= 10, data[0] == 0x05, data[1] == 0x00 else {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE rejected")
                    return
                }

                let (parsedHost, relayPort) = self.parseSOCKS5Address(from: data, offset: 3)
                // many socks servers reply 0.0.0.0 meaning "reuse the control connection host"
                let relayHost = (parsedHost == "0.0.0.0" || parsedHost == "::" || parsedHost.isEmpty) ? socksHost : parsedHost
                guard relayPort != 0 else {
                    self.failUDPHandshake(clientFlow, tcpConnection, "SOCKS5 UDP ASSOCIATE returned no relay port")
                    return
                }
                self.relayUDPThroughSOCKS5(clientFlow: clientFlow, relayHost: relayHost, relayPort: relayPort, tcpConnection: tcpConnection, processPath: processPath)
            }
        }
    }
    
    private func parseSOCKS5Address(from data: Data, offset: Int) -> (String, UInt16) {
        guard data.count > offset else { return ("0.0.0.0", 0) }
        let atyp = data[offset]

        if atyp == 0x01 {
            guard data.count >= offset + 7 else { return ("0.0.0.0", 0) }
            let ip = "\(data[offset+1]).\(data[offset+2]).\(data[offset+3]).\(data[offset+4])"
            let port = (UInt16(data[offset+5]) << 8) | UInt16(data[offset+6])
            return (ip, port)
        } else if atyp == 0x04 {
            guard data.count >= offset + 19 else { return ("0.0.0.0", 0) }
            var ipv6Parts: [String] = []
            for i in 0..<8 {
                let idx = offset + 1 + (i * 2)
                let part = (UInt16(data[idx]) << 8) | UInt16(data[idx+1])
                ipv6Parts.append(String(format: "%x", part))
            }
            let ip = ipv6Parts.joined(separator: ":")
            let port = (UInt16(data[offset+17]) << 8) | UInt16(data[offset+18])
            return (ip, port)
        } else if atyp == 0x03 {
            guard data.count >= offset + 2 else { return ("0.0.0.0", 0) }
            let len = Int(data[offset+1])
            guard data.count >= offset + 2 + len + 2 else { return ("0.0.0.0", 0) }
            let domain = String(data: data[(offset+2)..<(offset+2+len)], encoding: .utf8) ?? "unknown"
            let port = (UInt16(data[offset+2+len]) << 8) | UInt16(data[offset+2+len+1])
            return (domain, port)
        }

        return ("0.0.0.0", 0)
    }
    
    private func relayUDPThroughSOCKS5(clientFlow: NEAppProxyUDPFlow, relayHost: String, relayPort: UInt16, tcpConnection: NWTCPConnection, processPath: String) {
        let relayEndpoint = NWHostEndpoint(hostname: relayHost, port: String(relayPort))
        let udpSession = self.createUDPSession(to: relayEndpoint, from: nil)

        let association = UDPAssociation(clientFlow: clientFlow, controlConnection: tcpConnection, udpSession: udpSession, processPath: processPath)

        udpLock.lock()
        let existing = udpAssociations[clientFlow]
        udpAssociations[clientFlow] = association
        udpLock.unlock()
        // if the app reused a flow, drop the stale association first
        existing?.controlConnection.cancel()
        existing?.udpSession.cancel()

        readAndForwardClientUDP(association)
        readAndForwardRelayUDP(association)
        monitorControlConnection(association)
    }

    // idempotent, cancels both channels and closes the flow exactly once
    private func teardownUDP(_ flow: NEAppProxyUDPFlow) {
        udpLock.lock()
        guard let assoc = udpAssociations.removeValue(forKey: flow), !assoc.isTornDown else {
            udpLock.unlock()
            return
        }
        assoc.isTornDown = true
        udpLock.unlock()

        assoc.controlConnection.cancel()
        assoc.udpSession.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }

    // the socks control channel carries no data during a udp associate, so any
    // completion here means the server dropped it and the association is dead
    private func monitorControlConnection(_ association: UDPAssociation) {
        let clientFlow = association.clientFlow
        association.controlConnection.readMinimumLength(1, maximumLength: 1) { [weak self] _, _ in
            self?.teardownUDP(clientFlow)
        }
    }

    private func readAndForwardClientUDP(_ association: UDPAssociation) {
        let clientFlow = association.clientFlow
        clientFlow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self = self else { return }

            if let error = error {
                self.log("UDP read error: \(error.localizedDescription)", level: "ERROR")
                self.teardownUDP(clientFlow)
                return
            }

            // nil datagrams with no error = flow closed cleanly
            guard let datagrams = datagrams, let endpoints = endpoints else {
                self.teardownUDP(clientFlow)
                return
            }

            // non-nil but empty = nothing this round, just re-arm
            guard !datagrams.isEmpty else {
                self.readAndForwardClientUDP(association)
                return
            }

            var toSend: [Data] = []
            toSend.reserveCapacity(datagrams.count)

            for i in 0..<min(datagrams.count, endpoints.count) {
                guard let nwHost = endpoints[i] as? NWHostEndpoint else { continue }
                let destHost = nwHost.hostname
                let destPort = UInt16(nwHost.port) ?? 0
                guard destPort != 0 else { continue }

                // log each distinct destination once, cap the set so it can't grow forever
                if !association.loggedDestinations.contains(destHost) {
                    if association.loggedDestinations.count < 64 {
                        association.loggedDestinations.insert(destHost)
                    }
                    self.sendLogToApp(protocol: "UDP", process: association.processPath, destination: destHost, port: nwHost.port, proxy: "SOCKS5")
                }

                if let encapsulated = self.encapsulateSOCKS5UDP(datagram: datagrams[i], destHost: destHost, destPort: destPort) {
                    toSend.append(encapsulated)
                }
            }

            if !toSend.isEmpty {
                association.udpSession.writeMultipleDatagrams(toSend) { [weak self] error in
                    if let error = error {
                        self?.log("UDP write error: \(error.localizedDescription)", level: "ERROR")
                    }
                }
            }

            self.readAndForwardClientUDP(association)
        }
    }

    private func readAndForwardRelayUDP(_ association: UDPAssociation) {
        let clientFlow = association.clientFlow
        association.udpSession.setReadHandler({ [weak self] datagrams, error in
            guard let self = self else { return }

            if let error = error {
                // covers relay failures and icmp port-unreachable surfacing as a read error
                self.log("UDP relay error: \(error.localizedDescription)", level: "ERROR")
                self.teardownUDP(clientFlow)
                return
            }

            guard let datagrams = datagrams, !datagrams.isEmpty else { return }

            var payloads: [Data] = []
            var endpoints: [NWEndpoint] = []
            payloads.reserveCapacity(datagrams.count)
            endpoints.reserveCapacity(datagrams.count)

            for datagram in datagrams {
                if let (payload, destHost, destPort) = self.decapsulateSOCKS5UDPWithEndpoint(datagram: datagram) {
                    payloads.append(payload)
                    endpoints.append(NWHostEndpoint(hostname: destHost, port: String(destPort)))
                }
            }

            if !payloads.isEmpty {
                clientFlow.writeDatagrams(payloads, sentBy: endpoints) { [weak self] error in
                    if let error = error {
                        self?.log("UDP response write error: \(error.localizedDescription)", level: "ERROR")
                    }
                }
            }
        }, maxDatagrams: 32)
    }
    
    private func encapsulateSOCKS5UDP(datagram: Data, destHost: String, destPort: UInt16) -> Data? {
        if datagram.count > 1400 {
            self.log("Datagram too large (\(datagram.count) bytes), skipping", level: "WARN")
            return nil
        }
        
        var header = Data()
        header.append(contentsOf: [0, 0])
        header.append(0x00)
        
        if let ipv4 = IPv4Address(destHost) {
            header.append(0x01)
            header.append(contentsOf: ipv4.rawValue)
        } else if let ipv6 = IPv6Address(destHost) {
            header.append(0x04)
            header.append(contentsOf: ipv6.rawValue)
        } else {
            // length prefix must be the utf8 byte count, not the character count
            let hostBytes = Array(destHost.utf8)
            guard hostBytes.count <= 255 else {
                self.log("Domain name too long: \(hostBytes.count) bytes", level: "ERROR")
                return nil
            }
            header.append(0x03)
            header.append(UInt8(hostBytes.count))
            header.append(contentsOf: hostBytes)
        }
        
        header.append(UInt8(destPort >> 8))
        header.append(UInt8(destPort & 0xFF))
        
        var result = header
        result.append(datagram)
        
        if result.count > 1472 {
            self.log("Encapsulated datagram too large (\(result.count) bytes), skipping", level: "WARN")
            return nil
        }
        
        return result
    }
    
    private func decapsulateSOCKS5UDPWithEndpoint(datagram: Data) -> (Data, String, UInt16)? {
        guard datagram.count > 10 else { return nil }

        // byte 2 is FRAG, we don't reassemble so drop any fragmented datagram
        guard datagram[2] == 0x00 else { return nil }

        let atyp = datagram[3]
        var headerLen = 4
        var destHost = ""
        var destPort: UInt16 = 0

        if atyp == 0x01 {
            // ipv4 is 4 bytes + 2 port, already covered by count > 10
            destHost = "\(datagram[4]).\(datagram[5]).\(datagram[6]).\(datagram[7])"
            destPort = (UInt16(datagram[8]) << 8) | UInt16(datagram[9])
            headerLen += 6
        } else if atyp == 0x04 {
            // ipv6 needs 16 bytes + 2 port
            guard datagram.count >= 22 else { return nil }
            var ipv6Parts: [String] = []
            for i in 0..<8 {
                let idx = 4 + (i * 2)
                let part = (UInt16(datagram[idx]) << 8) | UInt16(datagram[idx+1])
                ipv6Parts.append(String(format: "%x", part))
            }
            destHost = ipv6Parts.joined(separator: ":")
            destPort = (UInt16(datagram[20]) << 8) | UInt16(datagram[21])
            headerLen += 18
        } else if atyp == 0x03 {
            // byte 4 is the domain length, then the domain, then 2 port bytes
            guard datagram.count >= 6 else { return nil }
            let domainLen = Int(datagram[4])
            guard datagram.count >= 5 + domainLen + 2 else { return nil }
            destHost = String(data: datagram[5..<(5+domainLen)], encoding: .utf8) ?? "unknown"
            destPort = (UInt16(datagram[5+domainLen]) << 8) | UInt16(datagram[5+domainLen+1])
            headerLen += 1 + domainLen + 2
        } else {
            return nil
        }

        guard datagram.count > headerLen else { return nil }

        let payload = datagram[headerLen...]
        return (Data(payload), destHost, destPort)
    }
    
    private func proxyTCPFlow(_ flow: NEAppProxyTCPFlow, destination: String, port: UInt16, config: StoredProxyConfig) {
        let proxyEndpoint = NWHostEndpoint(hostname: config.host, port: String(config.port))
        let proxyConnection = createTCPConnection(to: proxyEndpoint, enableTLS: false, tlsParameters: nil, delegate: nil)

        switch config.type.lowercased() {
        case "socks5":
            handleSOCKS5Proxy(clientFlow: flow, proxyConnection: proxyConnection, destination: destination, port: port, username: config.username, password: config.password)
        case "http":
            handleHTTPProxy(clientFlow: flow, proxyConnection: proxyConnection, destination: destination, port: port, username: config.username, password: config.password)
        default:
            log("unsupported proxy type: \(config.type)", level: "ERROR")
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
        }
    }
    
    private func handleSOCKS5Proxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String?, password: String?) {
        var greeting: [UInt8]
        if username != nil && password != nil {
            greeting = [0x05, 0x02, 0x00, 0x02]
        } else {
            greeting = [0x05, 0x01, 0x00]
        }
        
        let greetingData = Data(greeting)
        proxyConnection.write(greetingData) { [weak self] error in
            if let error = error {
                self?.log("SOCKS5 greeting write failed: \(error.localizedDescription)", level: "ERROR")
                clientFlow.closeReadWithError(error)
                clientFlow.closeWriteWithError(error)
                proxyConnection.cancel()
                return
            }
            
            proxyConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("SOCKS5 greeting response failed: \(error.localizedDescription)", level: "ERROR")
                    clientFlow.closeReadWithError(error)
                    clientFlow.closeWriteWithError(error)
                    proxyConnection.cancel()
                    return
                }
                
                guard let data = data, data.count == 2 else {
                    self.log("SOCKS5 invalid greeting response", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                    return
                }
                
                let version = data[0]
                let method = data[1]
                
                if version != 0x05 {
                    self.log("SOCKS5 invalid version: \(version)", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                    return
                }
                
                if method == 0x00 {
                    self.sendSOCKS5ConnectRequest(clientFlow: clientFlow, proxyConnection: proxyConnection, destination: destination, port: port)
                } else if method == 0x02 {
                    self.sendSOCKS5Auth(clientFlow: clientFlow, proxyConnection: proxyConnection, destination: destination, port: port, username: username ?? "", password: password ?? "")
                } else {
                    self.log("SOCKS5 no acceptable auth method: \(method)", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                }
            }
        }
    }
    
    private func sendSOCKS5Auth(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String, password: String) {
        var authData = Data()
        authData.append(0x01)
        authData.append(UInt8(username.count))
        authData.append(username.data(using: .utf8) ?? Data())
        authData.append(UInt8(password.count))
        authData.append(password.data(using: .utf8) ?? Data())
        
        proxyConnection.write(authData) { [weak self] error in
            if let error = error {
                self?.log("SOCKS5 auth write failed: \(error.localizedDescription)", level: "ERROR")
                clientFlow.closeReadWithError(error)
                clientFlow.closeWriteWithError(error)
                proxyConnection.cancel()
                return
            }
            
            proxyConnection.readMinimumLength(2, maximumLength: 2) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("SOCKS5 auth response failed: \(error.localizedDescription)", level: "ERROR")
                    clientFlow.closeReadWithError(error)
                    clientFlow.closeWriteWithError(error)
                    proxyConnection.cancel()
                    return
                }
                
                guard let data = data, data.count == 2, data[1] == 0x00 else {
                    self.log("SOCKS5 auth failed", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                    return
                }
                
                self.sendSOCKS5ConnectRequest(clientFlow: clientFlow, proxyConnection: proxyConnection, destination: destination, port: port)
            }
        }
    }
    
    private func sendSOCKS5ConnectRequest(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16) {
        var request = Data()
        request.append(0x05)
        request.append(0x01)
        request.append(0x00)
        
        if let ipAddr = IPv4Address(destination) {
            request.append(0x01)
            request.append(contentsOf: ipAddr.rawValue)
        } else if let ipAddr = IPv6Address(destination) {
            request.append(0x04)
            request.append(contentsOf: ipAddr.rawValue)
        } else {
            request.append(0x03)
            request.append(UInt8(destination.count))
            request.append(destination.data(using: .utf8) ?? Data())
        }
        
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        
        proxyConnection.write(request) { [weak self] error in
            if let error = error {
                self?.log("SOCKS5 connect write failed: \(error.localizedDescription)", level: "ERROR")
                clientFlow.closeReadWithError(error)
                clientFlow.closeWriteWithError(error)
                proxyConnection.cancel()
                return
            }
            
            proxyConnection.readMinimumLength(10, maximumLength: 512) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("SOCKS5 connect response failed: \(error.localizedDescription)", level: "ERROR")
                    clientFlow.closeReadWithError(error)
                    clientFlow.closeWriteWithError(error)
                    proxyConnection.cancel()
                    return
                }
                
                guard let data = data, data.count >= 10, data[0] == 0x05, data[1] == 0x00 else {
                    self.log("SOCKS5 connect failed", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                    return
                }
                
                self.log("SOCKS5 connection established to \(destination):\(port)")
                self.relayData(clientFlow: clientFlow, proxyConnection: proxyConnection)
            }
        }
    }
    
    private func handleHTTPProxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection, destination: String, port: UInt16, username: String?, password: String?) {
        var request = "CONNECT \(destination):\(port) HTTP/1.1\r\n"
        request += "Host: \(destination):\(port)\r\n"
        
        if let username = username, let password = password {
            let credentials = "\(username):\(password)"
            if let credData = credentials.data(using: .utf8) {
                let base64Creds = credData.base64EncodedString()
                request += "Proxy-Authorization: Basic \(base64Creds)\r\n"
            }
        }
        
        request += "\r\n"
        
        guard let requestData = request.data(using: .utf8) else {
            log("HTTP CONNECT request encoding failed", level: "ERROR")
            clientFlow.closeReadWithError(nil)
            clientFlow.closeWriteWithError(nil)
            proxyConnection.cancel()
            return
        }
        
        proxyConnection.write(requestData) { [weak self] error in
            if let error = error {
                self?.log("HTTP CONNECT write failed: \(error.localizedDescription)", level: "ERROR")
                clientFlow.closeReadWithError(error)
                clientFlow.closeWriteWithError(error)
                proxyConnection.cancel()
                return
            }
            
            proxyConnection.readMinimumLength(1, maximumLength: 8192) { [weak self] data, error in
                guard let self = self else { return }
                
                if let error = error {
                    self.log("HTTP CONNECT response failed: \(error.localizedDescription)", level: "ERROR")
                    clientFlow.closeReadWithError(error)
                    clientFlow.closeWriteWithError(error)
                    proxyConnection.cancel()
                    return
                }
                
                guard let data = data,
                      let response = String(data: data, encoding: .utf8) else {
                    self.log("HTTP CONNECT invalid response", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                    return
                }
                
                if response.contains("200") {
                    self.log("HTTP CONNECT established to \(destination):\(port)")
                    self.relayData(clientFlow: clientFlow, proxyConnection: proxyConnection)
                } else {
                    self.log("HTTP CONNECT failed: \(response)", level: "ERROR")
                    clientFlow.closeReadWithError(nil)
                    clientFlow.closeWriteWithError(nil)
                    proxyConnection.cancel()
                }
            }
        }
    }
    
    private func relayData(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection) {
        clientFlow.open(withLocalEndpoint: nil) { [weak self] error in
            if let error = error {
                self?.log("Failed to open client flow: \(error.localizedDescription)", level: "ERROR")
                proxyConnection.cancel()
                return
            }
            
            self?.relayClientToProxy(clientFlow: clientFlow, proxyConnection: proxyConnection)
            self?.relayProxyToClient(clientFlow: clientFlow, proxyConnection: proxyConnection)
        }
    }
    
    private func relayClientToProxy(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection) {
        clientFlow.readData { [weak self] data, error in
            if let error = error {
                // ignore expected errors
                let code = (error as NSError).code
                if code != 57 && code != 54 && code != 89 {
                    self?.log("Client read error: \(error.localizedDescription)", level: "ERROR")
                }
                proxyConnection.cancel()
                return
            }
            
            guard let data = data, !data.isEmpty else {
                self?.log("Client closed connection")
                proxyConnection.cancel()
                return
            }
            
            proxyConnection.write(data) { error in
                if let error = error {
                    self?.log("Proxy write error: \(error.localizedDescription)", level: "ERROR")
                    clientFlow.closeReadWithError(error)
                    clientFlow.closeWriteWithError(error)
                } else {
                    self?.relayClientToProxy(clientFlow: clientFlow, proxyConnection: proxyConnection)
                }
            }
        }
    }
    
    private func relayProxyToClient(clientFlow: NEAppProxyTCPFlow, proxyConnection: NWTCPConnection) {
        proxyConnection.readMinimumLength(1, maximumLength: 65536) { [weak self] data, error in
            if let error = error {
                let code = (error as NSError).code
                if code != 57 && code != 54 && code != 89 {
                    self?.log("Proxy read error: \(error.localizedDescription)", level: "ERROR")
                }
                clientFlow.closeReadWithError(nil)
                clientFlow.closeWriteWithError(nil)
                return
            }
            
            guard let data = data, !data.isEmpty else {
                self?.log("Proxy closed connection")
                clientFlow.closeReadWithError(nil)
                clientFlow.closeWriteWithError(nil)
                return
            }
            
            clientFlow.write(data) { error in
                if let error = error {
                    self?.log("Client write error: \(error.localizedDescription)", level: "ERROR")
                    proxyConnection.cancel()
                } else {
                    self?.relayProxyToClient(clientFlow: clientFlow, proxyConnection: proxyConnection)
                }
            }
        }
    }
    
    private func findMatchingRule(bundleId: String, processName: String?, destination: String, port: UInt16, connectionProtocol: RuleProtocol, checkIpPort: Bool) -> ProxyRule? {
        rulesLock.lock()
        let currentRules = rules
        rulesLock.unlock()
        
        var wildcardRule: ProxyRule? = nil
        
        for rule in currentRules {
            guard rule.enabled else { continue }

            if rule.ruleProtocol != .both && rule.ruleProtocol != connectionProtocol {
                continue
            }

            let isWildcardProcess = (rule.processNames == "*" || rule.processNames.isEmpty)

            if isWildcardProcess {
                let hasIpFilter = (rule.targetHosts != "*" && !rule.targetHosts.isEmpty)
                let hasPortFilter = (rule.targetPorts != "*" && !rule.targetPorts.isEmpty)

                if hasIpFilter || hasPortFilter {
                    // udp has no destination here, so a filtered wildcard can't match
                    if checkIpPort, rule.matchesIP(destination), rule.matchesPort(port) {
                        return rule
                    }
                    continue
                }

                // pure wildcard, keep the first one as a fallback
                if wildcardRule == nil {
                    wildcardRule = rule
                }
                continue
            }

            if rule.matchesProcess(bundleId: bundleId, processName: processName) {
                if checkIpPort {
                    if rule.matchesIP(destination) && rule.matchesPort(port) {
                        return rule
                    }
                } else {
                    // udp matches on process alone
                    return rule
                }
            }
        }

        if let wildcardRule = wildcardRule {
            return wildcardRule
        }
        
        return nil
    }
    
    private func sendLogToApp(protocol: String, process: String, destination: String, port: String, proxy: String) {
        guard trafficLoggingEnabled else { return }
        appendLog(.connection(proto: `protocol`, process: process, destination: destination, port: port, proxy: proxy))
    }
}


