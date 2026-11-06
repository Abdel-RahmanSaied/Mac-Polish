import Foundation

/// The privacy-safe report redactor, on a fake identity and a fixture report with every kind of path the deep scan
/// report contains, plus one check against the live account.
@main
enum ReportPrivacyCheck {
    static let identity = ReportRedactor.Identity(home: "/Users/jdoe", userName: "jdoe", fullName: "Jane Doe",
                                                  hostNames: ["Janes-MacBook-Pro"])

    static let fixture = """
    # Mac Polish deep scan report

    Created November 6, 2026 at 9:41 AM.
    Read-only scan results. Paths and file names are included; review before sharing.

    Deep scan duration: 42 s.

    ## Steps

    | Step | Result | Time |
    | --- | --- | --- |
    | Mac health | Score 87 · 0 critical · 2 need attention | 3 s |
    | Every file on the startup disk | 1,234,567 files counted · 93% of used space explained | 31 s |
    | Caches, logs, developer and large files | Incomplete: Could not read /Users/jdoe/Library/Mail: Operation not permitted | 12 s |
    | Project build folders | 4 folders · 16.1 GB | — |

    # Mac Health Report

    Checked November 6, 2026 at 9:41 AM · Score 87/100 · 0 critical · 2 need attention

    ## This Mac

    - **Model** (Info): MacBook Pro
      - Model identifier MacBookPro18,3.
    - **Serial number** (Info): C02XK0ABJGH5
    - **Computer name** (Info): Jane’s MacBook Pro (Janes-MacBook-Pro.local)
    - **Owner** (Info): Jane Doe <jane.doe@example.com>
    - **Uptime** (Info): 3 days
      - Since the last restart on Nov 3, 2026 at 8:00 AM.
    - **Free space** (Good): 412.5 GB free of 994.66 GB
      - 41% of the startup disk is available. This does not check whether an update is available.

    ## Storage

    - 1.2 TB used of 2 TB; 800 GB free.
    - Found 1.1 TB of 1.2 TB used on the data volume (93%).

    ### Largest files

    | File | Size | Modified |
    | --- | ---: | --- |
    | `/Users/jdoe/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | 64 GB | Nov 1, 2026 |
    | `/private/var/vm/swapfile0` | 1.2 GB | Nov 6, 2026 |
    | `/Users/jdoe/Movies/Wedding Video 2023.mov` | 23.4 GB | Jun 12, 2023 |
    | `/Users/jdoe/Downloads/ubuntu-24.04-desktop-arm64.iso` | 6.1 GB | Oct 2, 2026 |
    | `/Users/jdoe/Projects/acme-site/node_modules/.cache/webpack/0.pack` | 900 MB | — |
    | `/Users/jdoe/Projects/rocket-engine/target/debug/deps/librocket_engine-1a2b3c4d.rlib` | 700 MB | — |
    | `/Users/jdoe/Library/Developer/Xcode/DerivedData/AcmeSite-abcdefghijklmnopqrstuvwxyzab/Build/Products/Debug/AcmeSite.app/Contents/MacOS/AcmeSite` | 650 MB | — |
    | `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/usr/lib/libLLVM.dylib` | 600 MB | — |
    | `/System/Volumes/Data/Users/jdoe/Desktop/Client Projects/Smith & Co/Invoice March.pdf` | 500 MB | — |
    | `/Users/jdoe/Library/Application Support/MobileSync/Backup/00008103-001A2B3C4D5E001E/Manifest.db` | 450 MB | — |
    | `/Users/jdoe/Library/Mobile Documents/com~apple~CloudDocs/Taxes/2023 Return.pdf` | 400 MB | — |
    | `/Users/jdoe/Library/CloudStorage/GoogleDrive-jane.doe@example.com/My Drive/Résumé — Jane Doe.docx` | 300 MB | — |
    | `/Users/bob/Documents/Secret Plans.key` | 250 MB | — |
    | `/Users/Shared/Family Photos/IMG_0001.HEIC` | 200 MB | — |
    | `/Volumes/Jane’s Passport/Backups.backupdb/Janes-MacBook-Pro/2026-11-01-120000/Macintosh HD - Data/Users/jdoe/Documents/notes.txt` | 150 MB | — |
    | `/Users/jdoe/Library/Caches/com.apple.Safari/WebKitCache/Version 16/Blobs/ABC` | 120 MB | — |
    | `/Users/jdoe/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/Outlook.sqlite` | 110 MB | — |
    | `/Users/jdoe/.npm/_cacache/content-v2/sha512/ab/cd/ef` | 100 MB | — |
    | `/Users/jdoe/.cargo/registry/cache/index.crates.io-6f17d22bba15001f/serde-1.0.0.crate` | 90 MB | — |
    | `/private/var/folders/zz/zyxvpxvq6csfxvn_n0000000000000/T/jdoe-export/report.csv` | 80 MB | — |
    | `/Users/jdoe/Pictures/Photos Library.photoslibrary/database/Photos.sqlite` | 70 MB | — |
    | `/Users/jdoe/Library/Developer/CoreSimulator/Devices/12345678-90AB-CDEF-1234-567890ABCDEF/data/Library/Caches/x.db` | 60 MB | — |
    | `/Users/jdoe/Projects/acme-site/node_modules` | 1.4 GB | — |
    | /Users/jdoe/Downloads/Holiday Plans/Itinerary Final.pdf | 10 MB | — |

    ## Startup items to review

    - `com.jdoe.sync-agent` (The program has no code signature, so nothing identifies who made it.; Runs through bash. The signature shown is the interpreter's; the script it runs (/Users/jdoe/bin/sync photos.sh) is not covered by it.)
    - `com.vendor.helper` (The program is in a hidden, temporary or shared folder that other software can write to.; The property list is a symbolic link to /Users/jdoe/dotfiles/LaunchAgents/com.vendor.helper.plist.)
    - `org.example.updater` (The program it starts no longer exists. This is usually left behind by an app that was removed.; The app it belongs to (com.example.Updater) was not found.)
    - `local.tool` (node was not found in /usr/bin, /bin, /usr/sbin or /sbin, where launchd looks for it.)
    - `Jane's backup` (Its property list in /Library is not owned by root, so a non-administrator account may be able to change what runs.)

    - Project build folders: 4, 16.1 GB
      - `/Users/jdoe/Projects/acme-site/node_modules` · node_modules · 1.4 GB
      - `/Users/jdoe/Projects/acme-site/.next` · Next.js .next · 300 MB
      - `/Users/jdoe/Projects/rocket-engine/target` · Rust target · 12.3 GB
      - `/Users/jdoe/Documents/Work/Mac polish Services/Mac-polish/.build` · SwiftPM .build · 2 GB
    - Leftover data of removed apps: 3 items, 140 MB (review: matched by bundle identifier)
      - `~/Library/Application Support/com.oldvendor.OldApp` · 120 MB
      - file:///Users/jdoe/Library/Saved%20Application%20State/com.jdoe.tool.savedState/
      - `~/Library/Containers/com.apple.Preview/Data/Library/Autosave Information/Unsaved Contract.pdf`

    Contact: jdoe@example.com, jane.doe+mac@example.co.uk. Host janes-macbook-pro.local reported for user jdoe (JaneDoe99).
    Hardware UUID 12345678-90AB-CDEF-1234-567890ABCDEF; Wi-Fi a4:83:e7:12:34:56.
    Error: The file “Tax Return 2023.pdf” couldn’t be opened because you don’t have permission to view it.
    Nothing was moved or deleted by this report. Sizes are allocated disk space; moving files to Trash frees space only when Trash is emptied.
    """

