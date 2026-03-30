import Foundation

public class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let fileURL: URL
    private let onChange: () -> Void

    public init(url: URL, onChange: @escaping () -> Void) {
        self.fileURL = url
        self.onChange = onChange
        startWatching()
    }

    private func startWatching() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
