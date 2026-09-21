import AVFoundation
import BMSlicerCore


var checks = 0
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { checks += 1; if a != b { fatalError("Expected \(a) == \(b)", file:file,line:line) } }
func expectEqual(_ a: Float, _ b: Float, accuracy: Float, file: StaticString = #file, line: UInt = #line) { checks += 1; if abs(a-b)>accuracy { fatalError("Sample mismatch \(a) / \(b)",file:file,line:line) } }
func expectLE(_ a: Double, _ b: Double) { checks += 1; precondition(a<=b) }
func expectGT<T: Comparable>(_ a: T, _ b: T) { checks += 1; precondition(a>b) }
func expectThrows<T>(_ operation: @autoclosure () throws -> T) { checks += 1; do { _ = try operation(); fatalError("Expected failure") } catch {} }

final class CoreTests {
    func fixture(_ ext: String) -> URL { URL(fileURLWithPath: "/dev/null") }
    func testTripletGridAndNoCumulativeDrift() {
        for rate in [44100.0,48000.0,96000.0] { for bpm in [120.0,137.35,999.0] { for denominator in [2,4,8,16,32] { for triplet in [true,false] {
            let g = Grid(denominator,triplet:triplet)
            let step = rate * 60/bpm * 4/Double(denominator)*(triplet ? 2.0/3 : 1)
            let cuts = g.boundaries(sampleRate:rate,bpm:bpm,total:Int(rate*61))
            expectEqual(Set(cuts).count,cuts.count)
            for (i,f) in cuts.enumerated() { expectLE(abs(Double(f)-Double(i+1)*step),0.500001) }
        } } } }
    }
    func testSplitJoinAndNonContiguousSelection() {
        var e = EditState(); e.split(at:[0,10,20,30,40,50,50,100],total:100)
        expectEqual(e.cuts,[10,20,30,40,50]); expectEqual(e.segments(total:100).reduce(0){$0+$1.count},100)
        e.selected=[0,1,3,4]; e.join(total:100)
        expectEqual(e.cuts,[20,30,50]); expectEqual(e.selected,[0,2])
        e.selected = Set(e.segments(total:100).indices); e.join(total:100); expectEqual(e.cuts,[])
    }
    func testRangeJoinAndSplit() {
        var e = EditState(); e.split(at:[10,20,30],total:40); e.range=11..<29; e.join(total:40); expectEqual(e.cuts,[10,30])
        e.split(at:[12,27],total:40); expectEqual(e.cuts,[10,12,27,30])
    }
    func testNaming() throws {
        expectEqual(try Naming.names(template:"pluck_top_\\n",count:3,start:3),["pluck_top_3.wav","pluck_top_4.wav","pluck_top_5.wav"])
        expectEqual(try Naming.names(template:"키음_\\n.wav",count:2,start:9,digits:3),["키음_009.wav","키음_010.wav"])
        expectEqual(try Naming.names(template:"pluck",count:2,start:1),["pluck_1.wav","pluck_2.wav"])
        for name in ["../evil_\\n","CON","foo:bar","","a\nfoo","a\\bad"] { expectThrows(try Naming.names(template:name,count:1,start:1)) }
        expectThrows(try Naming.names(template:"a_\\n",count:2,start:Int.max))
    }
    func testExportRoundTripAndExactReconstruction() throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? fm.removeItem(at:dir) }
        let samples: [[Float]] = [(0..<1001).map{Float(sin(Double($0)*0.17)*0.9)},(0..<1001).map{Float(cos(Double($0)*0.31)*0.7)}]
        let a = try AudioData(samples:samples,sampleRate:48000,source:dir.appendingPathComponent("source.wav"))
        for bits in [16,24] {
            let ranges = [0..<333,333..<666,666..<1001]
            let names = (0..<3).map{"\(bits)_\($0).wav"}
            let urls = try a.export(ranges:ranges,names:names,directory:dir,bits:bits)
            var joined = [[Float](),[Float]()]
            for (i,url) in urls.enumerated() {
                let read = try AudioData.load(url); expectEqual(read.frames,ranges[i].count); expectEqual(read.channels,2); expectEqual(read.sampleRate,48000)
                for c in 0..<2 { joined[c] += read.samples[c] }
            }
            for c in 0..<2 { for f in 0..<1001 { expectEqual(joined[c][f],samples[c][f],accuracy:bits == 24 ? 0.00000013 : 0.000031) } }
            let original = try Data(contentsOf:urls[0])
            expectThrows(try a.export(ranges:ranges,names:names,directory:dir,bits:bits)); expectEqual(try Data(contentsOf:urls[0]),original)
        }
    }
    func testOddLength24BitWavAndClipping() throws {
        let a = try AudioData(samples:[[-2,-1,0,1,2,Float.nan,0.25]],sampleRate:44100,source:fixture("ogg"))
        let data = try a.wav(range:0..<7,bits:24)
        expectEqual(data.count,66); expectEqual(data[40],21); expectEqual(data[65],0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        defer { try? FileManager.default.removeItem(at:url) }; try data.write(to:url)
        let b = try AudioData.load(url); expectEqual(b.frames,7); expectEqual(b.samples[0][0],-1); expectEqual(b.samples[0][5],0)
    }
    func testOggAndMP3Decode() throws {
        for ext in ["ogg","mp3"] {
            guard let i = CommandLine.arguments.firstIndex(of: "--"+ext), CommandLine.arguments.count > i+1 else { throw SliceError.message("Missing --"+ext+" file path") }; let a = try AudioData.load(URL(fileURLWithPath: CommandLine.arguments[i+1])); expectGT(a.frames,100); expectGT(a.sampleRate,0); if ext == "ogg" { expectGT(a.samples[0].map{abs($0)}.max()!,0) }; print("Decoded \(ext): \(a.frames) frames, \(a.sampleRate) Hz, \(a.channels) channels")
        }
    }
    func testFailureDoesNotLeavePartialFiles() throws {
        let fm = FileManager.default, dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true); defer { try? fm.removeItem(at:dir) }
        let a = try AudioData(samples:[[0,0.1,0.2]],sampleRate:44100,source:fixture("ogg"))
        expectThrows(try a.export(ranges:[0..<2,2..<5],names:["a.wav","b.wav"],directory:dir,bits:24))
        expectEqual(try fm.contentsOfDirectory(atPath:dir.path),[])
    }
    func testAdaptiveGrid() {
        expectEqual(Grid.adaptive(pixelsPerSecond:1000,bpm:120,triplet:false).denominator,32)
        expectEqual(Grid.adaptive(pixelsPerSecond:20,bpm:120,triplet:false).denominator,2)
        expectEqual(Grid(16,triplet:true).snap(22049,sampleRate:44100,bpm:120,total:44100),22050)
    }
}