    static func main() {
        var redactor = ReportRedactor(identity: identity)
        let safe = redactor.text(fixture)
        let lower = safe.lowercased()

        // Nothing that identifies the person, the Mac or another account survives.
        for secret in ["jdoe", "jane", "janes-macbook-pro", "/users/jdoe", "jane.doe@example.com", "c02xk0abjgh5",
                       "bob", "smith", "acme", "rocket", "wedding", "invoice", "taxes", "secret plans", "passport",
                       "résumé", "holiday", "itinerary", "contract", "family photos", "tax return",
                       "00008103-001a2b3c4d5e001e", "12345678-90ab", "a4:83:e7", "zyxvpxvq6csfxvn",
                       "mac polish services", "sync photos", "dotfiles"] {
            precondition(!lower.contains(secret), "\(secret) survived:\n\(safe)")
        }
        precondition(safe.range(of: "\\bdoe\\b", options: [.regularExpression, .caseInsensitive]) == nil, safe)

        // Diagnostic structure, sizes, dates and findings stay readable.
        for kept in ["node_modules", "com.apple.Safari", "/Applications/Xcode.app/Contents/Developer", "Library/Caches",
                     "1.2 GB", "93%", "412.5 GB free of 994.66 GB", "November 6, 2026 at 9:41 AM", "Nov 6, 2026",
                     "Score 87/100", "MacBookPro18,3", "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                     "/private/var/vm/swapfile0", "libLLVM.dylib", "UBF8T346G9.Office", "~/.npm/_cacache",
                     "~/.cargo/registry", "com~apple~CloudDocs", "Macintosh HD - Data", "Backups.backupdb",
                     "DerivedData", "Photos Library.photoslibrary/database/Photos.sqlite",
                     "~/Library/Application Support/com.oldvendor.OldApp", "/usr/bin, /bin, /usr/sbin or /sbin",
                     "Its property list in /Library is not owned by root", "`org.example.updater`",
                     "(com.example.Updater)", "need attention", "critical", "Operation not permitted",
                     "~/Library/Mail: Operation", "| --- | ---: | --- |", "Model identifier", "MacBook Pro"] {
            precondition(safe.contains(kept), "\(kept) was lost:\n\(safe)")
        }

        // Expected rewrites, with aliases numbered in first-seen order and the same folder aliased the same way.
        for expected in [
            "`~/Movies/‹file›.mov`", "`~/Downloads/‹file›.iso`",
            "`~/Projects/‹project 1›/node_modules/.cache/webpack/0.pack`",
            "`~/Projects/‹project 2›/target/debug/deps/‹file›.rlib`",
            "DerivedData/‹project 3›/Build/Products/Debug/‹project 3›.app/Contents/MacOS/‹project 3›`",
            "`~/Desktop/‹folder 1›/‹folder 2›/‹file›.pdf`",
            "MobileSync/Backup/‹id 1›/Manifest.db", "Mobile Documents/com~apple~CloudDocs/‹folder 3›/‹file›.pdf",
            "CloudStorage/GoogleDrive-‹account›/My Drive/‹file›.docx", "`/Users/‹other user›/Documents/‹file›.key`",
            "`/Users/Shared/‹folder 4›/‹file›.HEIC`",
            "`/Volumes/‹volume 1›/Backups.backupdb/‹folder 5›/2026-11-01-120000/Macintosh HD - Data/Users/‹user›/Documents/‹file›.txt`",
            "`/private/var/folders/‹per-user›/T/‹folder 6›/‹file›.csv`",
            "CoreSimulator/Devices/‹id 2›/data", "| `~/Projects/‹project 1›/node_modules` | 1.4 GB |",
            "| ~/Downloads/‹folder 7›/‹file›.pdf | 10 MB |",
            "`com.‹user›.sync-agent`", "(~/bin/‹file›.sh)", "symbolic link to ~/‹folder 8›/LaunchAgents/com.vendor.helper.plist.)",
            "`‹user›'s backup`", "`~/Projects/‹project 1›/.next`", "`~/Projects/‹project 2›/target`",
            "`~/Documents/Work/‹project 4›/‹folder 9›/.build`",
            "~/Library/Saved Application State/com.‹user›.tool.savedState/",
            "Autosave Information/‹file›.pdf`", "‹user›’s MacBook Pro (‹host›.local)", "‹user› <‹email›>",
            "**Serial number** (Info): ‹serial›", "Contact: ‹email›, ‹email›. Host ‹host›.local reported for user ‹user› (‹user›99).",
            "Hardware UUID ‹id 2›; Wi-Fi ‹mac address›.", "The file “‹file›.pdf” couldn’t be opened",
        ] {
            precondition(safe.contains(expected), "missing \(expected):\n\(safe)")
        }

        // Tables and code spans keep their shape.
        let before = fixture.components(separatedBy: "\n")
        let after = safe.components(separatedBy: "\n")
        precondition(before.count == after.count, "line count changed")
        for (original, redacted) in zip(before, after) {
            precondition(original.filter { $0 == "|" }.count == redacted.filter { $0 == "|" }.count, "pipes: \(redacted)")
            precondition(original.filter { $0 == "`" }.count == redacted.filter { $0 == "`" }.count, "backticks: \(redacted)")
        }

        // Paths on their own: the same folder keeps its alias in every spelling, other projects get other aliases.
        let spellings = ["/Users/jdoe/Projects/acme-site", "file:///Users/jdoe/Projects/acme-site/",
                         "/System/Volumes/Data/Users/jdoe/Projects/acme-site/node_modules", "~/Projects/acme-site/.next",
                         "/Users/JDOE/projects/ACME-SITE/package.json", "~jdoe/Projects/acme-site"]
        let expectedSpellings = ["~/Projects/‹project 1›", "~/Projects/‹project 1›/",
                                 "~/Projects/‹project 1›/node_modules", "~/Projects/‹project 1›/.next",
                                 "~/projects/‹project 1›/package.json", "~/Projects/‹project 1›"]
        for (input, expected) in zip(spellings, expectedSpellings) {
            let output = redactor.path(input)
            precondition(output == expected, "\(input) → \(output), expected \(expected)")
        }
        precondition(redactor.path("/Users/jdoe/Projects/new-thing/Cargo.toml") == "~/Projects/‹project 5›/Cargo.toml")
        precondition(redactor.path("/Users/jdoe/Projects/rocket-engine") == "~/Projects/‹project 2›")
        let pathCases: [(String, String)] = [
            ("/Users/jdoe", "~"), ("/Users/jdoe/", "~/"), ("~", "~"), ("/", "/"), ("/Users", "/Users"),
            ("/Applications/Xcode.app/Contents/Info.plist", "/Applications/Xcode.app/Contents/Info.plist"),
            ("/Library/Application Support/com.apple.TCC/TCC.db", "/Library/Application Support/com.apple.TCC/TCC.db"),
            ("/System/Library/Frameworks/AppKit.framework/AppKit", "/System/Library/Frameworks/AppKit.framework/AppKit"),
            ("/System/Volumes/Data", "/System/Volumes/Data"),
            ("~/Library/Caches/com.apple.Safari/", "~/Library/Caches/com.apple.Safari/"),
            ("/Users/jdoe/Library/Logs/DiagnosticReports", "~/Library/Logs/DiagnosticReports"),
            ("/Users/alice/Library/Caches/com.spotify.client", "/Users/‹other user›/Library/Caches/com.spotify.client"),
            ("/Users/jdoe/Downloads/Cafe\u{0301} Menu.pdf", "~/Downloads/‹file›.pdf"),
            ("/Users/jdoe/Downloads/Zoom.app/Contents/MacOS/zoom.us", "~/Downloads/Zoom.app/Contents/MacOS/zoom.us"),
            ("/Users/jdoe/Downloads/archive.tar.gz", "~/Downloads/‹file›.tar.gz"),
            ("/Users/jdoe/.Trash/Old Budget.xlsx", "~/.Trash/‹file›.xlsx"),
            ("/Users/jdoe/Library/Developer/Xcode/DerivedData/ModuleCache.noindex",
             "~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex"),
            ("/Users/jdoe/Library/LaunchAgents/com.jdoe.backup.plist", "~/Library/LaunchAgents/com.‹user›.backup.plist"),
            ("/Library/LaunchDaemons/com.janedoe.helper.plist", "/Library/LaunchDaemons/com.‹user›.helper.plist"),
            ("/Volumes/Macintosh HD/Users/jdoe/Documents/a.txt", "/Volumes/Macintosh HD/Users/‹user›/Documents/‹file›.txt"),
            ("/Users/jdoe/My\\ Files/x.txt", "~/‹folder 10›/‹file›.txt"),
            ("Docker.raw", "Docker.raw"), ("secret.txt", "‹file›.txt"), ("node_modules", "node_modules"),
            ("/tmp/jdoe-notes.txt", "/tmp/‹file›.txt"), ("/opt/homebrew/Cellar/node/22.1.0/bin/node",
                                                          "/opt/homebrew/Cellar/node/22.1.0/bin/node"),
            ("/Users/jdoe/Projects/acme-site/src/components/Button.tsx", "~/Projects/‹project 1›/src/components/‹file›.tsx"),
            ("/Users/jdoe/Applications/Chrome Apps.localized/Gmail.app", "~/Applications/Chrome Apps.localized/Gmail.app"),
            ("/Users/jdoe/go/pkg/mod/golang.org/x/net@v0.20.0/http2/frame.go",
             "~/go/pkg/mod/golang.org/x/net@v0.20.0/http2/frame.go"),
            ("/Users/jdoe/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/0A1B2C3D-1111-2222-3333-444455556666/Draft.pdf",
             "~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/‹id 3›/‹file›.pdf"),
            ("/Users/jdoe/Library/Messages/Attachments/ab/11/IMG_4021.HEIC", "~/Library/Messages/Attachments/ab/11/‹file›.HEIC"),
        ]
        for (input, expected) in pathCases {
            let output = redactor.path(input)
            precondition(output == expected, "\(input) → \(output), expected \(expected)")
        }

        // Idempotent: redacting the redacted report changes nothing, with this redactor or a new one.
        precondition(redactor.text(safe) == safe, "not idempotent")
        var fresh = ReportRedactor(identity: identity)
        let again = fresh.text(safe)
        precondition(again == safe, "not idempotent on a new redactor:\n\(again)")
        for (input, _) in pathCases {
            let once = redactor.path(input)
            precondition(redactor.path(once) == once, "path not idempotent: \(once)")
        }

        // Cases found by fuzzing: other accounts by tilde, `..`, folder names with spaces in prose, stray backticks,
        // root folders that are not system folders, dot folders that are not tool folders.
        let textCases: [(String, String)] = [
            ("Could not read ~bob: denied.", "Could not read /Users/‹other user›: denied."),
            ("(~bob/Tax Files/a.pdf)", "(/Users/‹other user›/‹folder 11›/‹file›.pdf)"),
            ("see /Users/jdoe/Tax Files 2023 Final/a.txt today", "see ~/‹folder 12›/‹file›.txt today"),
            ("`unterminated /Users/jdoe/x.pdf", "`unterminated ~/‹file›.pdf"),
            ("- ~/Desktop/a.txt · 2 GB · file:///Users/jdoe/Desktop/b.txt", "- ~/Desktop/‹file›.txt · 2 GB · ~/Desktop/‹file›.txt"),
            ("/Volumes/Macintosh HD - Data/Users/jdoe/Smith & Co/x.pdf is big",
             "/Volumes/Macintosh HD - Data/Users/‹user›/‹folder 13›/‹file›.pdf is big"),
            ("~5 GB free, ~/x and ~ alone", "~5 GB free, ~/x and ~ alone"),
        ]
        for (input, expected) in textCases {
            let output = redactor.text(input)
            precondition(output == expected, "\(input) → \(output), expected \(expected)")
        }
        for (input, expected) in [("/Users/jdoe/../bob/Documents", "/Users/‹other user›/Documents"),
                                  ("~/../bob", "/Users/‹other user›"), ("/Projects/acme/node_modules", "/Projects/‹project 6›/node_modules"),
                                  ("~/.password-store/bank.gpg", "~/.password-store/‹file›.gpg"),
                                  ("/Volumes/Macintosh HD/Volumes/Jane Disk/a.txt", "/Volumes/Macintosh HD/Volumes/‹volume 2›/‹file›.txt"),
                                  ("/private/var/folders/zz/abc123/T/../Secret/x.txt", "/private/var/folders/‹per-user›/‹folder 14›/‹file›.txt")] {
            let output = redactor.path(input)
            precondition(output == expected, "\(input) → \(output), expected \(expected)")
        }

        // Odd input never crashes, leaks or changes on a second pass.
        let odd = ["", "/", "//", "~", "~/", "file://", "`", "``", "\"", "“", "(", ")", "|", "||", "‹", "›", "‹›", "‹user",
                   "a‹file›b", "/Users/jdoe/‹", "\r\n", "x\r\ny", "/Users/jdoe/😀 Folder/👍.png", "~jdoe", "~jdoe/x",
                   "**/Users/jdoe/x**", "[link](/Users/jdoe/Projects/a/b.md)", "/Users/jdoe/x.", "/Users/jdoe/..",
                   "https://github.com/jdoe/repo", "mailto:jdoe@example.com", "| `/Users/jdoe/a|b.txt` | 1 GB |",
                   String(repeating: "/a", count: 2_000), String(repeating: "x", count: 10_000) + " /Users/jdoe/y"]
        // Random paths from personal, other-user, volume and temporary roots, in every way a report quotes them.
        var seed: UInt64 = 0x5EED
        func random(_ count: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(count))
        }
        let roots = ["/Users/jdoe", "~", "/System/Volumes/Data/Users/jdoe", "file:///Users/jdoe", "/Users/bob", "~bob",
                     "/Volumes/Jane Disk", "/private/var/folders/zz/abc123/T", "/tmp", "/Users/Shared",
                     "/Volumes/Macintosh HD/Users/jdoe"]
        // No dependency folders here: package names inside node_modules are public and kept on purpose.
        let names = ["Projects", "acme site", "Documents", "Taxes 2023", "notes.txt", "Smith & Co",
                     "Jane’s Stuff", "jdoe-files", "build", "Debug", "Desktop", "Mobile Documents", "CloudStorage",
                     "GoogleDrive-jane@x.com", "DerivedData", "Acme-abcdefghijklmnopqrstuvwxyzab", ".git", "ab", "Users",
                     "Macintosh HD - Data", "C02XK0ABJGH5", "..", ".", "My Drive", "résumé.pdf", "日本語", "x.tar.gz",
                     "a b c d e f", "README.md", "target", ".Trash", "Developer", "12345678-90AB-CDEF-1234-567890ABCDEF"]
        var generated: [String] = []
        for trial in 0..<600 {
            var path = roots[random(roots.count)]
            for _ in 0..<random(7) { path += "/" + names[random(names.count)] }
            let quoted = ["`\(path)`", "| `\(path)` | 1.2 GB |", "| \(path) | 3 GB |", "Could not read \(path): denied.",
                          "(\(path))", "link to \(path).", "“\(path)”", "- \(path) · 2 GB · file://\(path)"]
            generated.append(quoted[trial % quoted.count])
        }
        for input in odd + generated {
            var first = ReportRedactor(identity: identity)
            let once = first.text(input)
            var second = ReportRedactor(identity: identity)
            precondition(second.text(once) == once, "not idempotent: \(input) → \(once)")
            precondition(input.filter { $0 == "|" }.count == once.filter { $0 == "|" }.count, "pipes: \(once)")
            let lowered = once.lowercased()
            for secret in ["jdoe", "jane", "bob", "acme", "taxes", "smith", "c02xk0", "12345678-90ab", "résumé", "日本語", "abc123"] {
                precondition(!lowered.contains(secret), "\(secret) survived: \(input) → \(once)")
            }
        }

