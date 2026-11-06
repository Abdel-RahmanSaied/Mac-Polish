import Foundation

@main
enum AccessGateCheck {
    @MainActor static func main() {
        let suite = "MacPolish-access-gate-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // Old onboarding completion alone must not bypass the new verification.
        defaults.set(true, forKey: AccessSetupModel.completedKey)
        let access = AccessSetupModel(defaults: defaults, probe: { .unknown }, copies: { [] })
        precondition(!access.authorizeScan() && access.presented)
        access.finish()
        precondition(access.presented && !defaults.bool(forKey: AccessSetupModel.reviewedKey), "Unchecked setup cannot finish")
        let app = AppModel(access: access)
        app.startScan()
        app.findDuplicates()
        app.loadApplications()
        app.analyzeStorage()
        app.analyzeSystemData()
        app.loadStartupItems()
        app.optimizer.scan()
        precondition(app.state == .idle && app.duplicateState == .idle && app.applicationState == .idle)
        precondition(app.storageState == .idle && app.startupState == .idle && !app.systemDataLoading && !app.optimizer.busy,
                     "All production scan entry points must refuse work before access review")
        access.results = FolderAccessCheck.locations().map { FolderAccessResult(name: $0.0, url: $0.1, status: .readable) }
        access.checkedAt = Date()
        access.fullDiskAccess = .unknown
        let removed = access.results.removeLast()
        precondition(!access.hasCompletedChecks, "One missing answer keeps verification incomplete")
        access.results.append(removed)
        precondition(access.hasCompletedChecks && access.hasIncompleteAccess, "Unknown protected access is never certified")
        access.checking = true
        precondition(!access.hasCompletedChecks && !access.authorizeScan())
        access.checking = false
        // Explicitly continuing after all answers acknowledges a limited scan, not a permission grant.
        access.finish()
        precondition(access.authorizeScan())
        let reopened = AccessSetupModel(defaults: defaults, probe: { .unknown }, copies: { [] })
        precondition(reopened.authorizeScan(), "Completed review persists without asking every update")
        reopened.accessLost = true
        precondition(!reopened.authorizeScan() && reopened.presented, "Known access loss requires review again")
        let paths = Set(FolderAccessCheck.locations().map { $0.1.standardizedFileURL.path })
        precondition(SystemDataScanner.specifications().allSatisfy { paths.contains($0.url.standardizedFileURL.path) },
                     "Every System Data root must be included in upfront verification")
        print("PASS: all scan entry points blocked before verification, no skipped/partial checks, explicit limited review, persistence, lost-access gate, complete System Data root inventory")
    }
}
