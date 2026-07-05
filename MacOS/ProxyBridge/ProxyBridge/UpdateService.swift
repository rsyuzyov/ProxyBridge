import Foundation
import AppKit

// the update manifest served at download.interceptsuite.com, one entry per platform
struct UpdateManifest: Codable {
    let macos: PlatformRelease
}

struct PlatformRelease: Codable {
    let version: String
    let releaseDate: String
    let download: String
    let releaseNotes: String

    enum CodingKeys: String, CodingKey {
        case version
        case releaseDate = "release_date"
        case download
        case releaseNotes = "release_notes"
    }
}

struct VersionInfo {
    let currentVersion: String
    let latestVersion: String
    let isUpdateAvailable: Bool
    let downloadUrl: String?
    let fileName: String?
    let releaseNotesUrl: String?
    let error: String?
}

class UpdateService {
    private let manifestUrl = "https://download.interceptsuite.com/proxybridge.json"

    func checkForUpdates() async -> VersionInfo {
        do {
            guard let url = URL(string: manifestUrl) else {
                return errorVersion("Invalid update URL")
            }

            var request = URLRequest(url: url)
            request.setValue("ProxyBridge-UpdateChecker", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, _) = try await URLSession.shared.data(for: request)
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)

            let mac = manifest.macos
            let currentVersion = getCurrentVersion()
            let fileName = URL(string: mac.download)?.lastPathComponent ?? "ProxyBridge-Installer.pkg"
            let isUpdateAvailable = isNewerVersion(mac.version, currentVersion)
                && mac.download.lowercased().hasSuffix(".pkg")

            return VersionInfo(
                currentVersion: currentVersion,
                latestVersion: "v\(mac.version)",
                isUpdateAvailable: isUpdateAvailable,
                downloadUrl: mac.download,
                fileName: fileName,
                releaseNotesUrl: mac.releaseNotes,
                error: nil
            )
        } catch {
            return errorVersion("Failed to check for updates: \(error.localizedDescription)")
        }
    }

    func downloadUpdate(from urlString: String, fileName: String, progress: @escaping (Double) -> Void) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "UpdateService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "UpdateService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }

        let totalBytes = response.expectedContentLength
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        try? FileManager.default.removeItem(at: fileURL)

        var downloadedBytes: Int64 = 0
        var data = Data()
        if totalBytes > 0 { data.reserveCapacity(Int(totalBytes)) }

        // collect into a buffer and flush in chunks, and only report progress
        // every ~256kb so we aren't hopping to the main actor for every byte
        var buffer = [UInt8]()
        buffer.reserveCapacity(65536)
        let progressStep: Int64 = 256 * 1024
        var lastReported: Int64 = 0

        for try await byte in asyncBytes {
            buffer.append(byte)
            downloadedBytes += 1

            if buffer.count >= 65536 {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            if totalBytes > 0, downloadedBytes - lastReported >= progressStep {
                lastReported = downloadedBytes
                let progressValue = Double(downloadedBytes) / Double(totalBytes)
                await MainActor.run { progress(progressValue) }
            }
        }

        if !buffer.isEmpty {
            data.append(contentsOf: buffer)
        }

        if totalBytes > 0 {
            await MainActor.run { progress(1.0) }
        }

        try data.write(to: fileURL)
        return fileURL
    }

    func installUpdateAndQuit(installerPath: URL) {
        NSWorkspace.shared.open(installerPath)
        // let the installer come up before we quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func getCurrentVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return "v\(version)"
        }
        return "v3.1"
    }

    private func isNewerVersion(_ latest: String, _ current: String) -> Bool {
        let latestComponents = latest.split(separator: ".").compactMap { Int($0) }
        let currentVersionString = current.hasPrefix("v") ? String(current.dropFirst()) : current
        let currentComponents = currentVersionString.split(separator: ".").compactMap { Int($0) }

        for i in 0..<min(latestComponents.count, currentComponents.count) {
            if latestComponents[i] > currentComponents[i] {
                return true
            } else if latestComponents[i] < currentComponents[i] {
                return false
            }
        }

        return latestComponents.count > currentComponents.count
    }

    private func errorVersion(_ message: String) -> VersionInfo {
        return VersionInfo(
            currentVersion: getCurrentVersion(),
            latestVersion: "Error",
            isUpdateAvailable: false,
            downloadUrl: nil,
            fileName: nil,
            releaseNotesUrl: nil,
            error: message
        )
    }
}
