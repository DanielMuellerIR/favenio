import Foundation
import Darwin
@main struct Bench {
 static func main() {
  let mode = CommandLine.arguments[1]
  var hits: [Hit] = []
  var done = false
  var status: Int32?
  let start = ProcessInfo.processInfo.systemUptime
  var last = start
  var maxDelay = 0.0
  let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
   let now = ProcessInfo.processInfo.systemUptime
   maxDelay = max(maxDelay, now-last-0.005); last = now
  }
  let args = ["-u", "-c", "import json,sys; [print(json.dumps({'path':'/fixture/file-%d.txt'%i,'type':'file','isDirectory':False,'filesystemPath':'/fixture/file-%d.txt'%i,'archiveMembers':[]})) for i in range(100000)]"]
  if mode == "quick" {
   DispatchQueue.global().async {
    let result = runSearchStreaming(arguments: args, onHit: { hits.append($0) }, onProgress: { _ in })
    DispatchQueue.main.async { status = result.status; done = true }
   }
  } else {
   let process = Process(); process.executableURL = URL(fileURLWithPath: pythonPath); process.arguments = args
   let pipe = Pipe(); process.standardOutput = pipe
   var buffer = Data(); var eof = false; var ended = false
   func consume(_ data: Data) {
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
     let line = buffer.subdata(in: buffer.startIndex..<newline)
     buffer.removeSubrange(buffer.startIndex...newline)
     if case .hit(let hit)? = parseSearchLine(line) { hits.append(hit) }
    }
   }
   pipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
     handle.readabilityHandler = nil
     DispatchQueue.main.async { eof = true; done = eof && ended }
    } else { DispatchQueue.main.async { consume(data) } }
   }
   process.terminationHandler = { process in DispatchQueue.main.async { status = process.terminationStatus; ended = true; done = eof && ended } }
   try! process.run()
  }
  while !done && ProcessInfo.processInfo.systemUptime-start < 60 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001)) }
  timer.invalidate()
  let elapsed = ProcessInfo.processInfo.systemUptime-start
  var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
  guard done, status == 0 else {
   fputs("Runner-Messung nicht erfolgreich abgeschlossen\n", stderr)
   exit(2)
  }
  guard hits.count == 100000,
        hits.enumerated().allSatisfy({ $0.element.path == "/fixture/file-\($0.offset).txt" }) else {
   fputs("Runner-Messung verliert oder vertauscht Treffer\n", stderr)
   exit(2)
  }
  print("mode=\(mode) hits=\(hits.count) seconds=\(elapsed) rss=\(usage.ru_maxrss) max_delay=\(maxDelay)")

 }
}
