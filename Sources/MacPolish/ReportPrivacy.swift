import Darwin
import Foundation

/// Rewrites report text and file paths so a report can be shared without identifying the person or the Mac.
///
/// The home folder becomes `~`; the account name, full name and computer name become `‹user›` and `‹host›`; other
/// accounts become `‹other user›`; personal folder, project and volume names become numbered aliases (`‹project 1›`,
/// `‹folder 2›`, `‹volume 1›`) numbered in the order they are first seen; personal file names become `‹file›` with
/// their extension; e-mail addresses, serial numbers and hardware or device identifiers are removed. What helps a
/// diagnosis stays readable: system locations, app names, bundle identifiers, `~/Library` structure, developer tool,
/// dependency and build folder names, sizes, counts, dates and findings.
///
/// Use one redactor per report, so the same folder gets the same alias everywhere in it. Redaction never touches the
/// file system and is idempotent: redacting text that is already redacted changes nothing.
struct ReportRedactor: Sendable {
    struct Identity: Sendable, Equatable {
        var home: String
        var userName: String
        var fullName: String
        var hostNames: [String]

        init(home: String, userName: String, fullName: String, hostNames: [String] = []) {
            self.home = home
            self.userName = userName
            self.fullName = fullName
            self.hostNames = hostNames
        }

