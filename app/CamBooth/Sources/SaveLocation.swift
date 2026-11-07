import AppKit
import Foundation

/// Where captures are written. Default is the user's Downloads folder; any other folder can be
/// picked in 高级设置. The app no longer creates its own "Cam Booth" subfolders — files ended up
/// where nobody looked for them.
enum SaveLocation {
    private static let defaultsKey = "saveDirectory"

    /// User-chosen folder. A stored path that no longer exists (unmounted volume, deleted folder)
    /// reads as nil, so captures still land in Downloads instead of failing.
    static var custom: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return url
        }
        set {
            if let url = newValue {
                UserDefaults.standard.set(url.path, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    static var current: URL { custom ?? downloads }

    static var isCustom: Bool { custom != nil }

    static func resetToDownloads() { custom = nil }

    /// Standard folder chooser. Cancelling leaves the setting as it was.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "存到此处"
        panel.message = "拍摄的照片和视频会直接保存到这个文件夹。"
        panel.directoryURL = current
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        custom = url
        return url
    }

    /// Same-second captures would otherwise overwrite each other and confuse the 影像栏.
    /// `reserved` carries names already handed out whose file has not been written yet.
    static func uniqueURL(filename: String, reserved: Set<String> = []) -> URL {
        uniqueURL(filename: filename, in: current, reserved: reserved)
    }

    static func uniqueURL(filename: String, in directory: URL, reserved: Set<String> = []) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.lastPathComponent) {
            candidate = directory.appendingPathComponent("\(base) \(attempt).\(ext)")
            attempt += 1
        }
        return candidate
    }

    private static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }
}
