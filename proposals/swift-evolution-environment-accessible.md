# Environment-Accessible Observable Objects

* Proposal: [SE-XXXX](XXXX-environment-accessible.md)
* Authors: [Author Name](https://github.com/mi11ione)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#XXXXX](https://github.com/apple/swift/pull/XXXXX)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

This proposal introduces the `@EnvironmentAccessible` macro and `@EnvironmentBound` property wrapper, enabling SwiftUI `@Observable` objects to access environment values with minimal boilerplate. This addresses the fundamental limitation where environment values are only accessible within View contexts.

## Motivation

SwiftUI's environment system provides elegant dependency injection within the view hierarchy:

```swift
struct ContentView: View {
    @Environment(\.locale) var locale
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        // Direct access to injected dependencies
    }
}
```

However, this system is unavailable to `@Observable` objects:

```swift
@Observable
class ContentModel {
    // ❌ Cannot access environment
    @Environment(\.locale) var locale // Compiler error
    
    // Current workaround: manual injection
    let locale: Locale
    
    init(locale: Locale) {
        self.locale = locale
    }
}
```

This limitation forces developers to:
- Thread dependencies manually through object hierarchies
- Create initialization boilerplate for each dependency
- Update multiple call sites when dependencies change
- Compromise testability with complex initialization

In large applications, this problem compounds:

```swift
// Current approach - manual threading becomes unwieldy
struct RootView: View {
    @Environment(\.database) private var database
    @Environment(\.networkClient) private var network
    @Environment(\.analytics) private var analytics
    @Environment(\.userSettings) private var settings
    
    var body: some View {
        ContentView(
            model: ContentModel(
                database: database,
                network: network,
                analytics: analytics,
                settings: settings,
                userModel: UserModel(
                    database: database,
                    network: network,
                    settings: settings
                ),
                cartModel: CartModel(
                    database: database,
                    analytics: analytics
                )
            )
        )
    }
}
```

## Proposed solution

We propose two complementary APIs that work together to eliminate environment forwarding boilerplate:

### 1. `@EnvironmentAccessible` macro for observable objects:

```swift
@EnvironmentAccessible
@Observable
class ContentModel {
    @Environment(\.locale) var locale
    @Environment(\.colorScheme) var colorScheme
    
    var localizedContent: String {
        // Direct environment access after binding
        locale.localizedString(forLanguageCode: "en")
    }
}
```

### 2. `@EnvironmentBound` property wrapper for automatic binding:

```swift
struct ContentView: View {
    @EnvironmentBound var model = ContentModel()
    
    var body: some View {
        Text(model.localizedContent)
        // Environment automatically bound to model
    }
}
```

For cases requiring explicit control, manual binding is also supported:

```swift
struct ContentView: View {
    @State private var model = ContentModel()
    
    var body: some View {
        Text(model.localizedContent)
            .bindEnvironment(to: model)
    }
}
```

## Detailed design

### Binding context and execution model

Environment binding in this proposal is explicitly tied to SwiftUI's view lifecycle:

1. **View-anchored binding**: Environment values are only accessible when bound through SwiftUI
2. **No ambient context**: Unlike TaskLocal, there is no implicit propagation of environment values
3. **Explicit lifecycle**: Binding occurs during view updates and is cleaned up appropriately
4. **MainActor-bound operations**: All binding operations occur on the main thread during SwiftUI's update cycle

This design ensures that:
- Environment access is deterministic and predictable
- No hidden dependencies are introduced
- The execution context is always clear
- Thread safety is maintained

### Core components

#### 1. @EnvironmentAccessible macro

```swift
/// Enables environment access in `@Observable` objects by synthesizing
/// storage and binding mechanisms for `@Environment` properties.
@attached(member, names: 
    named(_environmentStorage), 
    arbitrary
)
@attached(extension, conformances: EnvironmentBindable)
public macro EnvironmentAccessible() = #externalMacro(
    module: "SwiftUIMacros", 
    type: "EnvironmentAccessibleMacro"
)
```

#### 2. @EnvironmentBound property wrapper

```swift
/// A property wrapper that automatically binds environment values to 
/// EnvironmentBindable objects during SwiftUI's update cycle.
@propertyWrapper
public struct EnvironmentBound<Value: EnvironmentBindable>: DynamicProperty {
    @State private var storage: Storage<Value>
    @Environment(\.self) private var environment
    
    public init(wrappedValue: Value) {
        self._storage = State(initialValue: Storage(value: wrappedValue))
    }
    
    public var wrappedValue: Value {
        storage.value
    }
    
    public var projectedValue: Binding<Value> {
        Binding(
            get: { wrappedValue },
            set: { storage.value = $0 }
        )
    }
    
    public func update() {
        // Called by SwiftUI during view updates
        storage.value.bindEnvironment { keyPath in
            environment[keyPath: keyPath]
        }
    }
    
    private final class Storage<T>: ObservableObject {
        let value: T
        init(value: T) { self.value = value }
    }
}
```

#### 3. EnvironmentBindable protocol

```swift
/// A type that can receive SwiftUI environment values.
public protocol EnvironmentBindable: AnyObject {
    /// Binds environment values to this object.
    /// - Parameter environment: A closure providing access to current environment values
    func bindEnvironment(from environment: @escaping (AnyKeyPath) -> Any?)
    
    /// Unbinds environment values.
    func unbindEnvironment()
    
    /// Returns whether environment is currently bound.
    var isEnvironmentBound: Bool { get }
}
```

### Generated code

For an observable class:

```swift
@EnvironmentAccessible
@Observable
class MyModel {
    @Environment(\.database) var database: Database
    @Environment(\.logger) var logger: Logger
    
    let child = ChildModel() // Nested object
}
```

The macro generates:

```swift
@Observable
class MyModel {
    // Synthesized storage
    private let _environmentStorage = EnvironmentStorage()
    
    // Transform @Environment properties to computed properties
    var database: Database {
        _read {
            if let value = _environmentStorage.value(for: \EnvironmentValues.database) {
                yield value
            } else {
                yield EnvironmentValues().database // Default value
            }
        }
        _modify {
            var value = _environmentStorage.value(for: \EnvironmentValues.database) ?? EnvironmentValues().database
            yield &value
            _environmentStorage.setValue(value, for: \EnvironmentValues.database)
        }
    }
    
    var logger: Logger {
        _read {
            if let value = _environmentStorage.value(for: \EnvironmentValues.logger) {
                yield value
            } else {
                yield EnvironmentValues().logger // Default value
            }
        }
        _modify {
            var value = _environmentStorage.value(for: \EnvironmentValues.logger) ?? EnvironmentValues().logger
            yield &value
            _environmentStorage.setValue(value, for: \EnvironmentValues.logger)
        }
    }
    
    let child = ChildModel()
}

extension MyModel: EnvironmentBindable {
    public func bindEnvironment(from environment: @escaping (AnyKeyPath) -> Any?) {
        _environmentStorage.bind(environment)
        
        // Only bind children when explicitly requested via modifier
        // Mirror-based reflection is opt-in
    }
    
    public func unbindEnvironment() {
        _environmentStorage.unbind()
    }
    
    public var isEnvironmentBound: Bool {
        _environmentStorage.isBound
    }
}
```

### EnvironmentStorage implementation

```swift
/// Thread-safe storage for environment values with proper error handling.
/// 
/// Safety: This type is marked @unchecked Sendable because all mutable state
/// is protected by os_unfair_lock, ensuring thread-safe access. The closure
/// property is immutable after binding and only accessed under lock protection.
final class EnvironmentStorage: @unchecked Sendable {
    private var environment: ((AnyKeyPath) -> Any?)?
    private var cache: [AnyKeyPath: Any] = [:]
    private var lock = os_unfair_lock()
    
    var isBound: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return environment != nil
    }
    
    func bind(_ environment: @escaping (AnyKeyPath) -> Any?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        self.environment = environment
        self.cache.removeAll()
    }
    
    func unbind() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        self.environment = nil
        self.cache.removeAll()
    }
    
    func value<T>(for keyPath: KeyPath<EnvironmentValues, T>) -> T? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        // Return nil if not bound (caller should use default)
        guard environment != nil else { return nil }
        
        // Check cache first
        if let cached = cache[keyPath] as? T {
            return cached
        }
        
        // Get from environment
        if let value = environment?(keyPath) as? T {
            cache[keyPath] = value
            return value
        }
        
        return nil
    }
    
    func setValue<T>(_ value: T, for keyPath: KeyPath<EnvironmentValues, T>) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        
        cache[keyPath] = value
    }
}
```

### SwiftUI integration

#### View modifier for explicit binding

```swift
extension View {
    /// Binds the current environment to an object conforming to EnvironmentBindable.
    public func bindEnvironment<T: EnvironmentBindable>(to object: T) -> some View {
        modifier(EnvironmentBindingModifier(objects: [object]))
    }
    
    /// Binds the current environment to multiple objects.
    public func bindEnvironments<T: EnvironmentBindable>(to objects: [T]) -> some View {
        modifier(EnvironmentBindingModifier(objects: objects))
    }
    
    /// Binds the current environment to an object and optionally its children.
    public func bindEnvironment<T: EnvironmentBindable>(
        to object: T,
        includeChildren: Bool
    ) -> some View {
        modifier(EnvironmentBindingModifier(
            objects: includeChildren ? object.allBindableChildren : [object]
        ))
    }
}

private struct EnvironmentBindingModifier: ViewModifier {
    let objects: [EnvironmentBindable]
    @Environment(\.self) private var environment
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                bindAll()
            }
            .onChange(of: environment) { _, _ in
                bindAll()
            }
            .onDisappear {
                unbindAll()
            }
    }
    
    private func bindAll() {
        for object in objects {
            object.bindEnvironment { keyPath in
                environment[keyPath: keyPath]
            }
        }
    }
    
    private func unbindAll() {
        for object in objects {
            object.unbindEnvironment()
        }
    }
}

// Helper for finding all bindable children (only used with includeChildren: true)
extension EnvironmentBindable {
    fileprivate var allBindableChildren: [EnvironmentBindable] {
        var result = [self]
        // Mirror-based reflection only performed when explicitly requested
        Mirror(reflecting: self).children.forEach { child in
            if let bindable = child.value as? EnvironmentBindable {
                result.append(contentsOf: bindable.allBindableChildren)
            }
        }
        return result
    }
}
```

### Concurrency and async/await

The design handles Swift concurrency nicely. Environment values are safely accessible across await boundaries:

```swift
@EnvironmentAccessible
@Observable
class DataModel {
    @Environment(\.networkClient) var client
    
    func loadData() async throws {
        let data = try await client.fetch("/api/data")
        process(data)
    }
}
```

Key guarantees:
- Environment binding persists across `await` boundaries
- Thread-safe access via internal locking
- No task-local storage complexity
- Actor isolation is respected

### Error handling and edge cases

The implementation handles edge cases gracefully:

```swift
@EnvironmentAccessible
@Observable
class SafeModel {
    @Environment(\.database) var database
    
    func performOperation() {
        guard isEnvironmentBound else {
            print("Warning: Accessing environment before binding")
            // Uses default value from EnvironmentValues()
            return
        }
        
        // Safe to use environment
        database.save(data)
    }
}
```

### Performance impact

The design minimizes overhead through:

1. **Lazy binding**: Environment values are only resolved when accessed
2. **Caching**: Values are cached after first access to avoid repeated lookups
3. **Lock optimization**: os_unfair_lock provides minimal overhead for thread safety

Expected impact:
- **Memory**: Additional storage per bound object for cache and binding closure
- **CPU**: One-time binding cost during view appearance, cached access thereafter
- **Reflection cost**: When using `includeChildren: true`, Mirror-based traversal adds O(n) overhead where n is the number of properties

Note: Actual performance characteristics will need validation during implementation.

### SwiftUI Previews support

```swift
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environment(\.locale, Locale(identifier: "fr"))
            .environment(\.colorScheme, .dark)
        // @EnvironmentBound automatically works in previews
    }
}
```

### Testing support

```swift
extension EnvironmentBindable {
    /// Binds test environment values for unit testing.
    public func bindTestEnvironment(_ values: [PartialKeyPath<EnvironmentValues>: Any]) {
        bindEnvironment { keyPath in
            guard let typedKeyPath = keyPath as? PartialKeyPath<EnvironmentValues> else {
                return nil
            }
            return values[typedKeyPath]
        }
    }
}

// Example test with proper isolation
final class ContentModelTests: XCTestCase {
    var model: ContentModel!
    
    override func setUp() {
        super.setUp()
        model = ContentModel()
    }
    
    override func tearDown() {
        model.unbindEnvironment()
        model = nil
        super.tearDown()
    }
    
    func testEnvironmentBinding() {
        // Arrange
        model.bindTestEnvironment([
            \.locale: Locale(identifier: "fr_FR"),
            \.colorScheme: ColorScheme.dark
        ])
        
        // Assert
        XCTAssertEqual(model.locale.identifier, "fr_FR")
        XCTAssertEqual(model.colorScheme, .dark)
    }
    
    func testDefaultValues() {
        // Without binding, should use defaults
        XCTAssertNotNil(model.locale) // Falls back to EnvironmentValues().locale
    }
}
```

### Migration strategy

For gradual adoption in existing codebases:

```swift
// Phase 1: New features use @EnvironmentBound
struct NewFeatureView: View {
    @EnvironmentBound var model = NewFeatureModel()
    
    var body: some View {
        // Automatic binding, no boilerplate
    }
}

// Phase 2: Migrate existing models gradually
@EnvironmentAccessible
@Observable
class ExistingModel {
    @Environment(\.api) var api
    
    // Can still accept injected dependencies during migration
    init(api: API? = nil) {
        if let api {
            self.api = api
        }
    }
}

// Phase 3: Complex hierarchies with mixed approaches
struct ComplexView: View {
    @EnvironmentBound var newModel = NewModel()
    @StateObject private var oldModel: OldModel
    
    init(dependency: Dependency) {
        _oldModel = StateObject(wrappedValue: OldModel(dependency: dependency))
    }
}
```

## Best practices and guidance

### When to use each approach

**Use `@EnvironmentBound` when:**
- Creating new views with observable objects
- The object's lifecycle matches the view's lifecycle
- You want automatic environment binding

**Use manual `.bindEnvironment(to:)` when:**
- You need explicit control over binding timing
- Working with conditional or dynamic objects
- Integrating with existing code

**Continue using manual injection when:**
- The object is a simple value type
- Dependencies rarely change
- The object is shared across many unrelated views

### Anti-patterns to avoid

```swift
// ❌ Don't use for short-lived objects
@EnvironmentAccessible
@Observable
class TemporaryCalculator {
    @Environment(\.numberFormatter) var formatter
    // Just pass the formatter directly
}

// ❌ Don't access environment in init
@EnvironmentAccessible
@Observable
class BadModel {
    @Environment(\.database) var database
    
    init() {
        database.setup() // Error: Not bound yet
    }
}

// ✅ Do use lifecycle methods
@EnvironmentAccessible
@Observable
class GoodModel {
    @Environment(\.database) var database
    
    func onAppear() {
        database.setup() // Safe: Called after binding
    }
}
```

## Implementation status

* **Prototype**: Not yet implemented

The macro implementation can be developed as a third-party package for validation before official adoption. The property wrapper and protocol would need to be part of SwiftUI itself.

## Source compatibility

This is a purely additive change. Existing code continues to work without modification. The new functionality only applies to:
- Classes marked with `@EnvironmentAccessible`
- Properties using `@EnvironmentBound`
- Views using `.bindEnvironment(to:)`

## Effect on ABI stability

This proposal maintains ABI stability:
- Adds new protocol `EnvironmentBindable`
- Adds new property wrapper `@EnvironmentBound` 
- Adds new view modifiers
- Uses only existing, stable Swift features
- No modifications to existing types

## Effect on API resilience

The design allows for future evolution:
- Additional methods can be added to `EnvironmentBindable` with default implementations
- The environment binding closure signature supports future environment value types
- The macro can be enhanced without breaking existing usage

## Alternatives considered

### Automatic binding through property wrappers alone

Attempting to make `@State` and `@StateObject` automatically bind environment:

```swift
@State private var model = Model() // Automatically receives environment
```

Rejected because:
- Requires modifying existing property wrapper behavior
- Explicit binding provides better control

### Global environment access

```swift
extension EnvironmentValues {
    static var current: EnvironmentValues { get }
}
```

Rejected because:
- Breaks hierarchical environment model

### Protocol with associated types

```swift
protocol EnvironmentAccessible {
    associatedtype Dependencies
    var dependencies: Dependencies { get }
}
```

Rejected because:
- Less flexible than key path approach
- Requires defining dependency containers
- More complex for users

### Compiler-level integration

Deep integration with Swift compiler to make `@Environment` work everywhere.

Rejected because:
- Requires significant compiler changes
- Would take years to implement
- Macro approach achieves similar ergonomics

## Future directions

### Selective environment observation

Allow objects to specify which environment values they observe for performance:

```swift
@EnvironmentAccessible(observing: [\.locale, \.colorScheme])
@Observable
class OptimizedModel {
    // Only specified values trigger updates
}
```

### Integration with Navigation

Automatic environment binding for navigation destinations:

```swift
NavigationStack {
    // ...
}
.navigationDestination(for: Model.self) { model in
    DetailView(model: model)
    // Environment automatically bound to model
}
```

### Environment value requirements

Compile-time verification of required environment values:

```swift
@EnvironmentAccessible(requires: [\.database, \.api])
@Observable
class StrictModel {
    // Compiler error if used without required environment
}
```

### And last but not least

Actor and non-observable class support?