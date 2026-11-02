import Foundation

@main
struct UpdateCheck {
    static func main() async throws {
        precondition(AppVersion("v0.10.0")! > AppVersion("0.9.0")!)
        precondition(AppVersion("0.4.0") == AppVersion("v0.4.0"))
        for invalid in ["", "1.2", "1.2.3.4", "1.-2.3", "1.2.3-beta", "../bad"] {
            precondition(AppVersion(invalid) == nil)
        }
        func release(_ tag: String, preview: Bool = false, draft: Bool = false, asset: Bool = true) -> PublishedRelease {
            PublishedRelease(tag_name: "v" + tag, draft: draft, prerelease: preview,
                             assets: asset ? [.init(name: "Mac-Polish-\(tag)-macos-arm64.zip", state: "uploaded")] : [])
        }
        let releases = [release("0.5.0", preview: true), release("0.4.1"), release("0.8.0", draft: true), release("0.9.0", asset: false), release("0.3.0")]
        let current = AppVersion("0.4.0")!
        precondition(PublishedRelease.newest(releases, after: current, previews: false)?.tag_name == "v0.4.1")
        precondition(PublishedRelease.newest(releases, after: current, previews: true)?.tag_name == "v0.5.0")
        precondition(PublishedRelease.newest(releases, after: AppVersion("1.0.0")!, previews: true) == nil)
        if CommandLine.arguments.contains("--live") {
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/Abdel-RahmanSaied/Mac-Polish/releases?per_page=100")!)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        let live = try JSONDecoder().decode([PublishedRelease].self, from: data)
        precondition(PublishedRelease.newest(live, after: AppVersion("0.3.0")!, previews: true) != nil)
        }
        print("PASS: numeric versions, preview channel, draft/asset exclusion, no downgrade")
    }
}
