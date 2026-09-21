import AppKit
import AVFoundation
import UniformTypeIdentifiers
import BMSlicerCore

let bg = NSColor(calibratedWhite: 0.115, alpha: 1)
let trackBackground = NSColor(calibratedWhite: 0.16, alpha: 1)
let ink = NSColor(calibratedWhite: 0.84, alpha: 1)
let accent = NSColor(calibratedRed: 0.99, green: 0.65, blue: 0.24, alpha: 1)

final class Editor: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var timeline: Timeline!
    let scroll = AudioDropScrollView()
    lazy var dropImport = DropImport(editor: self)
    var audio: AudioData?
    var state = EditState()
    var undoStack: [EditState] = [], redoStack: [EditState] = []
    var bpm: Double = 120
    var pps: Double = 160
    var fixedDenominator = 16
    var adaptive = true
    var triplet = false
    var snapping = true
    var loading = false
    var startNumber: Int?
    var loadedName = ""
    let bpmField = NSTextField(string: "120")
    let nameField = NSTextField(string: "sample_\\n")
    let gridMenu = NSPopUpButton()
    let bitMenu = NSPopUpButton()
    let digitsMenu = NSPopUpButton()
    let autoButton = NSButton(checkboxWithTitle: "자동 그리드", target: nil, action: nil)
    let tripButton = NSButton(checkboxWithTitle: "Triplet", target: nil, action: nil)
    let snapButton = NSButton(checkboxWithTitle: "Snap", target: nil, action: nil)
    let status = NSTextField(labelWithString: "WAV · OGG · MP3 파일을 끌어 놓으세요")
    let fileLabel = NSTextField(labelWithString: "NO AUDIO")
    let selectionLabel = NSTextField(labelWithString: "0 CLIPS")
    let previewLabel = NSTextField(labelWithString: "예: sample_1.wav, sample_2.wav …")
    let playButton = NSButton(title: "▶ 재생", target: nil, action: nil)
    var player: AVAudioPlayer?
    var playbackRange: Range<Int>?
    var playbackTimer: Timer?
    var playhead: Int?
    var pendingURL: URL?
    var grid: Grid { adaptive ? Grid.adaptive(pixelsPerSecond: pps, bpm: bpm, triplet: triplet) : Grid(fixedDenominator, triplet: triplet) }
    var segments: [Range<Int>] { state.segments(total: audio?.frames ?? 0) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let saved = UserDefaults.standard.double(forKey: "bpm")
        if saved.isFinite && saved >= 1 && saved <= 999 { bpm = saved }
        bpmField.stringValue = formatBPM(bpm)
        nameField.stringValue = UserDefaults.standard.string(forKey: "nameTemplate") ?? "sample_\\n"
        cleanOldDragFiles(); buildMenu(); buildWindow(); refresh()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let url = pendingURL { load(url) }
        else if let pathIndex = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > pathIndex+1 { load(URL(fileURLWithPath: CommandLine.arguments[pathIndex+1])) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let name = filenames.first { let url = URL(fileURLWithPath: name); if window == nil { pendingURL = url } else { load(url) } }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func formatBPM(_ value: Double) -> String { String(format: "%.3f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) }
    func label(_ text: String, small: Bool = false) -> NSTextField {
        let v = NSTextField(labelWithString: text); v.textColor = small ? .secondaryLabelColor : ink; v.font = .systemFont(ofSize: small ? 11 : 12, weight: .medium); return v
    }
    func button(_ text: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: text, target: self, action: action); b.bezelStyle = .rounded; return b
    }
    func stack(_ items: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: items); s.orientation = .horizontal; s.alignment = .centerY; s.spacing = spacing; return s
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 80, y: 140, width: 1200, height: 660), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "BMSlicer"; window.minSize = NSSize(width: 1000, height: 520); window.delegate = self; window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = bg
        let content = AudioDropView(frame: window.contentView!.bounds)
        content.dropHandler = dropImport
        window.contentView = content
        scroll.dropHandler = dropImport
        let title = label("BMSLICER"); title.font = .systemFont(ofSize: 20, weight: .heavy); title.textColor = accent
        fileLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); fileLabel.textColor = .secondaryLabelColor; fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 450).isActive = true
        let header = stack([title, label("/  AUDIO → KEYSOUNDS", small: true), fileLabel])
        bpmField.widthAnchor.constraint(equalToConstant: 72).isActive = true; bpmField.delegate = self; bpmField.alignment = .center; bpmField.target = self; bpmField.action = #selector(commitBPM)
        gridMenu.addItems(withTitles: ["1/2","1/4","1/8","1/16","1/32"]); gridMenu.selectItem(at: 3); gridMenu.target = self; gridMenu.action = #selector(changeGrid)
        autoButton.state = .on; autoButton.target = self; autoButton.action = #selector(changeAuto)
        tripButton.target = self; tripButton.action = #selector(changeTriplet)
        snapButton.state = .on; snapButton.target = self; snapButton.action = #selector(changeSnap)
        playButton.target = self; playButton.action = #selector(togglePlay)
        let controls = stack([button("파일 열기…", #selector(openFile)), label("BPM"), bpmField, playButton, label("│"), gridMenu, tripButton, autoButton, snapButton, button("그리드 일괄 자르기", #selector(splitGrid)), button("전체 보기", #selector(fit))], spacing: 9)
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false; scroll.autohidesScrollers = false; scroll.borderType = .noBorder; scroll.drawsBackground = true; scroll.backgroundColor = bg
        timeline = Timeline(editor: self); timeline.frame = NSRect(x: 0, y: 0, width: 1100, height: 310); scroll.documentView = timeline
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.timeline.needsDisplay = true }
        nameField.widthAnchor.constraint(equalToConstant: 210).isActive = true; nameField.delegate = self; nameField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        bitMenu.addItems(withTitles: ["24-bit WAV", "16-bit WAV"])
        digitsMenu.addItems(withTitles: ["번호 1", "번호 01", "번호 001", "번호 0001"]); digitsMenu.target = self; digitsMenu.action = #selector(updatePreview)
        let renameButton = button("제목 바꾸기", #selector(renameClips))
        renameButton.toolTip = "선택한 클립의 제목만 변경합니다. 선택이 없으면 전체에 적용합니다."
        let naming = stack([label("파일 이름"), nameField, renameButton, button("시작 번호…", #selector(chooseStart)), digitsMenu, bitMenu, button("선택 내보내기…", #selector(exportSelected)), button("전체 내보내기…", #selector(exportAll))])
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); previewLabel.textColor = accent
        let editing = stack([selectionLabel, button("자르기  ⌘E", #selector(split)), button("합치기  ⌘J", #selector(join)), button("삭제  ⌫", #selector(deleteClips)), button("전체 선택  ⌘A", #selector(selectAllClips)), button("실행 취소", #selector(undoEdit))])
        let help = label("파형 드래그: 시간 선택    ·    제목 띠 드래그: WAV 파일 전달    ·    Shift/⌘ 클릭: 여러 클립 선택    ·    ⌘ 스크롤: 확대/축소    ·    Space: 재생", small: true)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        let column = NSStackView(views: [header, controls, scroll, editing, naming, previewLabel, help, status]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 15; column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22), column.topAnchor.constraint(equalTo: content.topAnchor, constant: 22), column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18), scroll.widthAnchor.constraint(equalTo: column.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220), status.widthAnchor.constraint(equalTo: column.widthAnchor)])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    func buildMenu() {
        let menu = NSMenu()
        func submenu(_ title: String, _ entries: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let sub = NSMenu(title: title)
            for e in entries { let i = NSMenuItem(title: e.0, action: e.1, keyEquivalent: e.2); i.keyEquivalentModifierMask = e.3; i.target = self
                if e.2 == "c" { i.action = #selector(NSText.copy(_:)); i.target = nil }
                if e.2 == "v" { i.action = #selector(NSText.paste(_:)); i.target = nil }
                if e.2 == "x" { i.action = #selector(NSText.cut(_:)); i.target = nil }
                if e.2 == "a" { i.action = #selector(NSText.selectAll(_:)); i.target = nil }
                sub.addItem(i) }; holder.submenu = sub; menu.addItem(holder)
        }
        submenu("BMSlicer", [("BMSlicer 종료", #selector(quit), "q", .command)])
        submenu("파일", [("오디오 열기…", #selector(openFile), "o", .command), ("선택 내보내기…", #selector(exportSelected), "e", [.command,.shift]), ("전체 내보내기…", #selector(exportAll), "e", [.command,.option])])
        submenu("편집", [("실행 취소", #selector(undoEdit), "z", .command), ("다시 실행", #selector(redoEdit), "z", [.command,.shift]), ("자르기", #selector(split), "e", .command), ("합치기", #selector(join), "j", .command), ("전체 선택", #selector(selectAllClips), "a", .command), ("복사", #selector(copyText), "c", .command), ("붙여넣기", #selector(pasteText), "v", .command), ("잘라내기", #selector(cutText), "x", .command)])
        submenu("보기", [("그리드 좁히기", #selector(narrowGrid), "1", .command), ("그리드 넓히기", #selector(widenGrid), "2", .command), ("Triplet 전환", #selector(toggleTriplet), "3", .command), ("Snap 전환", #selector(toggleSnap), "4", .command), ("자동 그리드 전환", #selector(toggleAuto), "5", .command), ("전체 보기", #selector(fit), "0", .command)])
        if let editMenu = menu.items.first(where: { $0.title == "편집" })?.submenu {
            let deletion = NSMenuItem(title: "삭제", action: #selector(NSResponder.deleteBackward(_:)), keyEquivalent: "\u{8}")
            deletion.keyEquivalentModifierMask = []; deletion.target = nil; editMenu.addItem(deletion)
        }
        NSApp.mainMenu = menu
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func copyText() { (NSApp.keyWindow?.firstResponder as? NSTextView)?.copy(nil) }
    @objc func pasteText() { (NSApp.keyWindow?.firstResponder as? NSTextView)?.paste(nil) }
    @objc func cutText() { (NSApp.keyWindow?.firstResponder as? NSTextView)?.cut(nil) }
    func windowDidResize(_ notification: Notification) { resizeTimeline() }
    func resizeTimeline() { timeline.frame.size = NSSize(width: max(scroll.contentSize.width, (audio?.duration ?? 0) * pps + 60), height: max(220,scroll.contentSize.height)); timeline.needsDisplay = true }
    func refresh(_ message: String? = nil) {
        guard window != nil else { return }
        selectionLabel.stringValue = "\(segments.count) CLIPS  /  \(state.selected.count) 선택"
        selectionLabel.textColor = accent; selectionLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        autoButton.state = adaptive ? .on : .off; tripButton.state = triplet ? .on : .off; snapButton.state = snapping ? .on : .off
        gridMenu.selectItem(withTitle: "1/\(grid.denominator)")
        if let message = message { status.stringValue = message }
        else if let a = audio { status.stringValue = String(format:"%.3f s  ·  %.0f Hz  ·  %d ch  ·  GRID 1/%d%@  ·  %@", a.duration,a.sampleRate,a.channels,grid.denominator,triplet ? "T" : "",adaptive ? "AUTO" : "FIXED") }
        updatePreview(); resizeTimeline()
    }
    func alert(_ error: Error) { let a = NSAlert(); a.messageText = "작업을 완료하지 못했습니다"; a.informativeText = error.localizedDescription; a.runModal() }
    func saveUndo() { undoStack.append(state); if undoStack.count > 150 { undoStack.removeFirst() }; redoStack.removeAll() }
    func editableFocus() -> Bool { NSApp.keyWindow?.firstResponder is NSTextView }
    @objc func undoEdit() { if editableFocus() { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.undo(); return }; guard let old = undoStack.popLast() else { return }; redoStack.append(state); state = old; refresh() }
    @objc func redoEdit() { if editableFocus() { (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.redo(); return }; guard let old = redoStack.popLast() else { return }; undoStack.append(state); state = old; refresh() }
    @objc func openFile() {
        let p = NSOpenPanel(); p.allowedContentTypes = ["wav","ogg","mp3"].compactMap { UTType(filenameExtension: $0) }; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { load(url) }
    }
    func load(_ url: URL, removingAfterRead cleanup: URL? = nil) {
        func discardTemporaryImport() { if let cleanup = cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        guard !loading else { discardTemporaryImport(); return }
        guard ["wav","ogg","mp3"].contains(url.pathExtension.lowercased()) else { discardTemporaryImport(); alert(SliceError.message("WAV, OGG Vorbis, MP3 파일을 선택해 주세요.")); return }
        if !state.cuts.isEmpty || !state.deleted.isEmpty {
            let a = NSAlert(); a.messageText = "다른 오디오를 열까요?"; a.informativeText = "현재 분할 편집은 초기화됩니다. 필요한 WAV를 먼저 내보내세요."; a.addButton(withTitle: "열기"); a.addButton(withTitle: "취소"); if a.runModal() != .alertFirstButtonReturn { discardTemporaryImport(); return }
        }
        stop(); loading = true; refresh("오디오 읽는 중… \(url.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AudioData.load(url) }
            if let cleanup = cleanup { try? FileManager.default.removeItem(at: cleanup) }
            DispatchQueue.main.async { self.loading = false
                switch result {
                case .success(let data):
                    self.audio = data; self.state = EditState(); self.undoStack = []; self.redoStack = []; self.startNumber = nil
                    self.fileLabel.stringValue = url.lastPathComponent; self.loadedName = url.lastPathComponent; self.window.title = "\(url.lastPathComponent) — BMSlicer"; self.fit(); self.window.makeFirstResponder(self.timeline)
                case .failure(let error): self.alert(error); self.refresh("파일을 열지 못했습니다")
                }
            }
        }
    }
    @objc func commitBPM() {
        guard let n = Double(bpmField.stringValue.replacingOccurrences(of: ",", with: ".")), n.isFinite, n >= 1, n <= 999 else { bpmField.stringValue = formatBPM(bpm); NSSound.beep(); return }
        bpm = n; UserDefaults.standard.set(n, forKey: "bpm"); bpmField.stringValue = formatBPM(n); refresh()
    }
    func controlTextDidEndEditing(_ obj: Notification) { if obj.object as? NSTextField === bpmField { commitBPM() }; if obj.object as? NSTextField === nameField { UserDefaults.standard.set(nameField.stringValue, forKey: "nameTemplate"); updatePreview() } }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSTextField === nameField { startNumber = nil; updatePreview() } }
    @objc func changeGrid() { fixedDenominator = [2,4,8,16,32][max(0,gridMenu.indexOfSelectedItem)]; adaptive = false; refresh(); window.makeFirstResponder(timeline) }
    @objc func changeAuto() { adaptive = autoButton.state == .on; refresh() }
    @objc func changeTriplet() { triplet = tripButton.state == .on; refresh() }
    @objc func changeSnap() { snapping = snapButton.state == .on; refresh() }
    @objc func toggleAuto() { adaptive.toggle(); refresh() }
    @objc func toggleTriplet() { triplet.toggle(); refresh() }
    @objc func toggleSnap() { snapping.toggle(); refresh() }
    @objc func narrowGrid() { fixedDenominator = min(32, grid.denominator * 2); adaptive = false; refresh() }
    @objc func widenGrid() { fixedDenominator = max(2, grid.denominator / 2); adaptive = false; refresh() }
    @objc func fit() { if let a = audio { pps = max(0.05, (scroll.contentSize.width-60) / a.duration) }; resizeTimeline(); scroll.contentView.scroll(to: .zero); refresh() }
    func snap(_ frame: Int) -> Int { guard let a = audio else { return 0 }; return snapping ? grid.snap(frame, sampleRate: a.sampleRate, bpm: bpm, total: a.frames) : min(a.frames,max(0,frame)) }
    @objc func split() { guard let a = audio, !loading else { return }; commitBPM(); let cuts = state.range.map { [$0.lowerBound,$0.upperBound] } ?? [state.cursor]; if cuts.allSatisfy({ $0 <= 0 || $0 >= a.frames || state.cuts.contains($0) }) { return }; saveUndo(); state.split(at: cuts,total:a.frames); refresh() }
    @objc func deleteClips() {
        guard let audio = audio, !loading else { return }
        var next = state
        guard next.deleteSelection(total: audio.frames) else { return }
        stop(); saveUndo(); state = next
        window.makeFirstResponder(timeline)
        refresh("선택한 오디오 삭제 · ⌘Z로 되돌리기")
    }
    @objc func join() { guard let a = audio, !loading else { return }; var next = state; next.join(total: a.frames); if next.cuts != state.cuts { saveUndo(); state = next; refresh() } }
    @objc func splitGrid() {
        guard let a = audio, !loading else { return }; commitBPM()
        let limits: [Range<Int>] = state.range.map { r in segments.filter { $0.overlaps(r) }.map { max($0.lowerBound, r.lowerBound)..<min($0.upperBound, r.upperBound) } } ?? (state.selected.isEmpty ? segments : state.selected.sorted().compactMap { segments.indices.contains($0) ? segments[$0] : nil })
        let points = grid.boundaries(sampleRate:a.sampleRate,bpm:bpm,total:a.frames).filter { f in limits.contains { f > $0.lowerBound && f < $0.upperBound } }
        if points.count > 10000 { alert(SliceError.message("한 번에 10,000개까지 자를 수 있습니다. 구간을 선택하거나 그리드를 넓혀 주세요.")); return }
        guard !points.isEmpty else { return }; saveUndo(); state.split(at: points,total:a.frames); refresh()
    }
    @objc func selectAllClips() { if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.selectAll(nil); return }; state.selected = Set(segments.indices); state.range = nil; refresh() }
    @objc func updatePreview() {
        let names = try? Naming.names(template: nameField.stringValue, count: max(1,min(2,segments.count)), start: startNumber ?? 1, digits: digitsMenu.indexOfSelectedItem+1)
        previewLabel.stringValue = names.map { "예: " + $0.joined(separator: "  ·  ") + (startNumber == nil ? "  /  \\n 시작 번호는 내보내기·드래그할 때 입력" : "") } ?? "파일 이름을 확인해 주세요"
    }
    @objc func renameClips() {
        window.makeFirstResponder(timeline)
        guard let audio = audio, !loading else { return }
        guard requestStart(force: nameField.stringValue.contains("\\n")) else { return }
        do {
            var next = state
            try next.rename(total: audio.frames, template: nameField.stringValue, start: startNumber ?? 1, digits: digitsMenu.indexOfSelectedItem + 1)
            guard next != state else { return }
            saveUndo(); state = next
            refresh("\(state.selected.isEmpty ? segments.count : state.selected.count)개 클립 제목 변경 완료")
        } catch { alert(error) }
    }
    func needsOutputNumber(_ ranges: [Range<Int>]) -> Bool {
        ranges.contains { state.titles[$0.lowerBound] == nil }
    }
    @objc func chooseStart() { _ = requestStart(force: true) }
    func requestStart(force: Bool = false) -> Bool {
        if !force && (!nameField.stringValue.contains("\\n") || startNumber != nil) { return true }
        let a = NSAlert(); a.messageText = "n의 시작값"; a.informativeText = "선택한 키음의 시간 순서대로 번호를 붙입니다.\n\(nameField.stringValue)"; a.addButton(withTitle: "적용"); a.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x:0,y:0,width:230,height:26)); field.stringValue = String(startNumber ?? 1); a.accessoryView = field; a.window.initialFirstResponder = field
        if a.runModal() != .alertFirstButtonReturn { return false }
        guard let n = Int(field.stringValue), n >= 0, n <= Int.max - max(1,segments.count) else { alert(SliceError.message("시작 번호에는 0 이상의 정수를 입력해 주세요.")); return false }
        startNumber = n; updatePreview(); return true
    }
    func outputSelection(all: Bool) -> [Range<Int>] { all ? segments : state.selected.sorted().compactMap { segments.indices.contains($0) ? segments[$0] : nil } }
    func outputNames(_ ranges: [Range<Int>]) throws -> [String] { try state.outputNames(ranges: ranges, template: nameField.stringValue, start: startNumber ?? 1, digits: digitsMenu.indexOfSelectedItem+1) }
    @objc func exportSelected() { export(all: false) }
    @objc func exportAll() { export(all: true) }
    func export(all: Bool) {
        window.makeFirstResponder(timeline)
        guard let a = audio, !loading else { return }; let ranges = outputSelection(all: all)
        guard !ranges.isEmpty else { alert(SliceError.message("내보낼 클립을 먼저 선택해 주세요. 제목 띠를 클릭하거나 ⌘A로 전체 선택할 수 있습니다.")); return }
        guard !needsOutputNumber(ranges) || requestStart() else { return }
        do {
            let names = try outputNames(ranges)
            let p = NSOpenPanel(); p.canChooseFiles = false; p.canChooseDirectories = true; p.canCreateDirectories = true; p.prompt = "\(ranges.count)개 WAV 저장"; p.message = "\(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? " …" : "")"
            guard p.runModal() == .OK, let directory = p.url else { return }
            loading = true; refresh("\(ranges.count)개 WAV 내보내는 중…")
            let bits = bitMenu.indexOfSelectedItem == 0 ? 24 : 16
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try a.export(ranges: ranges,names:names,directory:directory,bits:bits) }
                DispatchQueue.main.async { self.loading = false; switch result {
                    case .success(let urls): self.refresh("\(urls.count)개 WAV 저장 완료 · \(directory.path)"); NSWorkspace.shared.activateFileViewerSelecting(urls)
                    case .failure(let error): self.alert(error); self.refresh("내보내기 실패")
                } }
            }
        } catch { alert(error) }
    }
    func cleanOldDragFiles() {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BMSlicer/DragExports")
        guard let folders = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            if let date = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate, date.timeIntervalSinceNow < -86400 { try? fm.removeItem(at: folder) }
        }
    }
    func dragFiles() -> [URL]? {
        guard let a = audio, !loading else { return nil }; let ranges = outputSelection(all:false); guard !ranges.isEmpty, !needsOutputNumber(ranges) || requestStart() else { return nil }
        do {
            let names = try outputNames(ranges)
            let base = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask)[0].appendingPathComponent("BMSlicer/DragExports")
            let directory = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let urls = try a.export(ranges:ranges,names:names,directory:directory,bits:bitMenu.indexOfSelectedItem == 0 ? 24 : 16)
            refresh("\(urls.count)개 WAV 준비됨 · uBMSC의 #WAV 목록 또는 Finder로 놓으세요")
            return urls
        } catch { alert(error); return nil }
    }
    func stop() { player?.stop(); player = nil; playhead = nil; playbackTimer?.invalidate(); playbackTimer = nil; playButton.title = "▶ 재생"; timeline?.needsDisplay = true }
    @objc func togglePlay() {
        if player?.isPlaying == true { stop(); return }
        guard let a = audio, !loading else { return }
        var range = state.range ?? (min(state.cursor,a.frames-1)..<a.frames)
        if state.range == nil, !state.selected.isEmpty { let chosen = outputSelection(all:false); if let first = chosen.first, let last = chosen.last { range = first.lowerBound..<last.upperBound } }
        do {
            player = try AVAudioPlayer(data:a.wav(range:range,bits:16,silencing:state.deleted),fileTypeHint:AVFileType.wav.rawValue); playbackRange = range
            guard player!.play() else { throw SliceError.message("오디오 장치에서 재생을 시작하지 못했습니다.") }; playButton.title = "■ 정지"
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 1/30, repeats:true) { [weak self] _ in
                guard let self = self, let player = self.player else { return }; if !player.isPlaying { self.stop(); return }; self.playhead = range.lowerBound + Int(player.currentTime*a.sampleRate); self.timeline.needsDisplay = true
            }
        } catch { alert(error); stop() }
    }
}

final class Timeline: AudioDropView, NSDraggingSource {
    unowned let editor: Editor
    var downPoint = NSPoint.zero
    var downFrame = 0
    var titleDrag = false
    var hasDragged = false
    var clickedIndex: Int?
    var previousSelection: Set<Int> = []
    var downModifiers: NSEvent.ModifierFlags = []
    var dropHighlighted = false
    var dragDirectory: URL?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(editor: Editor) { self.editor = editor; super.init(frame:.zero); dropHandler = editor.dropImport; setAccessibilityLabel("오디오 파형 편집기") }
    required init?(coder: NSCoder) { fatalError() }
    func x(_ frame: Int) -> CGFloat { guard let a = editor.audio else { return 0 }; return Double(frame) / a.sampleRate * editor.pps }
    func frameAt(_ x: CGFloat) -> Int { guard let a = editor.audio else { return 0 }; return min(a.frames,max(0,Int(x/editor.pps*a.sampleRate))) }
    func text(_ s: String, at p: NSPoint, color: NSColor = ink, size: CGFloat = 10, bold: Bool = false) {
        s.draw(at:p,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:bold ? .bold : .regular),.foregroundColor:color])
    }
    override func draw(_ dirtyRect: NSRect) {
        bg.setFill(); dirtyRect.fill()
        let visible = visibleRect
        if dropHighlighted {
            accent.setStroke(); let border = NSBezierPath(roundedRect: visible.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8); border.lineWidth = 3; border.stroke()
        }
        guard let a = editor.audio else {
            text("DROP AUDIO HERE",at:NSPoint(x:visible.minX+40,y:70),color:accent,size:26,bold:true)
            text("WAV / OGG / MP3",at:NSPoint(x:visible.minX+42,y:115),size:13)
            text("BPM 설정 → 그리드 편집 → WAV 내보내기 또는 드래그",at:NSPoint(x:visible.minX+42,y:148),size:12)
            return
        }
        let trackTop: CGFloat = 38, header: CGFloat = 25, bottom = bounds.height-30
        let regions = editor.segments
        for (i,r) in regions.enumerated() {
            let left = x(r.lowerBound), right = x(r.upperBound)
            if right < visible.minX || left > visible.maxX { continue }
            let selected = editor.state.selected.contains(i)
            (selected ? NSColor(calibratedRed:0.40,green:0.30,blue:0.16,alpha:1) : trackBackground).setFill()
            NSRect(x:left,y:trackTop,width:right-left,height:bottom-trackTop).fill()
            (selected ? accent : NSColor(calibratedRed:0.52,green:0.40,blue:0.24,alpha:1)).setFill()
            NSRect(x:left,y:trackTop,width:right-left,height:header).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:NSRect(x:left+3,y:trackTop,width:max(0,right-left-6),height:header)).addClip()
            text(String(format:"%03d",i+1) + "  " + (editor.state.titles[r.lowerBound] ?? editor.loadedName),at:NSPoint(x:left+7,y:trackTop+6),color:selected ? .black : ink,size:10,bold:true)
            NSGraphicsContext.restoreGraphicsState()
        }
        let step = editor.grid.step(sampleRate:a.sampleRate,bpm:editor.bpm)
        let pixelStep = step/a.sampleRate*editor.pps
        // Hide unreadable lines at extreme zoom-out; snapping still uses the chosen grid.
        let strideN = max(1,Int(ceil(7/max(0.001,pixelStep))))
        let first = max(0,Int(Double(frameAt(visible.minX))/step)/strideN*strideN)
        let last = Int(ceil(Double(frameAt(visible.maxX))/step))
        if last >= first { for tick in stride(from:first,through:last,by:strideN) {
            let f = Double(tick)*step; let xx = f/a.sampleRate*editor.pps
            let beat = Double(tick)*editor.grid.beats; let major = abs(beat/4-(beat/4).rounded()) < 0.00001
            (major ? NSColor(white:0.44,alpha:0.75) : NSColor(white:0.35,alpha:0.45)).setStroke()
            let path = NSBezierPath(); path.move(to:NSPoint(x:xx,y:trackTop+header)); path.line(to:NSPoint(x:xx,y:bottom)); path.lineWidth = 0.5; path.stroke()
            if major { text("\(Int((beat/4).rounded())+1)",at:NSPoint(x:xx+4,y:16),color:ink,size:11,bold:true) }
            else if pixelStep*Double(strideN) > 48 { text(String(format:"%d.%d",Int(beat/4)+1,Int(beat.truncatingRemainder(dividingBy:4))+1),at:NSPoint(x:xx+3,y:18),color:.secondaryLabelColor) }
        } }
        let waveTop = trackTop+header+9, waveHeight = max(40,bottom-waveTop-9)
        let channelHeight = waveHeight/CGFloat(a.channels)
        let wave = NSBezierPath(); wave.lineWidth = 1
        let lo = max(0,Int(visible.minX)), hi = min(Int(x(a.frames)),Int(ceil(visible.maxX)))
        if hi > lo { for c in 0..<a.channels {
            let mid = waveTop + channelHeight*(CGFloat(c)+0.5)
            for px in stride(from:lo,to:hi,by:2) {
                let peak = min(1,a.peak(channel:c,from:frameAt(CGFloat(px)),to:frameAt(CGFloat(px+2))))
                let amp = max(0.4,CGFloat(peak)*channelHeight*0.44)
                wave.move(to:NSPoint(x:CGFloat(px),y:mid-amp)); wave.line(to:NSPoint(x:CGFloat(px),y:mid+amp))
            }
        } }
        NSColor(calibratedRed:0.90,green:0.76,blue:0.51,alpha:1).setStroke(); wave.stroke()
        for span in editor.state.deleted {
            bg.setFill()
            NSRect(x: x(span.lowerBound), y: trackTop, width: x(span.upperBound)-x(span.lowerBound), height: bottom-trackTop).fill()
        }
        for cut in editor.state.cuts where x(cut) >= visible.minX && x(cut) <= visible.maxX {
            NSColor.black.setStroke(); let p = NSBezierPath(); p.move(to:NSPoint(x:x(cut),y:trackTop)); p.line(to:NSPoint(x:x(cut),y:bottom)); p.lineWidth=2; p.stroke()
        }
        if let r = editor.state.range { NSColor(calibratedRed:0.5,green:0.73,blue:0.95,alpha:0.22).setFill(); NSRect(x:x(r.lowerBound),y:trackTop+header,width:x(r.upperBound)-x(r.lowerBound),height:bottom-trackTop-header).fill() }
        let cursorX = x(editor.playhead ?? editor.state.cursor)
        (editor.playhead == nil ? NSColor.white : NSColor.systemGreen).setStroke(); let cursor = NSBezierPath(); cursor.move(to:NSPoint(x:cursorX,y:trackTop-6)); cursor.line(to:NSPoint(x:cursorX,y:bottom)); cursor.lineWidth=1.5; cursor.stroke()
        text(String(format:"%.3f s",Double(editor.state.cursor)/a.sampleRate),at:NSPoint(x:visible.minX+10,y:bottom+10),color:.secondaryLabelColor)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); guard editor.audio != nil, !editor.loading else { return }
        downPoint = convert(event.locationInWindow,from:nil); downFrame = editor.snap(frameAt(downPoint.x)); titleDrag = downPoint.y >= 38 && downPoint.y <= 63; hasDragged = false; downModifiers = event.modifierFlags; previousSelection = editor.state.selected
        let f = frameAt(downPoint.x); clickedIndex = editor.segments.firstIndex { $0.contains(f) }
        editor.state.cursor = downFrame; editor.state.range = nil
        if let i = clickedIndex, titleDrag || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            if event.modifierFlags.contains(.command) { if editor.state.selected.contains(i) { editor.state.selected.remove(i) } else { editor.state.selected.insert(i) } }
            else if event.modifierFlags.contains(.shift), let anchor = editor.state.selected.min() { editor.state.selected.formUnion(min(anchor,i)...max(anchor,i)) }
            else if !editor.state.selected.contains(i) { editor.state.selected = [i] }
        } else { editor.state.selected = [] }
        if event.clickCount == 2, let i = clickedIndex { editor.state.selected = [i]; editor.state.range = editor.segments[i]; titleDrag = true }
        editor.refresh()
    }
    override func mouseDragged(with event: NSEvent) {
        guard editor.audio != nil, !editor.loading else { return }
        let p = convert(event.locationInWindow,from:nil)
        guard hypot(p.x-downPoint.x,p.y-downPoint.y)>4 else { return }
        if titleDrag {
            guard !hasDragged else { return }; hasDragged = true
            if editor.needsOutputNumber(editor.outputSelection(all: false)) && editor.nameField.stringValue.contains("\\n") && editor.startNumber == nil {
                if editor.requestStart() { editor.refresh("시작 번호가 설정되었습니다. 선택한 제목 띠를 다시 드래그해 주세요.") }
                return
            }
            guard let urls = editor.dragFiles() else { return }
            dragDirectory = urls.first?.deletingLastPathComponent()
            let items = urls.enumerated().map { idx,url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter:url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile:url.path); icon.size=NSSize(width:32,height:32)
                item.setDraggingFrame(NSRect(x:p.x+CGFloat(idx%4)*4,y:p.y+CGFloat(idx%4)*4,width:32,height:32),contents:icon); return item
            }
            let session = beginDraggingSession(with:items,event:event,source:self); session.draggingFormation = .pile
        } else {
            hasDragged = true; autoscroll(with:event)
            let to = editor.snap(frameAt(p.x)); let low = min(downFrame,to), high = max(downFrame,to)
            editor.state.range = low < high ? low..<high : nil
            // Selection is defined by overlap with the time range.
            if let range = editor.state.range { editor.state.selected = Set(editor.segments.enumerated().filter { $0.element.overlaps(range) }.map { $0.offset }) }
            else { editor.state.selected = [] }
            editor.refresh()
        }
    }
    override func mouseUp(with event: NSEvent) {
        if titleDrag && !hasDragged && !downModifiers.contains(.command) && !downModifiers.contains(.shift), let i = clickedIndex { editor.state.selected = [i]; editor.refresh() }
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            guard editor.audio != nil else { return }
            let p = convert(event.locationInWindow,from:nil); let offset = p.x-editor.scroll.contentView.bounds.minX; let seconds = p.x/editor.pps
            let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            editor.pps = min(200000,max(0.05,editor.pps*exp(delta*(event.hasPreciseScrollingDeltas ? 0.012 : 0.1))))
            editor.resizeTimeline(); let origin = min(max(0,seconds*editor.pps-offset),max(0,bounds.width-editor.scroll.contentSize.width)); editor.scroll.contentView.scroll(to:NSPoint(x:origin,y:0)); editor.scroll.reflectScrolledClipView(editor.scroll.contentView); editor.refresh()
        } else {
            let delta = abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            let amount = delta*(event.hasPreciseScrollingDeltas ? 1 : 18)
            let origin = min(max(0,editor.scroll.contentView.bounds.minX-amount),max(0,bounds.width-editor.scroll.contentSize.width))
            editor.scroll.contentView.scroll(to:NSPoint(x:origin,y:0)); editor.scroll.reflectScrolledClipView(editor.scroll.contentView)
        }
    }
    override func deleteBackward(_ sender: Any?) { editor.deleteClips() }
    override func deleteForward(_ sender: Any?) { editor.deleteClips() }
    override func selectAll(_ sender: Any?) { editor.selectAllClips() }
    override func keyDown(with event: NSEvent) {
        if [51,117].contains(event.keyCode) { editor.deleteClips(); return }
        if event.keyCode == 49 { editor.togglePlay(); return }
        if event.keyCode == 53 { editor.state.selected=[]; editor.state.range=nil; editor.stop(); editor.refresh(); return }
        if [123,124].contains(event.keyCode), let a = editor.audio {
            let s = editor.grid.step(sampleRate:a.sampleRate,bpm:editor.bpm); let direction = event.keyCode == 123 ? -1.0 : 1.0
            let next = min(a.frames,max(0,Int(((Double(editor.state.cursor)/s).rounded()+direction)*s+0.5)))
            if event.modifierFlags.contains(.shift) { let old = editor.state.range?.lowerBound ?? editor.state.cursor; if old != next { editor.state.range = min(old,next)..<max(old,next) } }
            else { editor.state.range=nil; editor.state.selected=[] }
            editor.state.cursor=next; editor.refresh(); return
        }
        super.keyDown(with:event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(); for (t,a) in [("자르기 ⌘E",#selector(Editor.split)),("합치기 ⌘J",#selector(Editor.join)),("그리드 일괄 자르기",#selector(Editor.splitGrid)),("삭제 ⌫",#selector(Editor.deleteClips)),("선택 WAV 내보내기…",#selector(Editor.exportSelected))] { let i=NSMenuItem(title:t,action:a,keyEquivalent:""); i.target=editor; m.addItem(i) }; return m
    }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.isEmpty, let directory = dragDirectory { try? FileManager.default.removeItem(at: directory) }
        dragDirectory = nil
    }

}
let app = NSApplication.shared
let delegate = Editor()
app.delegate = delegate
app.run()