        // Plain text passes through untouched.
        let plain = "- 1.2 GB used of 2 TB; 800 GB free · 93% · 12,345 files · Nov 6, 2026 · 4 GB / 10 GB · 50 MB/s · Critical"
        precondition(redactor.text(plain) == plain, redactor.text(plain))

        // The header says what was redacted and is itself stable.
        let header = ReportRedactor.privacySafeHeader()
        precondition(header.contains("‹user›") && header.contains("‹project 1›") && header.contains("‹id›")
                     && header.contains("bundle identifiers"))
        precondition(redactor.text(header) == header, "header changes when redacted")
        var reporter = ReportRedactor(identity: identity)
        let report = reporter.report(fixture)
        precondition(report.hasPrefix("# Mac Polish deep scan report\n\n> **Privacy-safe report.**"), report)
        precondition(!report.lowercased().contains("jdoe"))

        // Generic host names are not redacted (they would erase model names).
        var generic = ReportRedactor(identity: .init(home: "/Users/sam", userName: "sam", fullName: "Sam",
                                                     hostNames: ["MacBook-Pro.local", "MacBook Pro"]))
        precondition(generic.text("Model: MacBook Pro") == "Model: MacBook Pro")

        // Performance: a 5,000-line report.
        var lines: [String] = ["| File | Size | Modified |", "| --- | ---: | --- |"]
        for index in 0..<5_000 {
            switch index % 5 {
            case 0: lines.append("| `/Users/jdoe/Projects/project\(index % 300)/node_modules/pkg\(index)/index.js` | \(index) MB | Nov 6, 2026 |")
            case 1: lines.append("| `/Users/jdoe/Documents/Folder \(index % 97)/Report \(index).pdf` | 1.\(index % 10) GB | — |")
            case 2: lines.append("- `com.jdoe.agent\(index)` (The script it runs (/Users/jdoe/bin/run\(index).sh) is not covered by it.)")
            case 3: lines.append("| `/Users/jdoe/Library/Caches/com.vendor.app\(index)/data.db` | \(index) KB | — |")
            default: lines.append("Contact jane.doe@example.com about C02XK0ABJGH5 on Janes-MacBook-Pro: 93% used, \(index) files.")
            }
        }
        let big = lines.joined(separator: "\n")
        var timed = ReportRedactor(identity: identity)
        let started = Date()
        let bigSafe = timed.text(big)
        let elapsed = Date().timeIntervalSince(started)
        // A sanity bound for unoptimised builds on slow CI runners (about 0.15 s locally); a quadratic redactor
        // would take minutes. Exact performance budgets belong in Scripts/perf.sh.
        precondition(elapsed < 10, "5,000 lines took \(elapsed) s")
        precondition(!bigSafe.lowercased().contains("jdoe") && !bigSafe.contains("C02XK0ABJGH5"))
        precondition(bigSafe.contains("~/Projects/‹project 1›/node_modules/pkg0/index.js"))
        precondition(bigSafe.contains("~/Projects/‹project 1›/node_modules/pkg1500/index.js"), "project alias not stable")

        // The live account: its user name and home never survive.
        let live = ReportRedactor.Identity.current()
        var liveRedactor = ReportRedactor(identity: live)
        let liveText = "\(live.userName) · \(live.home)/Documents/x.txt · file://\(live.home)/Desktop/a%20b.txt · "
            + "`\(live.home)/Projects/demo/node_modules` · /System/Volumes/Data\(live.home)/Library/Caches"
        let liveSafe = liveRedactor.text(liveText)
        let withoutAliases = liveSafe.replacingOccurrences(of: "‹[^›]*›", with: "", options: .regularExpression)
        precondition(live.userName.isEmpty || !withoutAliases.contains(live.userName), "live user name survived: \(liveSafe)")
        precondition(!liveSafe.contains(live.home + "/"), "live home survived: \(liveSafe)")
        precondition(liveSafe.contains("~/Documents/‹file›.txt") && liveSafe.contains("~/Library/Caches"), liveSafe)

        print("PASS ReportPrivacyCheck: fixture redacted, aliases stable, tables intact, idempotent, "
              + "5,000 lines in \(Int((elapsed * 1000).rounded())) ms, live account redacted")
    }
}
