import Foundation

/// The scan worker runs with Mac Polish's file permissions, so it must only answer the app that launched it.
@main
enum ScanWorkerGuardCheck {
    static func main() {
        // This test binary doubles as the worker, exactly like the app binary does.
        if let status = ScanWorker.runIfRequested(CommandLine.arguments) { exit(status) }
        guard let executable = Bundle.main.executableURL?.path else { preconditionFailure("No executable path") }

        // The app's own launch path keeps working.
        guard case .success = DiskScanService.read(StartupEntry.self, mode: "startup", timeout: 30) else {
            preconditionFailure("The worker must answer the process that launched it")
        }

        // Break caught: any other process (a shell, `open --args`, a script) reading through the worker.
        // A compound command keeps the shell as the parent instead of exec-ing the worker in its place.
        let viaShell = SystemDataScanner.run("/bin/sh", ["-c", "\"$0\" --scan-worker startup; exit $?", executable], timeout: 30)
        precondition(viaShell.status != 0 && viaShell.output.isEmpty,
                     "A worker launched by another program must refuse and print nothing (status \(viaShell.status))")
        print("PASS: scan worker answers its launching app and refuses other parent processes")
    }
}
