import AppKit

/// Finder uses file URLs; older audio applications can still use filename lists.
/// File promises are advertised before the source application has rendered a file.
public enum AudioDrop {
    public static let legacyFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    public static let types: [NSPasteboard.PasteboardType] = Array(Set(
        [.fileURL, .URL, legacyFilenames] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    ))
    public static func supported(_ url: URL) -> Bool {
        url.isFileURL && ["wav", "ogg", "mp3"].contains(url.pathExtension.lowercased())
    }
    public static func urls(from pasteboard: NSPasteboard) -> [URL] {
        var candidates = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? []).map { $0 as URL }
        if let paths = pasteboard.propertyList(forType: legacyFilenames) as? [String] {
            candidates += paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        // Some non-Cocoa senders declare the URL type but supply a raw string.
        for item in pasteboard.pasteboardItems ?? [] {
            for type in [NSPasteboard.PasteboardType.fileURL, .URL] {
                if let value = item.string(forType: type), let url = URL(string: value), url.isFileURL { candidates.append(url) }
            }
        }
        var seen = Set<URL>()
        return candidates.map { $0.standardizedFileURL }.filter { supported($0) && seen.insert($0).inserted }
    }
    public static func promises(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }
}

/// AppKit implements default destination callbacks on NSView. Override the whole
/// acceptance lifecycle, otherwise a later callback can negate draggingEntered.
public protocol AudioDropHandling: AnyObject {
    func operation(for sender: NSDraggingInfo) -> NSDragOperation
    func receive(_ sender: NSDraggingInfo) -> Bool
    func exited()
}

open class AudioDropView: NSView {
    public weak var dropHandler: AudioDropHandling?
    public override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes(AudioDrop.types) }
    public required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes(AudioDrop.types) }
    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler?.operation(for: sender) ?? [] }
    open override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler?.operation(for: sender) ?? [] }
    open override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !(dropHandler?.operation(for: sender).isEmpty ?? true) }
    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropHandler?.receive(sender) ?? false }
    open override func draggingExited(_ sender: NSDraggingInfo?) { dropHandler?.exited() }
}

public final class AudioDropScrollView: NSScrollView {
    public weak var dropHandler: AudioDropHandling?
    public override init(frame frameRect: NSRect) { super.init(frame: frameRect); registerForDraggedTypes(AudioDrop.types) }
    public required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes(AudioDrop.types) }
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler?.operation(for: sender) ?? [] }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dropHandler?.operation(for: sender) ?? [] }
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !(dropHandler?.operation(for: sender).isEmpty ?? true) }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { dropHandler?.receive(sender) ?? false }
    public override func draggingExited(_ sender: NSDraggingInfo?) { dropHandler?.exited() }
}
