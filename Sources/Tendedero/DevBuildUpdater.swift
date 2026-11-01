import AppKit

/// Updates a keyless developer build from its own fork's tested dev-latest
/// pre-release, from Settings → Updates. The bundled mac-dev-update.sh does
/// the work: curl downloads leave no quarantine mark, so macOS does not ask
/// to Open Anyway, and every build is re-signed with one signing identity
/// kept on this Mac, so privacy permissions survive the update.
///
/// Only a build that recorded its commit and fork at build time takes part.
/// The official application never has these keys and keeps its own updater.
@MainActor
final class DevBuildUpdater: ObservableObject {
    struct Configuration: Equatable {
        let build: String
        let repository: String
    }

    static func configuration(from info: [String: Any]?) -> Configuration? {
        guard let build = info?["ClipBoardLineDevBuild"] as? String, isCommit(build),
              let repository = info?["ClipBoardLineDevRepository"] as? String,
              repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return Configuration(build: build, repository: repository)
    }

    static func isCommit(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    /// The published build text, or nil when it is not one commit.
    static func publishedBuild(_ data: Data) -> String? {
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return isCommit(value) ? value : nil
    }

    /// Any other tested commit of main is an update: dev-latest only moves
    /// forward, and a build never offers itself.
    static func offers(_ latest: String?, installed: String) -> Bool {
        guard let latest else { return false }
        return latest != installed
    }

    static let shared = DevBuildUpdater(info: Bundle.main.infoDictionary)

    let configuration: Configuration?
    @Published private(set) var status = L("Check for an update when you are ready.")
    @Published private(set) var error: String?
    @Published private(set) var availableBuild: String?
    @Published private(set) var busy = false

    init(info: [String: Any]?) {
        configuration = Self.configuration(from: info)
    }

    var isActive: Bool { configuration != nil }
    var installedShortBuild: String { configuration.map { String($0.build.prefix(7)) } ?? "" }

    private var latestURL: URL? {
        configuration.flatMap { URL(string: "https://github.com/\($0.repository)/releases/download/dev-latest/ClipBoardLine-Dev-build.txt") }
    }

    func check() {
        guard let configuration, let url = latestURL, !busy else { return }
        busy = true; error = nil; status = L("Checking for updates…")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        Task { [weak self] in
            let latest: String?
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                latest = (response as? HTTPURLResponse)?.statusCode == 200 ? Self.publishedBuild(data) : nil
            } catch { latest = nil }
            guard let self else { return }
            self.busy = false
            guard let latest else {
                self.availableBuild = nil
                self.status = L("Check for an update when you are ready.")
                self.error = L("The update could not be checked.")
                return
            }
            if Self.offers(latest, installed: configuration.build) {
                self.availableBuild = latest
                self.status = String(format: L("A new build is ready (%@)."), String(latest.prefix(7)))
            } else {
                self.availableBuild = nil
                self.status = String(format: L("Up to date (%@)."), self.installedShortBuild)
            }
        }
    }

    /// Prepares the signed update while the app keeps running, then hands the
    /// swap to a detached copy of the script and quits so it can replace us.
    func installAndReopen() {
        guard let configuration, availableBuild != nil, !busy,
              let script = Bundle.main.url(forResource: "mac-dev-update", withExtension: "sh") else { return }
        busy = true; error = nil; status = L("Downloading and preparing the update…")
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("clipboardline-dev-update-\(UUID().uuidString)")
        let output = logs.appendingPathExtension("out"), messages = logs.appendingPathExtension("err")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: messages.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "prepare"]
        process.environment = environment(configuration)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try? FileHandle(forWritingTo: output)
        process.standardError = try? FileHandle(forWritingTo: messages)
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let staged = (try? Data(contentsOf: output)).flatMap { data in
                        String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init)
                    }
                    let detail = (try? String(contentsOf: messages, encoding: .utf8))?
                        .components(separatedBy: .newlines).last { $0.hasPrefix("HATA:") || $0.contains("error") }
                    try? FileManager.default.removeItem(at: output)
                    try? FileManager.default.removeItem(at: messages)
                    self.prepared(code: code, staged: staged, detail: detail, script: script, configuration: configuration)
                }
            }
        }
        do { try process.run() } catch {
            busy = false
            self.error = String(format: L("The update could not be prepared: %@"), error.localizedDescription)
        }
    }

    private func prepared(code: Int32, staged: String?, detail: String?, script: URL, configuration: Configuration) {
        guard code == 0, let staged, Self.isCommit(staged) else {
            busy = false
            status = L("Check for an update when you are ready.")
            let reason = detail?.replacingOccurrences(of: "HATA: ", with: "") ?? "exit \(code)"
            error = String(format: L("The update could not be prepared: %@"), reason)
            return
        }
        // The swap outlives this app: it waits for us to quit, replaces the
        // bundle and reopens it, or reopens the previous app if it cannot.
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/bash")
        swap.arguments = ["-c", #"nohup /bin/bash "$0" swap --wait-pid "$1" >/dev/null 2>&1 &"#,
                          script.path, String(ProcessInfo.processInfo.processIdentifier)]
        swap.environment = environment(configuration)
        swap.standardInput = FileHandle.nullDevice
        swap.standardOutput = FileHandle.nullDevice
        swap.standardError = FileHandle.nullDevice
        do {
            try swap.run()
            swap.waitUntilExit()
        } catch {
            busy = false
            self.error = String(format: L("The update could not be prepared: %@"), error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
        // A pending edit can keep the app open; the swap then waits for it.
        busy = false
    }

    private func environment(_ configuration: Configuration) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["CLIPBOARDLINE_DEV_REPOSITORY"] = configuration.repository
        values["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return values
    }
}