func testClipRename() throws {
    var state = EditState(); state.split(at: [10, 20], total: 30)
    let before = state
    state.selected = [0, 2]
    try state.rename(total: 30, template: "pluck_top_\\n", start: 3)
    expectEqual(state.titles, [0: "pluck_top_3.wav", 20: "pluck_top_4.wav"])
    expectEqual(state.cuts, before.cuts)
    expectEqual(try state.outputNames(ranges: [0..<10, 20..<30], template: "", start: 1), ["pluck_top_3.wav", "pluck_top_4.wav"])
    let renamed = state
    expectThrows(try state.rename(total: 30, template: "bad/name", start: 1))
    expectEqual(state, renamed)
    state.selected = []; try state.rename(total: 30, template: "키음_\\n", start: 8, digits: 2)
    expectEqual(state.titles, [0: "키음_08.wav", 10: "키음_09.wav", 20: "키음_10.wav"])
    state.selected = [0, 1]; state.join(total: 30)
    expectEqual(state.titles, [0: "키음_08.wav", 20: "키음_10.wav"])
    state.split(at: [10], total: 30); expectEqual(state.titles[10], nil)
}

let tests = CoreTests()
var suite: [(String, () throws -> Void)] = [
("grid rounding and triplets",tests.testTripletGridAndNoCumulativeDrift),
("split/join and noncontiguous selection",tests.testSplitJoinAndNonContiguousSelection),
("range join/split",tests.testRangeJoinAndSplit),
("numbered filenames and invalid names",tests.testNaming),
("PCM 16/24-bit roundtrip and lossless boundaries",tests.testExportRoundTripAndExactReconstruction),
("odd WAV chunk padding and clipping",tests.testOddLength24BitWavAndClipping),
("transactional export failure",tests.testFailureDoesNotLeavePartialFiles),
("adaptive grid and snapping",tests.testAdaptiveGrid),
("clip titles, numbering and edit preservation",testClipRename)]
if CommandLine.arguments.contains("--ogg") && CommandLine.arguments.contains("--mp3") { suite.append(("OGG and MP3 input",tests.testOggAndMP3Decode)) }
if CommandLine.arguments.contains("--drop") { suite.append(("AppKit file drop lifecycle",testFileDrops)); suite.append(("File-promise type negotiation",testPromiseNegotiation)) }
do { for (name,run) in suite { try run(); print("PASS: \(name)") }; print("ALL PASSED: \(suite.count) suites, \(checks) checks") } catch { print("FAIL: \(error)"); exit(1) }
