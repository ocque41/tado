import Foundation

/// Debounced file-system-object watcher. Wraps
/// `DispatchSource.makeFileSystemObjectSource` with:
///   - Re-open on rename/delete (atomic writes replace the inode,
///     so the original fd becomes stale after one write).
///   - 200ms debounce so a burst of events collapses to one handler
///     call (typical for editors that write-temp-rename).
///   - Hands back an opaque `Watcher` whose `cancel()` stops the
///     underlying DispatchSource and closes the fd.
final class FileWatcher {
    private let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private let debounce: TimeInterval

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var reopenWorkItem: DispatchWorkItem?
    private var isCancelled = false

    init(url: URL,
         debounce: TimeInterval = 0.2,
         queue: DispatchQueue = .main,
         onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.queue = queue
        self.onChange = onChange
        open()
    }

    func cancel() {
        isCancelled = true
        debounceWorkItem?.cancel()
        reopenWorkItem?.cancel()
        source?.cancel()
        source = nil
    }

    deinit { cancel() }

    private func open() {
        guard !isCancelled else { return }
        // Create parent + empty file if the target doesn't exist yet,
        // so DispatchSource has something to attach to. Harmless if
        // the path is a dir (we then watch the dir).
        if !FileManager.default.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let newFD = Darwin.open(url.path, O_EVTONLY)
        guard newFD >= 0 else {
            scheduleReopen()
            return
        }
        fd = newFD
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: newFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.delete) || event.contains(.rename) {
                // Atomic-write consumers replace the inode — reattach.
                self.reopen()
            }
            self.scheduleFire()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func reopen() {
        source?.cancel()
        source = nil
        // Let the rename settle, then reattach.
        reopenWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.open() }
        reopenWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func scheduleReopen() {
        guard !isCancelled else { return }
        reopenWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.open() }
        reopenWorkItem = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scheduleFire() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.onChange()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
