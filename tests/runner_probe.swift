// Headless-Probe des unveränderten gemeinsamen Runners. Keine App/Finder-Aktion.
import Foundation
import Darwin

#if !FAVENIO_TEST_SUITE
@main
#endif
struct RunnerProbe {
    static func rapidChanges() {
        var current: SearchRunner?
        var runners: [SearchRunner] = []
        var completed = 0
        var completionCounts = Array(repeating: 0, count: 20)
        var accepted: [String] = []
        for index in 0..<20 {
            current?.cancel()
            let runner = SearchRunner()
            runners.append(runner)
            current = runner
            let script = "import json; [print(json.dumps({'path':'/run-\(index)/'+str(i),'type':'file','isDirectory':False,'filesystemPath':'/run-\(index)/'+str(i),'archiveMembers':[]})) for i in range(1000)]"
            runner.start(arguments: ["-c", script], onBatch: { [weak runner] hits, _ in
                precondition(Thread.isMainThread)
                guard let runner, current === runner else { return }
                accepted.append(contentsOf: hits.map { $0.path })
            }, completion: { _ in
                precondition(Thread.isMainThread)
                completionCounts[index] += 1
                precondition(completionCounts[index] == 1)
                completed += 1
            })
            // A hat wirklich Zeit zum Produzieren. Main hält seine Pakete
            // zurück, bevor B die aktuelle Identität übernimmt.
            if index == 0 {
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while runner.transportPeaks.packets == 0,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        while completed < 20 && ProcessInfo.processInfo.systemUptime - start < 10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        let result: [String: Any] = ["completed": completed, "hits": accepted.count,
                                    "stale": accepted.filter { !$0.hasPrefix("/run-19/") }.count,
                                    "first_queued": runners[0].transportPeaks.packets]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }

    static func main() {
        run(CommandLine.arguments)
    }

    static func run(_ arguments: [String]) {
        let mode = arguments[1]
        if mode == "rapid" { rapidChanges(); return }
        let payload = "import json,sys,os,time\ndef hit(i):\n print(json.dumps({'path':'/fixture/file-%d.txt'%i,'type':'file','isDirectory':False,'filesystemPath':'/fixture/file-%d.txt'%i,'archiveMembers':[]}),flush=True)\n"
        var script = payload
        switch mode {
        case "ignore-term": script += "import signal;signal.signal(signal.SIGTERM,signal.SIG_IGN);print(json.dumps({'type':'progress','path':'ready'}),flush=True);time.sleep(10)"
        case "large-records": script += "[print(json.dumps({'path':'/'+str(i)+'x'*300000,'type':'file','isDirectory':False,'filesystemPath':'/'+str(i)+'x'*300000,'archiveMembers':[]})) for i in range(5)]"
        case "progress": script += "print(json.dumps({'type':'progress','path':'/only-progress'}))"
        case "tail": script += "sys.stdout.write(json.dumps({'path':'/tail','type':'file','isDirectory':False,'filesystemPath':'/tail','archiveMembers':[]}))"
        case "stderr": script += "[print('favenio: warnung: '+str(i),file=sys.stderr) for i in range(10000)];hit(0)"
        // Fremde stderr-Zeile ohne Favenio-Präfix, dann Status 69 — wie der
        // Apple-Stummel /usr/bin/python3 ohne akzeptierte Xcode-Lizenz.
        case "foreign-stderr": script += "print('You have not agreed to the Xcode license agreements.',file=sys.stderr);sys.exit(69)"
        // Dieselbe Lage mit CRLF-Zeilenenden und einer Leerzeile davor: Das
        // übrig bleibende „\r" darf nicht selbst zum Grund werden.
        case "foreign-crlf": script += "sys.stderr.write('\\r\\nxcrun: error: invalid active developer path\\r\\n');sys.exit(69)"
        case "eof-first": script += "hit(0);os.close(1);time.sleep(.1)"
        case "exit-first": script += "hit(0)\nif os.fork()==0:\n time.sleep(.1);os._exit(0)\nos._exit(0)"
        case "oversize": script += "sys.stdout.write('x'*1100000);sys.stdout.flush();time.sleep(5)"
        case "cancel-before", "cancel", "backpressure": script += "[hit(i) for i in range(100000)];time.sleep(5)"
        default: script += "[hit(i) for i in range(4097)]"
        }
        var hits: [Hit] = []
        var completed: SearchExit?
        var largestBatch = 0
        var completionCount = 0
        var lastProgress = ""
        let runner = SearchRunner()
        if mode == "cancel-before" { runner.cancel() }
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        var delay = 0.0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            delay = max(delay, now - last - 0.005); last = now
        }
        runner.start(arguments: ["-u", "-c", script],
                     executable: mode == "start-error" ? "/no-such-favenio-interpreter" : pythonPath,
                     onBatch: { batch, progress in
            precondition(Thread.isMainThread)
            if let progress {
                lastProgress = progress
                if mode == "ignore-term", progress == "ready" { runner.cancel() }
            }
            largestBatch = max(largestBatch, batch.count)
            hits.append(contentsOf: batch)
            if mode == "cancel", !batch.isEmpty { runner.cancel() }
        }, completion: {
            precondition(Thread.isMainThread)
            completionCount += 1
            precondition(completionCount == 1)
            completed = $0
        })
        if mode == "backpressure" {
            // Main verarbeitet absichtlich keine Pakete; Abbruch muss den
            // Hintergrundleser trotzdem aus dem vollen Transport holen.
            let fullDeadline = ProcessInfo.processInfo.systemUptime + 5
            while runner.transportPeaks.packets < 2
                    && ProcessInfo.processInfo.systemUptime < fullDeadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            runner.cancel()
        }
        while completed == nil && ProcessInfo.processInfo.systemUptime - start < 15 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        timer.invalidate()
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["mode": mode, "hits": hits.count,
            "seconds": ProcessInfo.processInfo.systemUptime - start,
            "rss": usage.ru_maxrss, "peak_packets": runner.transportPeaks.packets,
            "peak_bytes": runner.transportPeaks.bytes, "progress": lastProgress, "max_delay": delay, "largest_batch": largestBatch,
            "completions": completionCount,
            "ordered": hits.enumerated().allSatisfy { $0.element.path == "/fixture/file-\($0.offset).txt" }, "running": runner.process.isRunning, "status": completed?.status ?? -999,
            "warnings": completed?.warningCount ?? -1,
            "error": completed?.errorMessage ?? ""]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        if completed == nil { exit(1) }
    }
}
