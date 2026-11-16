import AppKit
import SwiftUI

// A file that has just arrived, said in the closed notch: a download that
// has finished, or a screenshot. The pill drops down under the cutout with
// the file's picture; a click shows it in Finder, and it can be dragged
// straight out — see `NotchPanelController.dragFile(with:)`.
//
// Found by watching the two folders themselves — Downloads, and wherever
// screenshots are saved — for a new name. No Spotlight, no polling: the
// kernel says when a folder's list changes, and nothing is read otherwise.
// Off until switched on in Settings: reading either folder is something
// macOS asks the user about first.

/// A file that has just arrived.
struct FileArrival: Equatable {
    enum Kind: Equatable, Sendable { case download, screenshot }

    var kind: Kind
    var url: URL
    /// Its size in bytes, when known.
    var bytes: Int64?
    /// A small picture of it, when it is one; otherwise its icon is shown.
    var picture: NSImage?

    var title: String {
        switch kind {
        case .download: L.t("Download finished", "Stažení dokončeno")
        case .screenshot: L.t("Screenshot", "Snímek obrazovky")
        }
    }

    /// "invoice.pdf · 2,4 MB" for a download; a screenshot's name is a date
    /// nobody reads, so it says where it went: "in Documents".
    var detail: String {
        let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
        return Self.detail(kind: kind, name: url.lastPathComponent, bytes: bytes, folder: folder)
    }

    nonisolated static func detail(kind: Kind, name: String, bytes: Int64?, folder: String) -> String {
        switch kind {
        case .download:
            guard let bytes, bytes > 0 else { return name }
            return "\(name) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        case .screenshot:
            return L.t("in \(folder)", "ve složce \(folder)")
        }
    }

    /// A name that is a download still on its way, or nothing to announce:
    /// the browsers' part-files, and anything hidden.
    nonisolated static func isTemporary(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["download", "crdownload", "part", "partial", "opdownload", "tmp", "icloud"].contains(ext)
    }

    /// The names in `now` that weren't there before and could be a finished
    /// file, oldest name first.
    nonisolated static func candidates(now: Set<String>, known: Set<String>) -> [String] {
        now.subtracting(known).filter { !isTemporary($0) }.sorted()
    }

    /// What a new file is, from what is known about it — nil when it is
    /// neither. A screenshot carries macOS's own mark. A download carries
    /// the browser's (where it came from, or the quarantine flag) and is
    /// new: a year-old download moved into the folder is not one finishing.
    nonisolated static func kind(watching: Set<Kind>, screenshotMark: Bool, downloadMark: Bool,
                                 age: TimeInterval) -> Kind? {
        guard age < 600 else { return nil }
        if watching.contains(.screenshot), screenshotMark { return .screenshot }
        if watching.contains(.download), downloadMark, !screenshotMark { return .download }
        return nil
    }

    /// `size` scaled to fit `box`, keeping its shape; never scaled up past it.
    nonisolated static func fitted(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    nonisolated static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tiff", "tif", "webp", "bmp"]
}

/// The file's picture under the notch: the image itself, small, or the
/// file's icon with a tick on it.
struct FilePicture: View {
    var file: FileArrival

    var body: some View {
        if let picture = file.picture {
            let size = FileArrival.fitted(picture.size, into: CGSize(width: 76, height: 46))
            Image(nsImage: picture)
                .resizable()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                }
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 42, height: 42)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85), ActivityLook.green)
                        .background(Circle().fill(NotchView.panelBlack).padding(-1))
                        .offset(x: 3, y: 2)
                }
        }
    }
}

/// The source of a file dragged out of the notch. A class of its own so the
/// panel can tell that drag from a file coming *in* — see `NotchPanel.draggingEntered`.
final class FileDragSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Watches Downloads and the screenshots' folder for new files.
@MainActor
final class FileWatcher {

    static let shared = FileWatcher()

    /// A download has finished, or a screenshot was saved.
    var onArrival: ((FileArrival) -> Void)?

    private var watches: [String: DirectoryWatch] = [:]

