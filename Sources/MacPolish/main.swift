import Foundation

if let status = ScanWorker.runIfRequested(CommandLine.arguments) {
    exit(status)
} else {
    MacPolishApp.main()
}
