import Foundation

@main
enum DuplicateSelectionCheck {
    static func main() {
        func file(_ path: String, _ hash: String, selected: Bool = false) -> DuplicateFile {
            DuplicateFile(id: UUID(), url: URL(fileURLWithPath: path), size: 100, fingerprint: hash, isSelected: selected)
        }
        let a = file("/a", "one", selected: true)
        let b = file("/b", "one", selected: true)
        let c = file("/c", "two")
        let d = file("/d", "two")
        let e = file("/e", "two")
        let unique = file("/unique", "unique", selected: true)
        let inputs = [e, b, unique, a, d, c]
        precondition(DuplicateSelection.extras(in: inputs) == Set([b.id, d.id, e.id]))
        precondition(DuplicateSelection.extras(in: []).isEmpty)
        precondition(DuplicateSelection.extras(in: [unique]).isEmpty)
        print("PASS: multiple groups, deterministic keeper, previous selections, singleton and empty results")
    }
}
