import AppKit
import BMSlicerCore

/// One import entry point shared by the window background, scroll view and track.
final class DropImport: AudioDropHandling {
    unowned let editor: Editor
    let queue: OperationQueue = {
        let q = OperationQueue(); q.name = "BMSlicer.FilePromises"; q.maxConcurrentOperationCount = 1; return q
    }()
    var promises: [NSFilePromiseReceiver] = []
    var receiving = false
    var hover = false
    init(editor: Editor) { self.editor = editor }

    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard !editor.loading, !receiving, !(sender.draggingSource is Timeline) else { return [] }
        let files = AudioDrop.urls(from: sender.draggingPasteboard)
        let hasPromise = sender.draggingPasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        guard !files.isEmpty || hasPromise else { return [] }
        // Older DAWs sometimes offer generic instead of copy; never accept move.
        let mask = sender.draggingSourceOperationMask
        let operation: NSDragOperation = mask.contains(.copy) ? .copy : (mask.contains(.generic) ? .generic : [])
        guard !operation.isEmpty else { return [] }
        hover = true
        editor.timeline.dropHighlighted = true
        editor.timeline.needsDisplay = true
        editor.status.stringValue = hasPromise ? "놓으면 오디오를 받아 엽니다" : "놓으면 \(files[0].lastPathComponent)을 엽니다"
        return operation
    }
    func exited() {
        guard hover else { return }; hover = false
        editor.timeline.dropHighlighted = false; editor.timeline.needsDisplay = true
        editor.refresh()
    }
    func receive(_ sender: NSDraggingInfo) -> Bool {
        guard !operation(for: sender).isEmpty else { return false }
        exited()
        let board = sender.draggingPasteboard
        let files = AudioDrop.urls(from: board)
        let receivers = AudioDrop.promises(from: board)
        // Prefer a completed file. If only a promise exists, ask its owner to
        // render it and wait for the receiver's completion callback.
        if let url = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            DispatchQueue.main.async { self.editor.load(url) }
            return true
        }
        if !receivers.isEmpty {
            receivePromises(receivers)
            return true
        }
        if let url = files.first {
            DispatchQueue.main.async { self.editor.load(url) }
            return true
        }
        return false
    }
    func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BMSlicer-Import-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        catch { editor.alert(error); return }
        receiving = true; promises = receivers
        editor.refresh("원본 앱에서 오디오 파일을 받는 중…")
        let group = DispatchGroup()
        let lock = NSLock()
        var candidates: [URL] = []
        var failures: [Error] = []
        var answered = Set<Int>()
        // Each receiver may supply several files (legacy file-promise format).
        // The operation queue drains after all coordinated reader callbacks.
        for (index, receiver) in receivers.enumerated() {
            group.enter()
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                lock.lock(); defer { lock.unlock() }
                if let error = error { failures.append(error) }
                else if AudioDrop.supported(url) { candidates.append(url) }
                if answered.insert(index).inserted { group.leave() }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            self.queue.waitUntilAllOperationsAreFinished()
            lock.lock(); let urls = candidates; let error = failures.first; lock.unlock()
            DispatchQueue.main.async {
                self.receiving = false; self.promises = []
                if let url = urls.first {
                    self.editor.load(url, removingAfterRead: directory)
                } else {
                    try? FileManager.default.removeItem(at: directory)
                    self.editor.alert(error ?? SliceError.message("전달된 파일에 WAV·OGG·MP3가 없습니다. Ableton의 오디오 클립을 드래그해 주세요."))
                    self.editor.refresh("오디오 가져오기를 완료하지 못했습니다")
                }
            }
        }
    }
}
