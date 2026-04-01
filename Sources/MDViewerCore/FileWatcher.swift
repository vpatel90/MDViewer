import Foundation

/// Watches a file for changes by polling its modification date.
/// Works reliably with all save mechanisms including atomic writes.
public class FileWatcher {
    private var timer: DispatchSourceTimer?
    private let fileURL: URL
    private let onChange: () -> Void
    private var lastModDate: Date?

    public init(url: URL, onChange: @escaping () -> Void) {
        self.fileURL = url
        self.onChange = onChange
        self.lastModDate = modificationDate()
        startPolling()
    }

    private func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let newDate = self.modificationDate() else { return }
            if self.lastModDate != newDate {
                self.lastModDate = newDate
                self.onChange()
            }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }
}
