import AppKit
import Foundation

// MARK: - GitHub Release 模型（API 通道）

struct GitHubRelease: Codable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    var version: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }

    var dmgAsset: GitHubAsset? {
        assets.first { $0.name.hasSuffix(".dmg") }
    }
}

struct GitHubAsset: Codable {
    let name: String
    let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

// MARK: - 下载进度回调

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    private var continuation: CheckedContinuation<URL, Error>?

    func resume(_ continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

// MARK: - UpdateChecker

/// 检查 GitHub Release 新版本；发现新版本后下载 DMG 并自动安装到 /Applications，重启应用。
/// 查询双通道：api.github.com 优先（信息全），403/限流时回退到 releases/latest 的
/// 302 重定向探测（共享出口 IP 的未认证 API 配额经常耗尽，github.com 主站不受影响）。
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading(Double) // 0...1
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let repoOwner = "steven0lisa"
    private let repoName = "open-my-app"
    private var pendingDownloadURL: URL?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: 检查

    func checkForUpdates() async {
        state = .checking
        do {
            let release = try await fetchViaAPI()
            apply(release)
        } catch {
            NSLog("[OpenMyApp] release API failed (\(error.localizedDescription)), falling back to redirect probe")
            do {
                let release = try await fetchViaRedirect()
                apply(release)
            } catch {
                state = .failed(localizedFailure("Update failed: %@", error))
            }
        }
    }

    private func apply(_ release: (version: String, assetURL: URL)) {
        guard isNewer(release.version, than: currentVersion) else {
            NSLog("[OpenMyApp] already up to date (\(currentVersion))")
            state = .upToDate
            return
        }
        NSLog("[OpenMyApp] update available: \(release.version) (current: \(currentVersion))")
        pendingDownloadURL = release.assetURL
        state = .available(version: release.version)
    }

    /// API 通道：信息完整（tag + asset 直链）
    private func fetchViaAPI() async throws -> (version: String, assetURL: URL) {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = release.dmgAsset, let assetURL = URL(string: asset.browserDownloadUrl) else {
            throw UpdateError.dmgNotFound
        }
        return (release.version, assetURL)
    }

    /// 回退通道：releases/latest 302 → /releases/tag/vX.Y.Z 提取 tag，
    /// DMG 直链按固定命名规律推导
    private func fetchViaRedirect() async throws -> (version: String, assetURL: URL) {
        final class RedirectPicker: NSObject, URLSessionDelegate {
            var location: String?
            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                willPerformHTTPRedirection response: HTTPURLResponse,
                newRequest request: URLRequest,
                completionHandler: @escaping (URLRequest?) -> Void
            ) {
                location = response.allHeaderFields["Location"] as? String
                completionHandler(nil) // 不跟随，保留 302 响应
            }
        }

        let delegate = RedirectPicker()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let url = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")!
        let (_, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 302,
              let location = delegate.location,
              let tag = URL(string: location)?.lastPathComponent, tag.hasPrefix("v") else {
            throw UpdateError.badResponse
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let assetURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/\(tag)/OpenMyApp-\(version).dmg")!
        return (version, assetURL)
    }

    // MARK: 下载 + 安装

    func downloadAndInstall() async {
        guard case .available(let version) = state, let downloadURL = pendingDownloadURL else { return }

        do {
            state = .downloading(0)
            let delegate = DownloadDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            delegate.onProgress = { [weak self] fraction in
                Task { @MainActor in self?.state = .downloading(fraction) }
            }
            let location: URL = try await withCheckedThrowingContinuation { continuation in
                delegate.resume(continuation)
                session.downloadTask(with: downloadURL).resume()
            }
            let dmgURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(downloadURL.lastPathComponent.isEmpty ? "OpenMyApp-update.dmg" : downloadURL.lastPathComponent)
            try? FileManager.default.removeItem(at: dmgURL)
            try FileManager.default.moveItem(at: location, to: dmgURL)

            state = .installing
            let dmgPath = dmgURL.path
            try await Task.detached(priority: .userInitiated) {
                try Self.installBlocking(dmgPath: dmgPath)
            }.value
            NSLog("[OpenMyApp] update installed, relaunching")
            relaunch()
        } catch {
            state = .failed(localizedFailure("Update failed: %@", error))
        }
    }

    // MARK: - 安装细节（后台线程执行）

    /// 挂载 DMG → 替换 /Applications 里的 app（由调用方负责重启）
    nonisolated private static func installBlocking(dmgPath: String) throws {
        let fileManager = FileManager.default
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("OpenMyAppUpdate-\(UUID().uuidString.prefix(6))")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        try run("/usr/bin/hdiutil", ["attach", dmgPath, "-nobrowse", "-quiet", "-mountpoint", mountPoint.path])
        defer {
            try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
            try? fileManager.removeItem(at: mountPoint)
        }

        let contents = try fileManager.contentsOfDirectory(atPath: mountPoint.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.appNotFoundInDMG
        }
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: mountPoint.appendingPathComponent(appName), to: destination)
        NSLog("[OpenMyApp] installed \(appName) to /Applications")
    }

    /// 以脱离方式延迟重启（等当前实例退出后再拉起新版本）
    nonisolated private static func relaunchBlocking() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n /Applications/OpenMyApp.app"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.commandFailed("\(executable): \(message.prefix(300))")
        }
    }

    private func relaunch() {
        Self.relaunchBlocking()
        NSApp.terminate(nil)
    }

    // MARK: - 工具

    private func localizedFailure(_ pattern: String, _ error: Error) -> String {
        String(format: NSLocalizedString(pattern, comment: ""), error.localizedDescription)
    }

    private func isNewer(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(latestParts.count, currentParts.count) {
            let l = index < latestParts.count ? latestParts[index] : 0
            let c = index < currentParts.count ? currentParts[index] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case dmgNotFound
    case appNotFoundInDMG
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return NSLocalizedString("Unexpected response from GitHub", comment: "")
        case .dmgNotFound:
            return NSLocalizedString("No DMG asset in the latest release", comment: "")
        case .appNotFoundInDMG:
            return NSLocalizedString("No app bundle found inside the DMG", comment: "")
        case .commandFailed(let detail):
            return detail
        }
    }
}