    /// Starts, stops or re-aims the watching, to match the settings. Called
    /// on every settings change; does nothing when nothing changed.
    func apply(downloads: Bool, screenshots: Bool) {
        var wanted: [String: Set<FileArrival.Kind>] = [:]
        if downloads, let folder = Self.downloadsFolder { wanted[folder.path, default: []].insert(.download) }
        if screenshots { wanted[Self.screenshotsFolder.path, default: []].insert(.screenshot) }

        for (path, watch) in watches where wanted[path] != watch.kinds {
            watch.stop()
            watches[path] = nil
        }
        for (path, kinds) in wanted where watches[path] == nil {
            let watch = DirectoryWatch(folder: URL(fileURLWithPath: path), kinds: kinds) { [weak self] arrival in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onArrival?(arrival) } }
            }
            watches[path] = watch
            watch.start()
        }
    }

    static var downloadsFolder: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Where screenshots go: what the user chose in the Screenshot app's
    /// options, or the Desktop.
    static var screenshotsFolder: URL {
        let chosen = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        if let chosen, !chosen.isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }
}

/// One folder, watched for new names. Everything here runs on its own
/// queue; the arrival is handed over from there.
final class DirectoryWatch: @unchecked Sendable {

    let kinds: Set<FileArrival.Kind>
    private let folder: URL
    private let onArrival: @Sendable (FileArrival) -> Void
    private let queue = DispatchQueue(label: "com.local.resonata.filewatch", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    /// The names already there, or already dealt with.
    private var known: Set<String> = []
    /// New names whose file is still growing, with its size at the last look.
    private var settling: [String: Int64] = [:]
    private var scanSoon: DispatchWorkItem?

    init(folder: URL, kinds: Set<FileArrival.Kind>, onArrival: @escaping @Sendable (FileArrival) -> Void) {
        self.folder = folder
        self.kinds = kinds
        self.onArrival = onArrival
    }

    func start() {
        queue.async { [self] in
            // The list first, the watching second. Reading the list is what
            // makes macOS ask whether Resonata may see this folder — and
            // this waits here, off the main thread, for the answer. Opening
            // it for events alone is refused without a word and without
            // the question: tried that way round, the installed app never
            // asked and never saw a file.
            guard let first = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
                NSLog("Resonata: not allowed to read %@", folder.path)
                return
            }
            known = Set(first)
            // Events only: the folder is never kept open for reading.
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else {
                NSLog("Resonata: can't watch %@", folder.path)
                return
            }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write,
                                                                   queue: queue)
            source.setEventHandler { [weak self] in self?.scan(after: 0.4) }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            scanSoon?.cancel()
            source?.cancel()
            source = nil
        }
    }

    private func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// A browser finishing a download renames, deletes and touches in a
    /// burst; one look after it has gone quiet sees the result.
    private func scan(after delay: TimeInterval) {
        scanSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        scanSoon = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scan() {
        let now = names()
        // Names that have gone can come again — the same file downloaded twice.
        known.formIntersection(now)
        settling = settling.filter { now.contains($0.key) }
        var arrived: FileArrival?
        var growing = false
        for name in FileArrival.candidates(now: now, known: known) {
            let url = folder.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey,
                                                           .contentModificationDateKey])
            let isFolder = values?.isDirectory == true
            let size = Int64(values?.fileSize ?? 0)
            if !isFolder {
                // Firefox puts the final name there first, empty, beside its
                // part-file. Not yet: the rename that finishes it changes
                // the folder again, and that look finds it whole.
                if size == 0 || FileManager.default.fileExists(atPath: url.path + ".part") {
                    settling[name] = nil
                    continue
                }
                // Anything else is looked at twice: still growing, it is
                // still being written.
                if settling[name] != size {
                    settling[name] = size
                    growing = true
                    continue
                }
            }
            settling[name] = nil
            known.insert(name)
            let newest = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max()
            let age = newest.map { Date().timeIntervalSince($0) } ?? 0
            guard let kind = FileArrival.kind(
                watching: kinds,
                screenshotMark: Self.has("com.apple.metadata:kMDItemIsScreenCapture", url),
                downloadMark: Self.has("com.apple.metadata:kMDItemWhereFroms", url)
                    || Self.has("com.apple.quarantine", url),
                age: age) else { continue }
            arrived = FileArrival(kind: kind, url: url, bytes: isFolder ? nil : size,
                                  picture: Self.picture(of: url))
        }
        // Several at once — an archive unpacked, a batch saved: one message,
        // for the last of them.
        if let arrived { onArrival(arrived) }
        if growing { scan(after: 0.8) }
    }

    private static func has(_ attribute: String, _ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, 0) >= 0
    }

    /// A picture of an image file, decoded small: a screenshot is several
    /// megabytes, and the notch shows it 76 points wide.
    private static func picture(of url: URL) -> NSImage? {
        guard FileArrival.pictureTypes.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
