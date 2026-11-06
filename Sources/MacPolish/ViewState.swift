import SwiftUI

/// View-owned state, used instead of SwiftUI's `State` attribute.
///
/// From the macOS 27 SDK, writing that attribute expands a macro implemented by the SwiftUIMacros compiler plugin.
/// Xcode ships the plugin; Command Line Tools alone do not, so with only Command Line Tools `swift run` failed on
/// every view ("plugin for module 'SwiftUIMacros' not found"). This wrapper stores a `State` value directly, which
/// needs no plugin, and SwiftUI manages it exactly like the attribute: it finds dynamic properties nested inside
/// other dynamic properties. It builds the same way with older SDKs.
///
/// `Scripts/test.sh` refuses the bare attribute in `Sources/` so the build keeps working without Xcode.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) { storage = State(initialValue: wrappedValue) }

    /// Optional state may be declared without a value, starting as nil.
    init() where Value: ExpressibleByNilLiteral { storage = State(initialValue: nil) }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
