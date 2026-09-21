import AppKit
import BMSlicerCore

final class DragInfoFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey : Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

final class DropHandlerFixture: AudioDropHandling {
    var received: [URL] = []
    func operation(for sender: NSDraggingInfo) -> NSDragOperation { AudioDrop.urls(from: sender.draggingPasteboard).isEmpty ? [] : .copy }
    func receive(_ sender: NSDraggingInfo) -> Bool { received = AudioDrop.urls(from: sender.draggingPasteboard); return !received.isEmpty }
    func exited() {}
}

func testFileDrops() {
    _ = NSApplication.shared
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let expected = URL(fileURLWithPath: "/tmp/한글 sample #1.WAV")
    board.writeObjects([expected as NSURL])
    expectEqual(AudioDrop.urls(from: board), [expected])
    let source = DragInfoFixture(board)
    let plain = NSView()
    print("Baseline NSView prepare=\(plain.prepareForDragOperation(source))")
    let handler = DropHandlerFixture()
    let track = AudioDropView(frame: .zero); track.dropHandler = handler
    let scroll = AudioDropScrollView(frame: .zero); scroll.dropHandler = handler
    for view: NSView in [track, scroll] {
        expectEqual(view.draggingEntered(source), .copy)
        expectEqual(view.draggingUpdated(source), .copy)
        expectEqual(view.prepareForDragOperation(source), true)
        expectEqual(view.performDragOperation(source), true)
        expectEqual(handler.received, [expected])
    }
    board.clearContents(); board.setPropertyList([expected.path], forType: AudioDrop.legacyFilenames)
    expectEqual(AudioDrop.urls(from: board), [expected])
    board.clearContents(); board.setString(expected.absoluteString, forType: .fileURL)
    expectEqual(AudioDrop.urls(from: board), [expected])
    board.clearContents(); board.writeObjects([URL(string:"https://example.com/audio.wav")! as NSURL])
    expectEqual(AudioDrop.urls(from: board), [])
    expectEqual(track.draggingEntered(source), [])
    expectEqual(track.prepareForDragOperation(source), false)
    board.clearContents(); board.writeObjects([URL(fileURLWithPath:"/tmp/wrong.txt") as NSURL])
    expectEqual(AudioDrop.urls(from: board), [])
    print("PASS: Finder URLs, legacy DAW paths, Unicode, drop enter/update/prepare/receive")
}

final class PromiseFixture: NSObject, NSFilePromiseProviderDelegate {
    let data: Data
    init(data: Data) { self.data = data }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "한글 promised audio.wav" }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
    }
}

func testPromiseNegotiation() throws {
    let audio = try AudioData(samples: [[0, 0.2, -0.2, 0]], sampleRate: 44100, source: URL(fileURLWithPath:"/tmp/source.wav"))
    let fixture = PromiseFixture(data: try audio.wav(range: 0..<4))
    let provider = NSFilePromiseProvider(fileType: "com.microsoft.waveform-audio", delegate: fixture)
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    expectEqual(board.writeObjects([provider]), true)
    let receivers = AudioDrop.promises(from: board)
    expectEqual(receivers.count, 1)
    expectEqual(receivers[0].fileTypes, ["com.microsoft.waveform-audio"])
    // Promise delivery itself needs an OS drag session; a private pasteboard can
    // verify negotiation but does not stand in for an actual cross-app drag.
    withExtendedLifetime(fixture) {}
}