        /// The signed-in account and this Mac. No network lookups: the host name comes from `gethostname`, the
        /// computer name ("Jane’s MacBook Pro") from `Host`, the home folder from the account database.
        static func current() -> Identity {
            var hosts: [String] = []
            var buffer = [CChar](repeating: 0, count: 256)
            if gethostname(&buffer, buffer.count - 1) == 0 {
                let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !name.isEmpty { hosts.append(name) }
            }
            if let name = Host.current().localizedName, !name.isEmpty { hosts.append(name) }
            // The account's real home, also when the process runs inside a sandbox container.
            var home = NSHomeDirectory()
            if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
                let path = String(cString: directory)
                if !path.isEmpty { home = path }
            }
            return Identity(home: home, userName: NSUserName(), fullName: NSFullUserName(), hostNames: hosts)
        }
    }

    let identity: Identity
    private let matchers: Matchers
    /// Alias of each personal folder, keyed by its normalized original path (`~/projects/acme`).
    private var aliases: [String: String] = [:]
    /// Project aliases by lowercased folder name, so DerivedData folders and build products named after a project
    /// show that project's alias.
    private var projectNames: [String: String] = [:]
    private var identifiers: [String: String] = [:]
    private var counters: [String: Int] = [:]

    init(identity: Identity = .current()) {
        self.identity = identity
        matchers = Matchers(identity)
    }

    /// A path safe to share. Accepts absolute paths (also below `/System/Volumes/Data`), `~` paths, `file://` URLs
    /// and relative paths; keeps a trailing slash.
    mutating func path(_ path: String) -> String {
        scrub(redactPath(path.precomposedStringWithCanonicalMapping))
    }

    /// Free text or Markdown: redacts embedded paths (in backticks, quotes, parentheses, table cells or bare),
    /// e-mail addresses, serial numbers, hardware identifiers and the user, full and host names. Sizes, counts,
    /// dates, percentages, severity words, table pipes and backticks are left as they are.
    mutating func text(_ text: String) -> String {
        let lines = text.precomposedStringWithCanonicalMapping.components(separatedBy: "\n")
        var redacted: [String] = []
        redacted.reserveCapacity(lines.count)
        for line in lines { redacted.append(redactLine(line)) }
        return scrub(redacted.joined(separator: "\n"))
    }

    /// A whole Markdown report, redacted, with `privacySafeHeader()` after its first heading.
    mutating func report(_ markdown: String) -> String {
        let body = text(markdown)
        let header = Self.privacySafeHeader()
        guard body.hasPrefix("# "), let end = body.firstIndex(of: "\n") else { return header + "\n\n" + body }
        return String(body[..<end]) + "\n\n" + header + "\n" + body[end...]
    }

    /// Markdown that says what a privacy-safe report leaves out and what it keeps.
    static func privacySafeHeader() -> String {
        """
        > **Privacy-safe report.** Your home folder is shown as `~`. Your account name, full name and computer name \
        are replaced with ‹user› and ‹host›, other accounts with ‹other user›. Names of personal folders, projects \
        and volumes are replaced with numbered aliases such as ‹project 1›, ‹folder 1› and ‹volume 1›, which stay \
        the same throughout this report. Personal file names are replaced with ‹file› (the extension is kept). \
        E-mail addresses, serial numbers and hardware or device identifiers are replaced with ‹email›, ‹serial› \
        and numbered ‹id› aliases.
        >
        > Kept for diagnosis: system locations, app names, bundle identifiers, Library folders, developer tool, \
        dependency and build folder names, sizes, counts, dates and findings. These can still show which apps and \
        tools are installed. Review the report before you share it.
        """
    }

    // MARK: Paths

    private struct Context: Equatable {
        /// Children are project folders (the folder is ~/Projects, ~/Developer, …).
        var projects = false
        /// Inside a build output folder: product names may be project names.
        var artifact = false
        var inProject = false
    }

    private enum Mode: Equatable {
        /// Names are installed software or system structure: kept.
        case system
        /// Inside a Library folder: app-defined names kept, personal subtrees (Mail, iCloud Drive, …) redacted.
        case library
        /// The first level of a home folder.
        case homeTop
        /// Names the person chose: kept only when well known.
        case personal(Context)
        /// The next name is an iCloud container (`com~apple~CloudDocs`).
        case iCloudContainer
        /// The next name is a cloud provider and account (`GoogleDrive-jane@example.com`).
        case cloudAccount
        /// The next name is an Xcode DerivedData folder (`Acme-gbxyz…`).
        case derivedData
    }

    private mutating func redactPath(_ raw: String) -> String {
        var start = raw.startIndex
        var end = raw.endIndex
        while start < end, raw[start].isWhitespace { start = raw.index(after: start) }
        while end > start, raw[raw.index(before: end)].isWhitespace { end = raw.index(before: end) }
        guard start < end else { return raw }
        var path = String(raw[start..<end])
        if path.utf8.count >= 7, path.prefix(7).lowercased() == "file://" {
            path.removeFirst(7)
            if path.lowercased().hasPrefix("localhost/") { path.removeFirst(9) }
            path = path.removingPercentEncoding ?? path
        }
        if path.contains("\\ ") { path = path.replacingOccurrences(of: "\\ ", with: " ") }
        let trailingSlash = path.count > 1 && path.hasSuffix("/")
        // `~` and `~name` become absolute, so every spelling of a folder takes the same route (and the same alias).
        if path == "~" || path.hasPrefix("~/") {
            path = (matchers.home.isEmpty ? "/Users/‹user›" : matchers.home) + path.dropFirst()
        } else if path.hasPrefix("~") {
            path = "/Users/" + path.dropFirst()
        }
        var components = path.split(separator: "/").map(String.init)[...]
        if components.contains(where: { $0 == "." || $0 == ".." }) {
            // Resolved by name only, so `..` cannot climb out of a redacted folder into a kept one.
            var resolved: [String] = []
            for name in components where name != "." {
                if name == "..", let last = resolved.last, last != ".." {
                    resolved.removeLast()
                } else if name != ".." || !path.hasPrefix("/") {
                    resolved.append(name)
                }
            }
            components = resolved[...]
        }
        var out: [String] = []
        let body: String
        if path.hasPrefix("/") {
            if components.count > 3, components.prefix(3).map({ $0.lowercased() }) == ["system", "volumes", "data"] {
                components = components.dropFirst(3)
            }
            let isHome = walkRoot(components, nested: false, base: "", unknown: .system, into: &out)
            body = isHome ? (["~"] + out).joined(separator: "/") : "/" + out.joined(separator: "/")
        } else {
            walk(components, mode: .personal(Context()), key: "", into: &out)
            body = out.joined(separator: "/")
        }
        let result = trailingSlash && !body.hasSuffix("/") ? body + "/" : body
        return String(raw[..<start]) + result + String(raw[end...])
    }

    /// Walks an absolute path. Returns true when the result is relative to the current home (`~`).
    private mutating func walkRoot(_ components: ArraySlice<String>, nested: Bool, base: String, unknown: Mode,
                                   into out: inout [String]) -> Bool {
        guard let first = components.first else { return false }
        let lower = first.lowercased()
        let rest = components.dropFirst()
        if let below = matchers.dropHome(components) {
            if nested { out += components.prefix(matchers.homeComponents.count - 1) + ["‹user›"] }
            walk(below, mode: .homeTop, key: "~", into: &out)
            return !nested
        }
        switch lower {
        case "users":
            out.append(first)
            guard let name = rest.first else { return false }
            let nameLower = name.lowercased()
            let below = rest.dropFirst()
            if nameLower == "shared" {
                out.append(name)
                walk(below, mode: .personal(Context()), key: base + "/users/shared", into: &out)
            } else if name == "‹user›" || matchers.isSelf(nameLower) {
                if nested { out.append("‹user›") } else { out.removeLast() }
                walk(below, mode: .homeTop, key: "~", into: &out)
                return !nested
            } else if Self.isDotName(name) {
                out.append(name)
                walk(below, mode: .personal(Context()), key: base + "/users/" + nameLower, into: &out)
            } else {
                out.append(Self.containsAlias(name) ? name : "‹other user›")
                walk(below, mode: .homeTop, key: base + "/users/" + nameLower, into: &out)
            }
        case "volumes":
            out.append(first)
            guard let name = rest.first else { return false }
            let key = "/volumes/" + name.lowercased()
            if Self.containsAlias(name) {
                out.append(name)
                _ = walkRoot(rest.dropFirst(), nested: true, base: key, unknown: .personal(Context()), into: &out)
            } else if Names.systemVolumes.contains(name.lowercased()) || Self.isBundleIdentifier(name) {
                out.append(name)
                _ = walkRoot(rest.dropFirst(), nested: true, base: key, unknown: .system, into: &out)
            } else {
                out.append(alias(for: key, kind: "volume"))
                _ = walkRoot(rest.dropFirst(), nested: true, base: key, unknown: .personal(Context()), into: &out)
            }
        case "private", "network":
            out.append(first)
            _ = walkRoot(rest, nested: true, base: base + "/" + lower, unknown: .system, into: &out)
        case "tmp":
            out.append(first)
            walk(rest, mode: .personal(Context()), key: base + "/tmp", into: &out)
        case "var":
            out.append(first)
            guard let second = rest.first else { return false }
            let key = base + "/var/" + second.lowercased()
            switch second.lowercased() {
            case "tmp":
                out.append(second)
                walk(rest.dropFirst(), mode: .personal(Context()), key: key, into: &out)
            case "folders":
                // /var/folders/<bucket>/<per-user id>/{T,C,0}: the two names identify the account.
                out.append(second)
                var below = rest.dropFirst()
                if let name = below.first, Self.containsAlias(name) {
                    out.append(name)
                    below = below.dropFirst()
                } else if !below.isEmpty {
                    out.append("‹per-user›")
                    below = below.dropFirst(min(2, below.count))
                }
                if let kind = below.first, ["T", "C", "0", "X"].contains(kind) {
                    out.append(kind)
                    // C (caches) and 0 hold app data by bundle identifier; T and X hold temporary files.
                    walk(below.dropFirst(), mode: kind == "C" || kind == "0" ? .library : .personal(Context()),
                         key: key + "/" + kind.lowercased(), into: &out)
                } else {
                    walk(below, mode: .personal(Context()), key: key, into: &out)
                }
            default:
                walk(rest, mode: .system, key: base + "/var", into: &out)
            }
        default:
            // Only the folders macOS and package managers put at the root are system structure.
            let isSystem = Names.systemRoots.contains(lower) || Self.isDotName(first)
            walk(components, mode: unknown == .system && !isSystem ? .personal(Context()) : unknown, key: base, into: &out)
        }
        return false
    }

    private mutating func walk(_ components: ArraySlice<String>, mode start: Mode, key base: String,
                               into out: inout [String]) {
        var mode = start
        var key = base
        var previous = ""
        var beforePrevious = ""
        for index in components.indices {
            let name = components[index]
            let lower = name.lowercased()
            let next = index + 1 < components.endIndex ? components[index + 1] : nil
            key += "/" + lower
            // A home folder inside a backup or a copy of a startup disk: …/Macintosh HD - Data/Users/<name>.
            let isHomeName = previous == "users" && Names.systemVolumes.contains(beforePrevious)
            defer { beforePrevious = previous; previous = lower }
            if Self.containsAlias(name) {
                out.append(name)
                if isHomeName {
                    mode = .homeTop
                    if name == "‹user›" { key = "~" }
                    continue
                }
                switch mode {
                case .homeTop, .iCloudContainer, .cloudAccount: mode = .personal(Context())
                case .derivedData: mode = .personal(Context(artifact: true, inProject: true))
                case .personal(let context):
                    mode = .personal(Context(artifact: context.artifact,
                                             inProject: context.inProject || name.hasPrefix("‹project")))
                case .system, .library: break
                }
                continue
            }
            switch mode {
            case .system:
                out.append(name)
            case .library:
                out.append(name)
                switch lower {
                case "mobile documents": mode = .iCloudContainer
                case "cloudstorage": mode = .cloudAccount
                case "deriveddata": mode = .derivedData
                case "archives" where previous == "xcode": mode = .personal(Context())
                default: if Names.personalInLibrary.contains(lower) { mode = .personal(Context()) }
                }
            case .iCloudContainer:
                out.append(name)
                mode = .personal(Context())
            case .cloudAccount:
                if let dash = name.firstIndex(of: "-") { out.append(name[..<dash] + "-‹account›") } else { out.append(name) }
                mode = .personal(Context())
            case .derivedData:
                out.append(derivedDataName(name, lower: lower, key: key))
                mode = .personal(Context(artifact: true, inProject: true))
            case .homeTop:
                if lower == "library" {
                    out.append(name)
                    mode = .library
                } else if Self.isDotName(name) {
                    // Tool folders (.npm, .cargo, .docker, …) hold caches and settings; others, such as the Trash,
                    // can hold your own files.
                    out.append(name)
                    mode = Names.toolFolders.contains(lower) ? .system : .personal(Context())
                } else if Names.homeFolders.contains(lower) || Names.devContainers.contains(lower) {
                    out.append(name)
                    mode = .personal(Context(projects: Names.devContainers.contains(lower)))
                } else {
                    let (output, nextMode) = personal(name, lower: lower, next: next, context: Context(), key: key)
                    out.append(output)
                    mode = nextMode
                }
            case .personal(let context):
                if isHomeName {
                    if matchers.isSelf(lower) {
                        out.append("‹user›")
                        key = "~"
                    } else {
                        out.append("‹other user›")
                    }
                    mode = .homeTop
                    continue
                }
                let (output, nextMode) = personal(name, lower: lower, next: next, context: context, key: key)
                out.append(output)
                mode = nextMode
            }
        }
    }

    /// One name in a folder the person organizes: kept when it is well known, otherwise an alias.
    private mutating func personal(_ name: String, lower: String, next: String?, context: Context,
                                   key: String) -> (String, Mode) {
        var child = context
        child.projects = false
        if !context.artifact, Self.isBundle(lower) { return (name, .system) }
        if Names.dependencies.contains(lower) { return (name, .system) }
        if Self.isArtifactFolder(lower) {
            child.artifact = true
            return (name, .personal(child))
        }
        if !context.inProject, !context.artifact, Names.devContainers.contains(lower) {
            child.projects = true
            return (name, .personal(child))
        }
        if Self.isKept(name, lower: lower) { return (name, .personal(child)) }
        if let alias = aliases[key] {
            if alias.hasPrefix("‹project") { child.inProject = true }
            return (alias, .personal(child))
        }
        let parts = Self.splitExtension(name)
        let suffix = parts.map { "." + $0.ext } ?? ""
        let stem = parts.map { $0.stem.lowercased() } ?? lower
        if context.artifact, let project = projectNames[stem] { return (project + suffix, .personal(child)) }
        if next == nil, parts != nil { return ("‹file›" + suffix, .personal(child)) }
        let isProject = !context.artifact && !context.inProject && (context.projects || Self.isProjectContent(next))
        let alias = alias(for: key, kind: isProject ? "project" : "folder", suffix: suffix)
        if isProject {
            child.inProject = true
            if projectNames[stem] == nil { projectNames[stem] = String(alias.dropLast(suffix.count)) }
        }
        return (alias, .personal(child))
    }

    /// `Acme-gbxyzw…` becomes the project's alias; the hash is dropped because it is derived from the project path.
    private mutating func derivedDataName(_ name: String, lower: String, key: String) -> String {
        if lower.hasSuffix(".noindex") || Self.isKept(name, lower: lower) { return name }
        var stem = lower
        if let dash = lower.lastIndex(of: "-") {
            let hash = lower[lower.index(after: dash)...]
            if hash.count >= 20, hash.allSatisfy({ $0 >= "a" && $0 <= "z" }) { stem = String(lower[..<dash]) }
        }
        if let project = projectNames[stem] { return project }
        let project = alias(for: key, kind: "project")
        projectNames[stem] = project
        return project
    }

    private mutating func alias(for key: String, kind: String, suffix: String = "") -> String {
        if let existing = aliases[key] { return existing }
        let number = (counters[kind] ?? 0) + 1
        counters[kind] = number
        let alias = "‹\(kind) \(number)›" + suffix
        aliases[key] = alias
        return alias
    }

    // MARK: Name rules

    static func containsAlias(_ name: String) -> Bool {
        name.contains("‹") && Patterns.alias.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static func isDotName(_ name: String) -> Bool {
        guard name.utf8.count >= 2, name.utf8.first == UInt8(ascii: ".") else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }

    private static func isBundle(_ lower: String) -> Bool {
        guard let dot = lower.lastIndex(of: "."), dot > lower.startIndex else { return false }
        return Names.bundleExtensions.contains(String(lower[lower.index(after: dot)...]))
    }

    private static func isArtifactFolder(_ lower: String) -> Bool {
        Names.artifacts.contains(lower) || lower.hasPrefix("cmake-build-")
    }

    private static func isProjectContent(_ next: String?) -> Bool {
        guard let lower = next?.lowercased() else { return false }
        return Names.projectMarkers.contains(lower) || isArtifactFolder(lower) || Names.dependencies.contains(lower)
            || lower.hasSuffix(".xcodeproj") || lower.hasSuffix(".xcworkspace")
    }

    static func isBundleIdentifier(_ name: String) -> Bool {
        Patterns.bundleIdentifier.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// Names that say nothing about the person: well-known files and folders, tool folders, bundle identifiers,
    /// numbers, dates, versions, hashes and build configurations.
    private static func isKept(_ name: String, lower: String) -> Bool {
        if lower.count == 1 || Names.wellKnown.contains(lower) || isDotName(name) || lower.hasSuffix(".localized") {
            return true
        }
        let isHex = lower.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        // Two-character hex shards (`ab/11/…`) in caches, attachments and git objects.
        if isHex, lower.utf8.count == 2 { return true }
        if lower.utf8.contains(where: { $0 >= 0x30 && $0 <= 0x39 }) {
            let body = lower.hasPrefix("v") ? lower.dropFirst() : Substring(lower)
            // Numbers, dates, times and versions: 2023, 2026-11-01-120000, v18.17.0.
            if body.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F || $0 == 0x20 || $0 == 0x3A }) {
                return true
            }
            if isHex { return true }
            if Patterns.identifier.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))?.range.length == name.utf16.count {
                return true
            }
        }
        if Patterns.structural.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil { return true }
        return isBundleIdentifier(name)
    }

    /// `name.tar.gz` → (`name`, `tar.gz`). An extension is 1–10 ASCII letters or digits with at least one letter.
    private static func splitExtension(_ name: String) -> (stem: String, ext: String)? {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ext.contains(where: \.isLetter) else { return nil }
        let stem = name[..<dot]
        if let inner = stem.lastIndex(of: "."), inner > stem.startIndex, stem[stem.index(after: inner)...].lowercased() == "tar" {
            return (String(stem[..<inner]), "tar." + ext)
        }
        return (String(stem), String(ext))
    }

    /// A file or folder name quoted in a message, such as the one in “The file “X” couldn’t be opened”.
    private static func quotedName(_ content: String, folder: Bool) -> String {
        let lower = content.lowercased()
        if containsAlias(content) || isBundle(lower) || isKept(content, lower: lower) { return content }
        if let parts = splitExtension(content) { return "‹file›." + parts.ext }
        return folder ? "‹folder›" : "‹file›"
    }

    // MARK: Text

    private mutating func redactLine(_ line: String) -> String {
        guard line.utf8.contains(where: { $0 == Byte.slash || $0 == Byte.tilde || $0 == Byte.quote || $0 == 0xE2 }) else {
            return line
        }
        let bytes = Array(line.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 32)
        var first = 0
        while first < bytes.count, bytes[first] == Byte.space || bytes[first] == Byte.tab { first += 1 }
        if first < bytes.count, bytes[first] == Byte.pipe {
            // A table row: each cell on its own, so pipes stay where they are.
            var cellStart = 0
            for index in 0...bytes.count where index == bytes.count || bytes[index] == Byte.pipe {
                let cell = cellStart..<index
                let trimmed = Self.trim(bytes, cell)
                if Self.startsPath(bytes, trimmed) {
                    out += bytes[cell.lowerBound..<trimmed.lowerBound]
                    out += redactPath(String(decoding: bytes[trimmed], as: UTF8.self)).utf8
                    out += bytes[trimmed.upperBound..<cell.upperBound]
                } else {
                    scan(bytes, cell, into: &out)
                }
                if index < bytes.count { out.append(Byte.pipe) }
                cellStart = index + 1
            }
        } else {
            scan(bytes, 0..<bytes.count, into: &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Prose: code spans, quotes, parentheses and bare paths.
    private mutating func scan(_ b: [UInt8], _ range: Range<Int>, into out: inout [UInt8]) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            let c = b[i]
            if c == Byte.backtick, let close = Self.find(Byte.backtick, in: b, from: i + 1, to: end) {
                out.append(c)
                let inner = (i + 1)..<close
                let trimmed = Self.trim(b, inner)
                if Self.startsPath(b, trimmed) {
                    out += b[inner.lowerBound..<trimmed.lowerBound]
                    out += redactPath(String(decoding: b[trimmed], as: UTF8.self)).utf8
                    out += b[trimmed.upperBound..<inner.upperBound]
                } else {
                    scan(b, inner, into: &out)
                }
                out.append(c)
                i = close + 1
                continue
            }
            if let quote = Self.openingQuote(b, at: i, end: end) {
                let contentStart = i + quote.open
                if let close = Self.find(quote.close, in: b, from: contentStart, to: end) {
                    let inner = contentStart..<close
                    let content = String(decoding: b[inner], as: UTF8.self)
                    var replacement: String?
                    if Self.startsPath(b, inner) {
                        replacement = redactPath(content)
                    } else if !content.contains("/"), content.utf8.count <= 255 {
                        let noun = Self.wordBefore(b, at: i, start: range.lowerBound)
                        if Names.fileNouns.contains(noun) {
                            replacement = Self.quotedName(content, folder: noun == "folder" || noun == "directory")
                        } else if let parts = Self.splitExtension(content), parts.ext.count >= 2,
                                  !content.hasPrefix(" "), !content.hasSuffix(" "), !content.contains(". ") {
                            replacement = Self.quotedName(content, folder: false)
                        }
                    }
                    if let replacement {
                        out += b[i..<contentStart]
                        out += replacement.utf8
                        out += quote.close
                        i = close + quote.close.count
                        continue
                    }
                }
                out += b[i..<contentStart]
                i = contentStart
                continue
            }
            if c == Byte.openParen {
                var j = i + 1
                while j < end, b[j] != Byte.closeParen, b[j] != Byte.openParen { j += 1 }
                if j < end, b[j] == Byte.closeParen {
                    let inner = (i + 1)..<j
                    if Self.startsPath(b, inner), !Self.containsListSeparator(b, inner) {
                        out.append(c)
                        out += redactPath(String(decoding: b[inner], as: UTF8.self)).utf8
                        out.append(Byte.closeParen)
                        i = j + 1
                        continue
                    }
                }
            }
            if Self.isPathStart(b, at: i, start: range.lowerBound, end: end) {
                let pathEnd = Self.pathEnd(b, from: i, to: end)
                if pathEnd > i {
                    out += redactPath(String(decoding: b[i..<pathEnd], as: UTF8.self)).utf8
                    i = pathEnd
                    continue
                }
            }
            out.append(c)
            i += 1
        }
    }

    private enum Byte {
        static let slash = UInt8(ascii: "/"), tilde = UInt8(ascii: "~"), quote = UInt8(ascii: "\""),
                   backtick = UInt8(ascii: "`"), pipe = UInt8(ascii: "|"), space = UInt8(ascii: " "),
                   tab = UInt8(ascii: "\t"), openParen = UInt8(ascii: "("), closeParen = UInt8(ascii: ")"),
                   backslash = UInt8(ascii: "\\")
        static let leftDoubleQuote: [UInt8] = [0xE2, 0x80, 0x9C], rightDoubleQuote: [UInt8] = [0xE2, 0x80, 0x9D]
    }

    private static func trim(_ b: [UInt8], _ range: Range<Int>) -> Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, b[lower] == Byte.space || b[lower] == Byte.tab { lower += 1 }
        while upper > lower, b[upper - 1] == Byte.space || b[upper - 1] == Byte.tab { upper -= 1 }
        return lower..<upper
    }

    private static func find(_ byte: UInt8, in b: [UInt8], from start: Int, to end: Int) -> Int? {
        var i = start
        while i < end { if b[i] == byte { return i }; i += 1 }
        return nil
    }

    private static func find(_ sequence: [UInt8], in b: [UInt8], from start: Int, to end: Int) -> Int? {
        guard sequence.count > 1 else { return sequence.first.flatMap { find($0, in: b, from: start, to: end) } }
        var i = start
        while i + sequence.count <= end {
            if b[i] == sequence[0], has(sequence, in: b, at: i, end: end) { return i }
            i += 1
        }
        return nil
    }

    private static func has(_ sequence: [UInt8], in b: [UInt8], at i: Int, end: Int) -> Bool {
        guard i >= 0, i + sequence.count <= end else { return false }
        for (offset, byte) in sequence.enumerated() where b[i + offset] != byte { return false }
        return true
    }

    private static func openingQuote(_ b: [UInt8], at i: Int, end: Int) -> (open: Int, close: [UInt8])? {
        if b[i] == Byte.quote { return (1, [Byte.quote]) }
        if b[i] == 0xE2, has(Byte.leftDoubleQuote, in: b, at: i, end: end) { return (3, Byte.rightDoubleQuote) }
        return nil
    }

    /// The lowercased word just before position `i` (skipping one space), for “file “X”” and “folder “X””.
    private static func wordBefore(_ b: [UInt8], at i: Int, start: Int) -> String {
        var j = i
        if j > start, b[j - 1] == Byte.space { j -= 1 }
        var k = j
        while k > start, (b[k - 1] | 0x20) >= 0x61, (b[k - 1] | 0x20) <= 0x7A { k -= 1 }
        return String(decoding: b[k..<j], as: UTF8.self).lowercased()
    }

    private static func containsListSeparator(_ b: [UInt8], _ range: Range<Int>) -> Bool {
        var i = range.lowerBound
        while i + 1 < range.upperBound {
            if (b[i] == UInt8(ascii: ",") || b[i] == UInt8(ascii: ";")) && b[i + 1] == Byte.space { return true }
            i += 1
        }
        return false
    }

    private static func isPathCharacter(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A) || byte >= 0x80
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
            || byte == Byte.tilde || byte == UInt8(ascii: "@")
    }

    private static func hasFileScheme(_ b: [UInt8], at i: Int, end: Int) -> Bool {
        guard i + 7 <= end else { return false }
        let scheme: [UInt8] = Array("file://".utf8)
        for offset in 0..<7 where (b[i + offset] | (offset < 4 ? 0x20 : 0)) != scheme[offset] { return false }
        return true
    }

    /// A path that fills a code span, quote, parenthesis or table cell.
    private static func startsPath(_ b: [UInt8], _ range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        let c = b[range.lowerBound]
        if c == Byte.slash { return range.count == 1 || isPathCharacter(b[range.lowerBound + 1]) }
        if c == Byte.tilde {
            // `~`, `~/…`, or another account's `~name` / `~name/…`.
            var j = range.lowerBound + 1
            guard j < range.upperBound, b[j] != Byte.slash else { return true }
            guard (b[j] | 0x20) >= 0x61, (b[j] | 0x20) <= 0x7A else { return false }
            while j < range.upperBound, isPathCharacter(b[j]), b[j] < 0x80, b[j] != Byte.tilde { j += 1 }
            return j == range.upperBound || b[j] == Byte.slash
        }
        return hasFileScheme(b, at: range.lowerBound, end: range.upperBound)
    }

    private static func isPathStart(_ b: [UInt8], at i: Int, start: Int, end: Int) -> Bool {
        let c = b[i]
        guard c == Byte.slash || c == Byte.tilde || c == UInt8(ascii: "f") || c == UInt8(ascii: "F") else { return false }
        if i > start {
            let previous = b[i - 1]
            let boundary = previous == Byte.space || previous == Byte.tab
                || "([{<=:,;'\"*|>`".utf8.contains(previous)
                || has([0xE2, 0x80, 0x9C], in: b, at: i - 3, end: end) || has([0xE2, 0x80, 0x98], in: b, at: i - 3, end: end)
            guard boundary else { return false }
        }
        if c == Byte.slash { return i + 1 < end && isPathCharacter(b[i + 1]) }
        if c == Byte.tilde {
            // `~/…`, or another account's `~name/…` (not `~5 GB`).
            var j = i + 1
            guard j < end else { return false }
            if b[j] == Byte.slash { return true }
            guard (b[j] | 0x20) >= 0x61, (b[j] | 0x20) <= 0x7A else { return false }
            while j < end, isPathCharacter(b[j]), b[j] < 0x80, b[j] != Byte.tilde { j += 1 }
            if j < end, b[j] == Byte.slash { return true }
            // A bare `~name` ends at white space or punctuation; trailing dots belong to the sentence.
            while j > i + 1, b[j - 1] == UInt8(ascii: ".") { j -= 1 }
            return j == end || !(b[j] >= 0x80 || (b[j] | 0x20) >= 0x61 && (b[j] | 0x20) <= 0x7A || b[j] == Byte.backslash)
        }
        return hasFileScheme(b, at: i, end: end)
    }

    /// Where a bare path ends: at white space (unless the next word goes on to deeper folders), a table pipe,
    /// a backtick, a quote, an unbalanced bracket, or a comma, semicolon or colon followed by a space.
    private static func pathEnd(_ b: [UInt8], from start: Int, to end: Int) -> Int {
        var j = start
        var parens = 0
        var brackets = 0
        scanning: while j < end {
            let c = b[j]
            switch c {
            case Byte.backslash where j + 1 < end && b[j + 1] == Byte.space:
                j += 2
                continue
            case 0xE2 where has([0xE2, 0x80, 0xB9], in: b, at: j, end: end):
                // An alias such as ‹project 1›, which contains a space.
                if let close = find([0xE2, 0x80, 0xBA], in: b, from: j + 3, to: end) { j = close + 3; continue }
                j += 3
                continue
            case 0xE2 where has([0xE2, 0x80, 0x9C], in: b, at: j, end: end) || has([0xE2, 0x80, 0x9D], in: b, at: j, end: end)
                || has([0xE2, 0x80, 0x98], in: b, at: j, end: end):
                break scanning
            case 0xE2 where has([0xE2, 0x80, 0x99], in: b, at: j, end: end):
                // ’ is an apostrophe inside a name (Jane’s Files) but closes a quote before a non-letter.
                if j + 3 >= end || !((b[j + 3] | 0x20) >= 0x61 && (b[j + 3] | 0x20) <= 0x7A) { break scanning }
                j += 3
                continue
            case Byte.space:
                if continuesPath(b, from: j + 1, to: end) { j += 1; continue }
                break scanning
            case Byte.tab, Byte.pipe, Byte.backtick, Byte.quote, UInt8(ascii: "<"), UInt8(ascii: ">"), 0x0D:
                break scanning
            case Byte.openParen: parens += 1
            case Byte.closeParen:
                if parens == 0 { break scanning }
                parens -= 1
            case UInt8(ascii: "["): brackets += 1
            case UInt8(ascii: "]"):
                if brackets == 0 { break scanning }
                brackets -= 1
            case UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: ":"):
                if j + 1 >= end || b[j + 1] == Byte.space || b[j + 1] == Byte.tab { break scanning }
            default: break
            }
            j += 1
        }
        while j > start + 1, ".,;:!?*".utf8.contains(b[j - 1]) { j -= 1 }
        return j
    }

    /// After a space inside a bare path: true when one of the next five words goes on into deeper folders
    /// (`My Tax Files 2023/a.txt`). A word that starts a new path, separates list items or ends a clause stops
    /// the look-ahead.
    private static func continuesPath(_ b: [UInt8], from start: Int, to end: Int) -> Bool {
        var i = start
        for _ in 0..<5 {
            guard i < end else { return false }
            let first = b[i]
            if first == Byte.slash || first == Byte.tilde || first == Byte.space || first == Byte.pipe
                || first == Byte.backtick || first == Byte.openParen || first == UInt8(ascii: "=")
                || first == UInt8(ascii: ">") || hasFileScheme(b, at: i, end: end) { return false }
            // Separators between list items (· • →); dashes stay, names such as “Macintosh HD - Data” contain them.
            if has([0xC2, 0xB7], in: b, at: i, end: end) || has([0xE2, 0x80, 0xA2], in: b, at: i, end: end)
                || has([0xE2, 0x86, 0x92], in: b, at: i, end: end) { return false }
            while i < end, b[i] != Byte.space {
                let c = b[i]
                if c == Byte.slash { return true }
                if c == Byte.tab || c == Byte.pipe || c == Byte.backtick || c == Byte.quote || c == Byte.closeParen
                    || c == UInt8(ascii: ",") || c == UInt8(ascii: ";") { return false }
                i += 1
            }
            guard i < end, !".:!?".utf8.contains(b[i - 1]) else { return false }
            i += 1
        }
        return false
    }

    // MARK: Tokens

    /// E-mail addresses, MAC addresses, hardware and device identifiers, the identity's names and serial numbers,
    /// outside aliases that are already in place.
    private mutating func scrub(_ input: String) -> String {
        var text = input
        if text.contains("@") { text = Self.replacing(Patterns.email, in: text) { _ in "‹email›" } }
        if text.contains(":") || text.contains("-") {
            text = Self.replacing(Patterns.macAddress, in: text) { _ in "‹mac address›" }
        }
        let found = Self.matches(Patterns.identifier, in: text)
        if !found.isEmpty {
            let ns = text as NSString
            var replacements: [String] = []
            for range in found {
                let key = ns.substring(with: range).uppercased()
                if let existing = identifiers[key] {
                    replacements.append(existing)
                } else {
                    let number = (counters["id"] ?? 0) + 1
                    counters["id"] = number
                    identifiers[key] = "‹id \(number)›"
                    replacements.append("‹id \(number)›")
                }
            }
            text = Self.substitute(text, found, replacements)
        }
        for (regex, token) in matchers.names { text = Self.replacing(regex, in: text) { _ in token } }
        let ns = text as NSString
        let serials = Self.matches(Patterns.serial, in: text).filter { range in
            // Ten-character developer team identifiers prefix app group names (UBF8T346G9.Office): kept.
            let after = range.location + range.length
            guard range.length == 10, after + 1 < ns.length, ns.character(at: after) == 0x2E else { return true }
            let next = ns.character(at: after + 1)
            return !((next | 0x20) >= 0x61 && (next | 0x20) <= 0x7A)
        }
        if !serials.isEmpty { text = Self.substitute(text, serials, Array(repeating: "‹serial›", count: serials.count)) }
        return text
    }

    /// Matches of `regex` that do not overlap an alias.
    private static func matches(_ regex: NSRegularExpression, in text: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let found = regex.matches(in: text, range: whole).map(\.range)
        guard !found.isEmpty, text.contains("‹") else { return found }
        // Both lists are in text order: one pass drops the matches that overlap an alias.
        let protected = Patterns.alias.matches(in: text, range: whole).map(\.range)
        var kept: [NSRange] = []
        kept.reserveCapacity(found.count)
        var next = 0
        for range in found {
            while next < protected.count, protected[next].location + protected[next].length <= range.location { next += 1 }
            if next < protected.count, protected[next].location < range.location + range.length { continue }
            kept.append(range)
        }
        return kept
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, _ make: (String) -> String) -> String {
        let found = matches(regex, in: text)
        guard !found.isEmpty else { return text }
        let ns = text as NSString
        return substitute(text, found, found.map { make(ns.substring(with: $0)) })
    }

    private static func substitute(_ text: String, _ ranges: [NSRange], _ replacements: [String]) -> String {
        let ns = text as NSString
        var out = ""
        out.reserveCapacity(ns.length)
        var last = 0
        for (range, replacement) in zip(ranges, replacements) {
            out += ns.substring(with: NSRange(location: last, length: range.location - last))
            out += replacement
            last = range.location + range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Regular expressions for one identity's names, longest first.
    private struct Matchers: Sendable {
        var names: [(NSRegularExpression, String)] = []
        var homeComponents: [String] = []
        /// The home folder, without a trailing slash or the data volume prefix.
        var home = ""
        var selfNames: Set<String> = []

        init(_ identity: Identity) {
            var home = identity.home.precomposedStringWithCanonicalMapping
            if home.hasPrefix("/System/Volumes/Data/") { home.removeFirst("/System/Volumes/Data".count) }
            homeComponents = home.split(separator: "/").map { $0.lowercased() }
            self.home = homeComponents.isEmpty ? "" : "/" + home.split(separator: "/").joined(separator: "/")
            let homeName = home.split(separator: "/").last.map(String.init) ?? ""
            let userName = identity.userName.precomposedStringWithCanonicalMapping
            selfNames = Set([userName, homeName].map { $0.lowercased() }.filter { !$0.isEmpty })

            var hosts: Set<String> = []
            for host in identity.hostNames {
                for variant in Self.hostVariants(host.precomposedStringWithCanonicalMapping)
                where variant.count >= 3 && !Self.isGenericHost(variant) {
                    hosts.insert(variant)
                }
            }
            var anywhere: Set<String> = []
            var words: Set<String> = []
            var exactWords: Set<String> = []
            let fullName = identity.fullName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
            let parts = fullName.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            if parts.count >= 2 {
                anywhere.insert(fullName)
                for separator in [" ", "-", "_", ".", ""] { anywhere.insert(parts.joined(separator: separator)) }
            }
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .punctuationCharacters)
                if trimmed.count >= 3, !Names.common.contains(trimmed.lowercased()) { words.insert(trimmed) }
            }
            for name in Set([userName, homeName]) where name.count >= 2 {
                // Account names are lowercase by convention; one that is a common word is matched as that exact word.
                if Names.common.contains(name.lowercased()) { exactWords.insert(name) }
                else if name.count >= 4 { anywhere.insert(name) }
                else { words.insert(name) }
            }
            func folded(_ set: Set<String>) -> Set<String> {
                set.union(set.map { $0.folding(options: .diacriticInsensitive, locale: nil) })
            }
            func pattern(_ tokens: Set<String>, wholeWords: Bool) -> String? {
                let sorted = tokens.filter { !$0.isEmpty }.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
                guard !sorted.isEmpty else { return nil }
                let alternatives = "(?:" + sorted.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
                return wholeWords ? "(?<![\\p{L}\\p{N}])" + alternatives + "(?![\\p{L}\\p{N}])" : alternatives
            }
            let rules: [(Set<String>, Bool, Bool, String)] = [
                (folded(hosts), false, true, "‹host›"),
                (folded(anywhere), false, true, "‹user›"),
                (folded(words), true, true, "‹user›"),
                (exactWords, true, false, "‹user›"),
            ]
            for (tokens, wholeWords, ignoreCase, replacement) in rules {
                guard let source = pattern(tokens, wholeWords: wholeWords),
                      let regex = try? NSRegularExpression(pattern: source, options: ignoreCase ? [.caseInsensitive] : [])
                else { continue }
                names.append((regex, replacement))
            }
        }

        func isSelf(_ lowercasedName: String) -> Bool { selfNames.contains(lowercasedName) }

        /// The components below the current home, when `components` starts with it.
        func dropHome(_ components: ArraySlice<String>) -> ArraySlice<String>? {
            guard !homeComponents.isEmpty, components.count >= homeComponents.count else { return nil }
            for (offset, name) in homeComponents.enumerated()
            where components[components.startIndex + offset].lowercased() != name { return nil }
            return components.dropFirst(homeComponents.count)
        }

        /// `Janes-MacBook-Pro.local`, `Janes-MacBook-Pro`, `Janes MacBook Pro`; `Jane’s MacBook Pro`, `Jane's …`.
        static func hostVariants(_ host: String) -> Set<String> {
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            let label = trimmed.split(separator: ".").first.map(String.init) ?? trimmed
            return [trimmed, label, label.replacingOccurrences(of: "-", with: " "),
                    trimmed.replacingOccurrences(of: "’", with: "'"), trimmed.replacingOccurrences(of: "'", with: "’"),
                    trimmed.filter { $0 != "’" && $0 != "'" }.replacingOccurrences(of: " ", with: "-")]
        }

        /// A host name made only of model words (`MacBook-Pro`, `Mac.lan`) identifies no one and would erase
        /// model names from the report.
        static func isGenericHost(_ host: String) -> Bool {
            host.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .allSatisfy { Names.genericHostWords.contains(String($0)) || $0.allSatisfy(\.isNumber) }
        }
    }

    private enum Patterns {
        static let alias = try! NSRegularExpression(pattern: "‹[a-z][a-z-]*(?: [a-z][a-z-]*)*(?: [0-9]+)?›")
        static let email = try! NSRegularExpression(
            pattern: "(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}")
        static let macAddress = try! NSRegularExpression(
            pattern: "(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
        /// UUIDs (hardware UUID, simulator devices), iPhone UDIDs in both formats, 40-digit hex device IDs.
        static let identifier = try! NSRegularExpression(
            pattern: "(?<![0-9A-Za-z])(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
                + "|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})(?![0-9A-Za-z])")
        /// 10–12 upper-case letters and digits with at least two of each: Mac and accessory serial numbers.
        static let serial = try! NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(?=(?:[A-Z]*[0-9]){2})(?=(?:[0-9]*[A-Z]){2})[A-Z0-9]{10,12}(?![A-Za-z0-9])")
        static let bundleIdentifier = try! NSRegularExpression(
            pattern: "^(?:(?:[A-Z0-9]{10}|group)\\.)?(?:com|org|net|io|dev|app|ai|co|me|de|uk|fr|jp|ch|nl|se|no|fi|dk|it"
                + "|es|ru|cn|ca|au|us|edu|gov|info|biz|tv|sh|so|xyz|cc|be|at|pl|cz|eu|ly|is|im|in|kr|br|mx|tech|cloud"
                + "|studio|games|gg|to|ws|nz|ie|pt|hu|ro|tw|hk|sg|il|za|icloud)(?:[.~][A-Za-z0-9_-]+)+$"
                + "|^[A-Z0-9]{10}\\.[A-Za-z0-9._-]+$",
            options: [.caseInsensitive])
        static let structural = try! NSRegularExpression(
            pattern: "^(?:arm64e?|arm64_32|x86_64h?|aarch64|i386|universal|debug|release|profile)(?:[-_.][a-z0-9_.]+)*$"
                + "|^(?:lib)?python[0-9]+(?:\\.[0-9]+)*$|^swapfile[0-9]*$|^dyld_shared_cache_[a-z0-9_.]+$"
                + "|^(?:untitled|new) folder(?: [0-9]+)?$")
    }

    private enum Names {
        /// First-level home folders macOS and common apps create.
        static let homeFolders = Set<String>([
            "desktop", "documents", "downloads", "movies", "music", "pictures", "public", "applications",
            "creative cloud files", "dropbox", "google drive", "onedrive", "icloud drive (archive)", "parallels",
            "virtual machines.localized", "virtualbox vms", "applications (parallels)", "postman", "zotero", "go",
        ])
        /// Folders at the root of a startup disk (besides Users, Volumes, private, var and tmp).
        static let systemRoots = Set<String>([
            "system", "library", "applications", "usr", "bin", "sbin", "opt", "etc", "cores", "dev", "nix", "sw",
            "developer", "appleinternal", "home", "net", "network", "private", "var", "tmp", "users", "volumes",
        ])
        /// Dot folders in a home folder that hold a tool's caches, packages and settings.
        static let toolFolders = Set<String>([
            ".npm", ".cargo", ".rustup", ".gradle", ".m2", ".nvm", ".pyenv", ".rbenv", ".gem", ".cocoapods", ".bun",
            ".deno", ".docker", ".colima", ".lima", ".orbstack", ".vscode", ".vscode-insiders", ".cursor", ".android",
            ".swiftpm", ".cache", ".local", ".config", ".yarn", ".pnpm-store", ".conda", ".julia", ".stack", ".cabal",
            ".ghcup", ".dartserver", ".pub-cache", ".minikube", ".kube", ".terraform.d", ".oh-my-zsh", ".ollama",
            ".node-gyp", ".electron-gyp", ".expo", ".zsh_sessions", ".ssh", ".gnupg", ".aws", ".azure", ".npm-global",
            ".nuget", ".dotnet", ".sdkman", ".jenv", ".asdf", ".volta", ".fnm", ".mint", ".tuist", ".xcodes",
            ".codeium", ".continue", ".claude", ".lmstudio", ".huggingface", ".keras", ".matplotlib", ".ipython",
            ".jupyter", ".streamlit", ".wdm", ".cups",
        ])
        /// Folders whose children are projects.
        static let devContainers = Set<String>([
            "developer", "development", "dev", "projects", "code", "repos", "repositories", "git", "github", "gitlab",
            "bitbucket", "workspace", "workspaces", "work", "workdir", "src", "source", "sites", "xcode projects",
            "androidstudioprojects", "ideaprojects", "pycharmprojects", "webstormprojects", "eclipse-workspace",
        ])
        /// Folders of downloaded dependencies: package names inside are public, so everything below is kept.
        static let dependencies = Set<String>([
            "node_modules", "pods", ".venv", "venv", "vendor", "carthage", "bower_components", "sourcepackages",
            "checkouts", ".pnpm-store", "site-packages", "dist-packages", "jspm_packages", ".yarn", ".gradle",
            ".cargo", ".npm", ".m2", "mod",
        ])
        /// Build output and tool folders. Names below them are kept only when well known.
        static let artifacts: Set<String> = Set(ProjectArtifactKind.allCases.flatMap(\.folderNames)
            .filter { !$0.hasSuffix("*") }.map { $0.lowercased() })
            .union(["deriveddata", ".git", ".svn", ".hg", "dist", "out", ".output", "coverage", ".nyc_output",
                    "__pycache__", ".swiftpm", "xcuserdata", ".expo", ".vercel", ".serverless", ".cache", ".parcel-cache"])
        /// Files that mark a project folder.
        static let projectMarkers = Set<String>([
            "package.json", "cargo.toml", "package.swift", "pom.xml", "build.gradle", "build.gradle.kts",
            "settings.gradle", "settings.gradle.kts", "podfile", "pyproject.toml", "setup.py", "requirements.txt",
            "go.mod", "gemfile", "mix.exs", "pubspec.yaml", "stack.yaml", "cmakelists.txt", "makefile", "build.zig",
            "angular.json", "turbo.json", "tsconfig.json", ".git", "readme.md",
        ])
        /// Library folders that hold the person's own messages, mail, iCloud Drive and documents.
        static let personalInLibrary = Set<String>([
            "mail", "messages", "mail downloads", "autosave information", "desktop", "documents", "downloads",
            "movies", "music", "pictures",
        ])
        static let systemVolumes = Set<String>([
            "macintosh hd", "macintosh hd - data", "data", "recovery", "preboot", "vm", "update", "xarts",
            "iscpreboot", "hardware",
        ])
        static let bundleExtensions = Set<String>([
            "app", "framework", "bundle", "plugin", "kext", "xpc", "appex", "prefpane", "qlgenerator", "mdimporter",
            "saver", "systemextension", "driver", "dext", "component", "vst", "vst3", "clap", "colorpicker", "service",
        ])
        /// Words before a quoted name in messages such as “The file “X” couldn’t be opened.”
        static let fileNouns: Set<String> = ["file", "folder", "directory", "item", "document", "package", "volume"]
        /// Names that are not personal: standard folders, project structure, build output, well-known files.
        static let wellKnown = Set<String>([
            // Standard and app-created folders
            "desktop", "documents", "downloads", "movies", "music", "pictures", "public", "applications", "library",
            "users", "shared", "home", "photos library.photoslibrary", "music library.musiclibrary",
            "tv library.tvlibrary", "imovie library.imovielibrary", "photo booth library", "garageband", "itunes",
            "media.localized", "tv", "voice memos", "screenshots", "screen recordings", "zoom", "microsoft user data",
            "my drive", "shared drives", "other computers", "backups.backupdb", "latest", "inprogress",
            "macintosh hd", "macintosh hd - data", "application support", "caches", "containers", "group containers",
            "preferences", "launchagents", "launchdaemons", "logs", "developer", "frameworks", "fonts", "keychains",
            "saved application state", "cookies", "webkit", "httpstorages", "application scripts", "attachments",
            "originals", "masters", "derivatives", "resources", "thumbnails", "database", "private",
            // Project structure
            "contents", "macos", "plugins", "sharedsupport", "data", "cache", "log", "tmp", "temp", "src", "source",
            "sources", "code", "pkg", "lib",
            "libs", "include", "bin", "sbin", "share", "man", "etc", "var", "opt", "usr", "test", "tests", "spec",
            "specs", "docs", "doc", "documentation", "scripts", "tools", "assets", "images", "img", "static",
            "packages", "apps", "app", "web", "www", "server", "client", "api", "config", "configs", "conf",
            "settings", "db", "backup", "backups", "archive", "archives", "old", "misc", "res", "third_party",
            "thirdparty", "external", "examples", "example", "samples", "sample", "demo", "components", "pages",
            "views", "models", "controllers", "utils", "helpers", "styles", "css", "js", "icons", "locales", "i18n",
            "migrations", "fixtures", "mocks", "frontend", "backend", "common", "core", "main", "default",
            "profile", "profiles", "export", "exports", "import", "imports", "inbox", "outbox", "sent", "drafts",
            "trash", "junk", "photos", "videos", "audio", "dcim",
            // Build output
            "debug", "release", "deps", "incremental", "build", "products", "intermediates.noindex", "index.noindex",
            "artifacts", "objects", "pack", "refs", "heads", "remotes", "tags", "hooks", "info", "lfs", "modules",
            "objects-normal", "target", "output", "fingerprint", "examples", "nightly", "stable",
            // Files
            "info.plist", "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb",
            "cargo.toml", "cargo.lock", "package.swift", "package.resolved", "podfile", "podfile.lock", "gemfile",
            "gemfile.lock", "makefile", "cmakelists.txt", "dockerfile", "docker-compose.yml", "docker-compose.yaml",
            "compose.yaml", "compose.yml", "readme", "readme.md", "readme.txt", "license", "license.md", "license.txt",
            "changelog.md", "swapfile", "sleepimage", "docker.raw", "docker.qcow2", "data.img", "disk.img", "pom.xml",
            "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradle.properties",
            "gradlew", "go.mod", "go.sum", "requirements.txt", "pyproject.toml", "setup.py", "setup.cfg", "pipfile",
            "pipfile.lock", "poetry.lock", "tox.ini", "angular.json", "turbo.json", "tsconfig.json", "pubspec.yaml",
            "pubspec.lock", "mix.exs", "mix.lock", "stack.yaml", "cabal.project", "build.zig", "main.tf", "brewfile",
            "vagrantfile", "contents.json", "pkginfo", "coderesources", "assets.car", "notestore.sqlite",
            "photos.sqlite", "chat.db", "index.html", "index.js", "main.swift", "pyvenv.cfg", "history", "bookmarks",
            "login data", "local state", "state.vscdb", "storage.json", "settings.json", "keybindings.json",
            "web data", "favicons", "top sites", "current session", "last session", "known_hosts",
            "authorized_keys", "id_rsa", "id_ed25519", "id_rsa.pub", "id_ed25519.pub", "head", "packed-refs",
            "fetch_head", "orig_head", "index", "description", "commit_editmsg", "manifest.json", "manifest.db",
            "manifest.plist", "status.plist", "localizable.strings", "infoplist.strings", "embedded.mobileprovision",
            "project.pbxproj", "contents.xcworkspacedata", "userinterfacestate.xcuserstate", "keychain-2.db",
            "metadata", "lock", "vm.img",
        ])
        /// Words that are not a person's name in a report; a name part equal to one is not redacted on its own.
        static let common = Set<String>([
            "user", "users", "admin", "administrator", "test", "tester", "guest", "root", "mac", "apple", "home",
            "data", "system", "library", "local", "shared", "staff", "work", "dev", "developer", "file", "files",
            "disk", "report", "scan", "health", "app", "apps", "application", "owner", "default", "public", "main",
            "demo", "build", "cache", "temp", "project", "folder", "volume", "serial", "email", "host", "account",
            "other", "note", "notes", "music", "photo", "photos", "mail", "office", "info", "support", "service",
            "server", "macbook", "imac", "studio", "mini", "pro", "air", "max", "desktop", "documents", "downloads",
            "movies", "pictures", "sites", "code", "swap", "store", "item", "items", "size", "free", "used", "total",
            "step", "result", "time", "found", "kind", "startup", "login", "security", "storage", "memory",
            "battery", "review", "cleanup", "logs", "caches", "the", "and", "for", "von", "van", "der", "den", "del",
            "della", "des", "dos", "das", "bin", "ibn", "jr", "sr", "mr", "mrs", "ms", "dr",
        ])
        static let genericHostWords = Set<String>([
            "mac", "macbook", "macbookpro", "macbookair", "pro", "air", "mini", "studio", "imac", "imacpro", "macpro",
            "macmini", "book", "local", "localhost", "localdomain", "lan", "home", "the", "s", "m1", "m2", "m3", "m4",
            "m5", "max", "ultra", "intel", "apple", "computer", "laptop", "desktop", "mbp", "mba", "my", "new", "old",
            "work", "office",
        ])
    }
}
