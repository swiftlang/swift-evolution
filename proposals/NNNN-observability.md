# Observation

* Proposal: [SE-NNNN](NNNN-observation.md)
* Authors: [Philippe Hausler](https://github.com/phausler), [Nate Cook](https://github.com/natecook1000)
* Review Manager: TBD
* Status: **Draft implementation**

#### Changes

* Pitch 1: [Initial pitch](https://forums.swift.org/t/pitch-observation/62051)
* Pitch 2: Previously Observation registered observers directly to `Observable`, the new approach registers observers to an `Observable` via a `ObservationTransactionModel`. These models control the "edge" of where the change is emitted. They are the responsible component for notifying the observers of events. This allows the observers to focus on just the event and not worry about "leading" or "trailing" (will/did) "edges" of the signal. Additionally the pitch was shifted from the type wrapper feature over to the more appropriate macro features.
* Pitch 3: The `Observer` protocol and `addObserver(_:)` method are gone in favor of providing async sequences of changes and transactions.

#### Suggested Reading

* [Expression Macros](https://github.com/apple/swift-evolution/blob/main/proposals/0382-expression-macros.md)
* [Attached Macros](https://github.com/DougGregor/swift-evolution/blob/attached-macros/proposals/nnnn-attached-macros.md)

## Introduction

Making responsive apps often requires the ability to update the presentation when underlying data changes. The _observer pattern_ allows a subject to maintain a list of observers and notify them of specific or general state changes. This has the advantages of not directly coupling objects together and allowing implicit distribution of updates across potential multiple observers. An observable object needs no specific information about its observers.

This design pattern is a well-traveled path by many languages, and Swift has an opportunity to provide a robust, type-safe, and performant implementation. This proposal defines what an observable reference is, what an observer needs to conform to, and the connection between a type and its observers.

## Motivation

There are already a few mechanisms for observation in Swift. These include key-value observing (KVO) and `ObservableObject`, but each of those have limitations. KVO can only be used with `NSObject` descendants, and `ObservableObject` requires using Combine, which is restricted to Darwin platforms and does not use current Swift concurrency features. By taking experience from those existing systems, we can build a more generally useful feature that applies to all Swift reference types, not just those that inherit from `NSObject`, and have it work cross-platform with the advantages from language features like `async`/`await`.

The existing systems get a number of behaviors and characteristics right. However, there are a number of areas that can provide a better balance of safety, performance, and expressiveness. For example, grouping dependent changes into an independent transaction is a common task, but this is complex when using Combine and unsupported when using KVO. In practice, observers want access to transactions, with the ability to specify how transactions are interpreted.

Annotations clarify what is observable, but can also be cumbersome. For example, Combine requires not just that a type conform to `ObservableObject`, but also requires each property that is being observed to be marked as `@Published`. Furthermore, computed properties cannot be directly observed. In reality, having non-observed fields in a type that is observable is uncommon.

Throughout this document, references to both KVO and Combine will illustrate what capabilities are benefits and can be incorporated into the new approach, and what drawbacks are possible to solve in a more robust manner.

### Prior Art

#### KVO

Key-value observing in Objective-C has served that model well, but is limited to class hierarchies that inherit from `NSObject`. The APIs only offer the intercepting of events, meaning that the notification of changes is between the `willSet` and `didSet` events. KVO has great flexibility with granularity of events, but lacks in composability. KVO observers must also inherit from `NSObject`, and rely on the Objective-C runtime to track the changes that occur. Even though the interface for KVO has been updated to utilize the more modern Swift strongly-typed key paths, under the hood its events are still stringly typed.

#### Combine

Combine's `ObservableObject` produces changes on the leading edge of the `willSet`/`didSet` events, and all values are delivered before the value is set. While this serves SwiftUI well, it is restrictive for non-SwiftUI usage and can be surprising to developers first encountering that restriction. `ObservableObject` also requires all observed properties to be marked as `@Published` to interact with change events. In most cases, this requirement is applied to every single property and becomes redundant to the developer; folks writing an `ObservableObject` conforming type must repeatedly (with little to no true gained clarity) annotate each property. In the end, this results in meaning fatigue of what is or isn't a participating item.

## Proposed solution

A formalized observer pattern needs to support the following capabilities:

* Marking a type as observable
* Tracking changes within an instance of an observable type
* Observing and utilizing those changes from somewhere else, e.g. another type

In addition, the design and implementation should meet these criteria:

* Observable types are easy to annotate (without fatigue of meaning)
* Access control should be respected
* Adopting the features for observability should require minimal effort to get started
* Using advanced features should progressively disclose to more complex systems
* Observation should be able to handle more than one observed member at once
* Observation should be able to work with computed properties that reference other properties
* Observation should be able to work with computed properties that process both get and set to external storage
* Integration of observation should work in transactions of graphs and not just singular objects

We propose a new standard library module named `Observation` that includes the protocols, types, and macros to implement such a pattern.

Primarily, a type can declare itself as observable simply by using the `@Observable` macro annotation:

```swift
@Observable public final class MyObject {
    public var someProperty: String = ""
    public var someOtherProperty: Int = 0
    fileprivate var somePrivateProperty: Int = 1
}
```

The macro provides three major ways of interacting with changed properties; a way of tracking changes that are coalesced starting from the willSet of properties and ending based upon a specified isolation, a way of tracking specific value changes that transactionally coalesce around the phase of iteration, and a way of interoperating with UI. The first two systems are intended to specifically allow developers to interact with values in non-ui based systems. The changes provide a mechanism to track when an instance has values that need to be read after an update occurs. It is worth noting that this system has the prerequisite that exclusivity, thread safety, and/or isolation is handled by the object in question. If for example two properties have some sort of linked atomicity then it is the responsibility of the author of that type to provide that atomicity since that is the domain of that object and not general observation. Likewise, observing a specific property for it's values does not make that specific sequence of values able to be sent from one task to another by the feature of the property's type but instead by the nature of the object being observed. I.e. the asynchronous sequence of values is only sendable if and only if the subject of observation is sendable.

For most tasks that involve the UI; the SwiftUI interoperation is the suggested manner in which to allow data to flow through the views. In this document there will be discussion about dependencies and the concept of computed properties. It is worth noting that since the SwiftUI interaction is graph based to any field accessed within the scope specified it means that system does not have the limitation of dependency tracking.

The `@Observable` macro declares and implements conformance to the `Observable` protocol, which includes a set of extension methods to handle observation. In the simplest case, a client can use the `values(for:)` method to observe changes to a specific property for a given instance.

```swift
func processChanges(_ object: MyObject) async {
    for await value in object.values(for: \.someProperty) {
        print(value)
    }
}
```

This allows users of `Observable` types to observe changes to specific values or an instance as a whole as asynchronous sequences of change events. The `values(for:)` method provides type safety, since it only provides the changes to one specific property.

```swift
object.someProperty = "hello" 
// prints "hello" in the awaiting loop
object.someOtherProperty += 1
// nothing is printed
```

Observable objects can also provide changes grouped into transactions, which coalesce any changes that are made between suspension points. Transactions are delivered isolated to an actor that you provide, or the main actor by default.

```swift
func processTransactions(_ object: MyObject) async {
    for await change in objects.changes(for: [\.someProperty, \.someOtherProperty]) {
        print(myObject.someProperty, myObject.someOtherProperty)
    }
}
```

Unlike `ObservableObject` and `@Published`, the properties of an `@Observable` type do not need to be individually marked as observable. Instead, all stored properties are implicitly observable.

For read-only computed properties, an author can add the static `dependencies(of:)` method to claim additional key paths as part of their observation. This is similar to the mechanism that KVO uses to provide additional key paths that have effects to key paths.

```swift
extension MyObject {
    var someComputedProperty: Int { 
        somePrivateProperty + someOtherProperty
    }

    nonisolated static func dependencies(
        of keyPath: PartialKeyPath<Self>
    ) -> TrackedProperties<Self> {
        switch keyPath {
        case \.someComputedProperty:
            return [\.somePrivateProperty, \.someOtherProperty]
        default:
            return [keyPath]
        }
    }
}
```

Since all access to observing changes is by key path, visibility keywords like `public` and `private` determine what can and cannot be observed. Unlike KVO, this means that only members that are accessible in a particular scope can be observed. This fact is reflected in the design, where transactions are represented as `TrackedProperties` instances, which allow querying for the changed key paths, but not their iteration.

```swift
// ✅ `someProperty` is publicly visible
object.changes(for: \.someProperty)
// ❌ `somePrivateProperty` is restricted to `private` access
object.changes(for: \.somePrivateProperty) 
// ✅ `someComputedProperty` is visible; `somePrivateProperty` isn't accessible in returned `TrackedProperties` instances
object.changes(for: \.someComputedProperty) 
```

## Detailed Design

The `Observable` protocol, `@Observable` macro, and a handful of supporting types comprise the `Observation` module. As described below, this design allows adopters to use terse, straightforward syntax for simple cases, while allowing full control over the details the implementation when necessary.

### `Observable` protocol 

The core protocol for observation is `Observable`. `Observable`-conforming types define what is observable by registering changes and provide asynchronous sequences of transactions and changes to individual properties, isolated to a specific actor.

```swift
protocol Observable {
    /// Returns an asynchronous sequence of change transactions for the specified
    /// properties.
    nonisolated func changes<Isolation: Actor>(
        for properties: TrackedProperties<Self>,
        isolatedTo: Isolation
    ) -> ObservedChanges<Self, Isolation>
      
    /// Returns an asynchronous sequence of changes for the specified key path.
    nonisolated func values<Member: Sendable>(
        for keyPath: KeyPath<Self, Member>
    ) -> ObservedValues<Self, Member>
      
    /// Returns a set of tracked properties that represent the given key path.
    nonisolated static func dependencies(
        of keyPath: PartialKeyPath<Self>
    ) -> TrackedProperties<Self>
}
```

The first two protocol requirements need to be implemented by conforming types, either manually or by using the `@Observable` macro, described below. These two methods make use of `ObservationRegistrar` (*also* described below) to track changes and provide async sequences of changes and transactions.

In addition to these protocol requirements, `Observable` types must implement the semantic requirement of tracking each access and mutation to  observable properties. This tracking is also provided by using the `@Observable` macro, or can be implemented manually using the `access` and `withMutation` methods of a registrar.

The `Observable` protocol also implements extension methods that provide convenient access to transactions isolated to the main actor or tracking just a single key path.

```swift
extension Observable {
    /// Returns an asynchronous sequence of change transactions for the specified
    /// key path, isolated to the given actor.
    nonisolated func changes<Member, Isolation: Actor>(
        for keyPath: KeyPath<Self, Member>,
        isolatedTo: Isolation
    ) -> ObservedChanges<Self, Delivery>
        
    /// Returns an asynchronous sequence of change transactions for the specified
    /// properties, isolated to the main actor.
    nonisolated func changes(
        for properties: TrackedProperties<Self>
    ) -> ObservedChanges<Self, MainActor.ActorType>
      
    /// Returns an asynchronous sequence of change transactions for the specified
    /// key path, isolated to the main actor.
    public nonisolated func changes<Member>(
        for keyPath: KeyPath<Self, Member>
    ) -> ObservedChanges<Self, MainActor.ActorType>
    
    // Default implementation returns `[keyPath]`.
    public nonisolated static func dependencies(
        of keyPath: PartialKeyPath<Self>
    ) -> TrackedProperties<Self>
}
```

The default implementation for `dependencies(of:)` returns a `TrackedProperties` type constructed with the given key path. This function is expected to be implemented in types when read only computed key paths are used, as seen in the `someComputedProperty` example above. 

It is possible that the dependencies could be calculated via the macro synthesis. This is an option that can be incorporated into the proposal, however automatically tracking them is not possible without macro support to modify function bodies. The half-step for automatic generation of `dependencies(of:)` would make (unless otherwise implemented) a default conformance where all computed properties would have the dependencies of all member (non-computed) properties. This would allow for developers to still override but in the default (non-override) case it would cause more updates than actually occurs.

The automatic synthesis of `dependencies(of:)` is a point of consideration for review.

### Macro Synthesis

In order to make implementation as simple as possible, the `@Observable` macro automatically synthesizes conformance to the `Observable` protocol, transforming annotated types into a type that can be observed. The `@Observable` macro does the following:

- declares conformance to the `Observable` protocol
- adds the required `Observable` method requirements
- adds a property for the registrar
- adds a storage abstraction for access tracking
- changes all stored properties into computed properties
- adds an initializer for the properties (with default values if they apply)

Since all of the code generated by the macro could be manually written, developers can write their own implementation when they need more fine-grained control.

```swift
@Observable final class Model {
    var order: Order?
    var account: Account?
  
    var alternateIconsUnlocked: Bool = false
    var allRecipesUnlocked: Bool = false
  
    func purchase(alternateIcons: Bool, allRecipes: Bool) {
        alternateIconsUnlocked = alternateIcons
        allRecipesUnlocked = allRecipes
    }
}
```

Expanding the macro for the previous example results in the following:

```swift
final class Model: Observable {
    internal let _$observationRegistrar = ObservationRegistrar<Model>()
    
    public nonisolated func changes<Isolation: Actor>(
        for properties: TrackedProperties<Model>, 
        isolatedTo: Delivery
    ) -> ObservedChanges<Model, Isolation> {
        _$observationRegistrar.changes(for: properties, isolation: isolation)
    }

    public nonisolated func values<Member: Sendable>(
        for keyPath: KeyPath<Model, Member>
    ) -> ObservedValues<Model, Member> {
        _$observationRegistrar.changes(for: keyPath)
    }

    private struct _$ObservationStorage {
        var order: Order?
        var account: Account?
  
        var alternateIconsUnlocked: Bool
        var allRecipesUnlocked: Bool
    }
  
    private var _$observationStorage: _$ObservationStorage

    init(order: Order? = nil, account: Account? = nil, alternateIconsUnlocked: Bool = false, allRecipesUnlocked: Bool = false) {
        _$observationStorage = _$ObservationStorage(order: order, account: account, alternateIconsUnlocked: alternateIconsUnlocked, allRecipesUnlocked: allRecipesUnlocked)
    }
  
    var order: Order? {
        get { 
            _$observationRegistrar.access(self, keyPath: \.order)
            return _$observationStorage.order
        }
        set {
            _$observationRegistrar.withMutation(self, keyPath: \.order) {
                _$observationStorage.order = newValue
            }
        }
    }
  
    var account: Account? {
        get { 
            _$observationRegistrar.access(self, keyPath: \.account)
            return _$observationStorage.account
        }
        set {
            _$observationRegistrar.withMutation(self, keyPath: \.account) {
                _$observationStorage.account = newValue
            }
        }
    }

    var alternateIconsUnlocked: Bool {
        get { 
            _$observationRegistrar.access(self, keyPath: \.alternateIconsUnlocked)
            return _$observationStorage.alternateIconsUnlocked
        }
        set {
            _$observationRegistrar.withMutation(self, keyPath: \.alternateIconsUnlocked) {
                _$observationStorage.alternateIconsUnlocked = newValue
            }
        }
    }

    var allRecipesUnlocked: Bool {
        get { 
            _$observationRegistrar.access(self, keyPath: \.allRecipesUnlocked)
            return _$observationStorage.allRecipesUnlocked
        }
        set {
            _$observationRegistrar.withMutation(self, keyPath: \.allRecipesUnlocked) {
                _$observationStorage.allRecipesUnlocked = newValue
            }
        }
    }
  
    init() { }
  
    func purchase(alternateIcons: Bool, allRecipes: Bool) {
        alternateIconsUnlocked = alternateIcons
        allRecipesUnlocked = allRecipes
    }
}
```

When a property does not have a default value that corresponding argument in the initializer does not have a default value. This means that the following example has a macro synthesized initializer of `init(a: Int, b: Int = 3)`.

```swift
@Observable final class InitializationSample {
    var a: Int
    var b: Int = 3
}
```

Because the memberwise initializer and backing storage are generated together, the initializer is able to initialize that storage. User-defined initializers should call the generated memberwise initializer instead of attempting to initialize the properties directly.

Due to limitations with macros all fields must have type information; this restriction may be able to be lifted later when the type system grows a mechanism to detect inferred types.

```swift
@Observable final class InitializationSample {
    var a: Int
    var b = 3 // this will emit an error: "@Observable requires properties to have type annotations. b is missing a non-inferred type"
}
```

Properties that have `willSet` and `didSet` property observations will be supported.

```swift
@Observable final class PropertyExample {
    var a: Int {
        willSet { print("will set triggered") }
        didSet { print("did set triggered") }
    }
}
```

Transforms into the macro expansion for the property `a` as follows:

```swift
var a: Int {
    get {
        _$observationRegistrar.access(self, keyPath: \.a)
        return _$observationStorage.a 
    }
    set {
        print("will set triggered")
        _$observationRegistrar.withMutation(of: self, keyPath: \.a) {
            _$observationStorage.a = newValue
        }
        print("did set triggered")
    }
}
```

### `TrackedProperties`

When observing changes to a type, there may be associated side effects to members that are not publicly visible. The `TrackedProperties` type allows for internal key paths to be included in a transaction without being exposed beyond their visibility. 

```swift
public struct TrackedProperties<Root>: ExpressibleByArrayLiteral, @unchecked Sendable {
    public typealias ArrayLiteralElement = PartialKeyPath<Root>
        
    public init()
    
    public init(_ sequence: some Sequence<PartialKeyPath<Root>>)
      
    public init(arrayLiteral elements: PartialKeyPath<Root>...)
      
    public func contains(_ member: PartialKeyPath<Root>) -> Bool
      
    public mutating func insert(_ newMember: PartialKeyPath<Root>) -> Bool
  
    public mutating func remove(_ member: PartialKeyPath<Root>)
}

extension TrackedProperties where Root: Observable {
    public init(dependent: TrackedProperties<Root>)
}
```

### `ObservationRegistrar`

`ObservationRegistrar` is the default storage for tracking and providing access to changes. The `@Observable` macro synthesizes a registrar to handle these mechanisms as a generalized feature. By default, the registrar is thread safe and must be as `Sendable` as containers could potentially be; therefore it must be designed to handle independent isolation for all actions.

```swift
public struct ObservationRegistrar<Subject: Observable>: Sendable {
    public init()
      
    public func access<Member>(
        _ subject: Subject, 
        keyPath: KeyPath<Subject, Member>
    )
      
    public func willSet<Member>(
        _ subject: Subject, 
        keyPath: KeyPath<Subject, Member>
    )
      
    public func didSet<Member>(
        _ subject: Subject, 
        keyPath: KeyPath<Subject, Member>
    )
      
    public func withMutation<Member, T>(
        of subject: Subject, 
        keyPath: KeyPath<Subject, Member>, 
        _ mutation: () throws -> T
    ) rethrows -> T
      
    public func changes<Isolation: Actor>(
        for properties: TrackedProperties<Subject>, 
        isolatedTo: Isolation
    ) -> ObservedChanges<Subject, Isolation>
      
    public func values<Member: Sendable>(
        for keyPath: KeyPath<Subject, Member>
    ) -> ObservedValues<Subject, Member>
}
```

The `access` and `withMutation` methods identify transactional accesses. These methods register access to the `ObservationTracking` system for access and identify mutations to the transactions registered for observers.

### `ObservationTracking`

In order to provide scoped observation, the `ObservationTracking` type provides a method to capture accesses to properties within a given scope and then call out upon the first change to any of those properties. This API is the primary mechanism in which UI interactions can be built. Specifically this will be used by SwiftUI to provide updates for views given specific property access in the rendering of `var body: some View` scopes. More detail will be expanded later in the SDK impact section.

```swift
public struct ObservationTracking {
    public static func withTracking<T>(
        _ apply: () -> T, 
        onChange: @autoclosure () -> @Sendable () -> Void
    ) -> T
}
```

The `withTracking` method takes two closures where any access to any property within the apply closure will indicate that property on that specific instance should participate in changes informed to the `onChange` closure.

```swift
@Observable final class Car {
    var name: String
    var awards: [Award]
}

let cars: [Car] = ...

func render() {
    ObservationTracking.withTracking {
        for car in cars {
            print(car.name)
        }
    } onChange {
        scheduleRender()
    }
}
```

In the example above, the `render` function accesses each car's `name` property. When any of the cars change `name`, the `onChange` closure is then called on the first change. However, if a car has an award added, the `onChange` call won't happen. This design supports uses that require implicit observation tracking, such as SwiftUI, ensuring that views are only updated in response to relevant changes.

### `ObservedChanges` and `ObservedValues`

The two included asynchronous sequences provide access to transactions based on a `TrackedProperties` instance or to changes based on a key path, respectively. The two sequences have slightly different semantics.

The `ObservedChanges` sequence is the result of calling `changes(for:isolatedTo:)` on an observable type and passing one or more key paths as a `TrackedProperties` instance. The isolating actor that you pass (or the main actor, by default) determines how changes are coalesced. Any changes between suspension points on the isolating actor, whether to one property or multiple properties, only provide a single transaction event. Sequence elements are `ObservedChange` instances, which you can query to see if a _specific_ property has changed. When the observed type is `Sendable`, an `ObservedChange` also includes the observed subject, in order to simplify accessing the updated properties.

The `ObservedValues` sequence, on the other hand, is the result of calling `values(for:)`, passing a single key path to observe. Instead of coalescing changes in reference to an isolating actor, `ObservedValues` provides changed values that are coalesced at each suspension during iteration. Since the iterator isn't `Sendable`, that behavior implicitly isolates changes to the current actor.

```swift
public struct ObservedChange<Subject: Observable>: @unchecked Sendable {
    public func contains(_ member: PartialKeyPath<Subject>) -> Bool
}

extension ObservedChange where Subject: Sendable {
    public var subject: Subject { get }
}

/// An asynchronous sequence of observed changes.
public struct ObservedChanges<Subject: Observable, Delivery: Actor>: AsyncSequence {
    public typealias Element = ObservedChange<Subject>
  
    public struct Iterator: AsyncIteratorProtocol {
        public mutating func next() async -> Element?
    }
    
    public func makeAsyncIterator() -> Iterator
}

extension ObservedChanges: @unchecked Sendable where Subject: Sendable { }
@available(*, unavailable)
extension ObservedChanges.Iterator: Sendable { }

/// An asynchronous sequence of observed changes.
public struct ObservedValues<Subject: Observable, Element: Sendable>: AsyncSequence {  
    public struct Iterator: AsyncIteratorProtocol {
        public mutating func next() async -> Element?
    }
    
    public func makeAsyncIterator() -> Iterator
}

extension ObservedValues: @unchecked Sendable where Subject: Sendable { }
@available(*, unavailable)
extension ObservedChanges.Iterator: Sendable { }
```

## SDK Impact (a preview of SwiftUI interaction)

Using existing systems like `ObservableObject` there are a number of edge cases that can be surprising unless developers really have an in-depth view to SwiftUI. Formalizing observation can make these edge cases considerably more approachable by reducing the complexity of the different systems needed to be understood. 

The following is adapted from the [Fruta sample app](https://developer.apple.com/documentation/swiftui/fruta_building_a_feature-rich_app_with_swiftui), modified for clarity:

```swift
final class Model: ObservableObject {
    @Published var order: Order?
    @Published var account: Account?
    
    var hasAccount: Bool {
        return userCredential != nil && account != nil
    }
    
    @Published var favoriteSmoothieIDs = Set<Smoothie.ID>()
    @Published var selectedSmoothieID: Smoothie.ID?
    
    @Published var searchString = ""
    
    @Published var isApplePayEnabled = true
    @Published var allRecipesUnlocked = false
    @Published var unlockAllRecipesProduct: Product?
}

struct SmoothieList: View {
    var smoothies: [Smoothie]
    @ObservedObject var model: Model
    
    var listedSmoothies: [Smoothie] {
        smoothies
            .filter { $0.matches(model.searchString) }
            .sorted(by: { $0.title.localizedCompare($1.title) == .orderedAscending })
    }
    
    var body: some View {
        List(listedSmoothies) { smoothie in
            ...
        }
    }
} 
```

The `@Published` identifies each field that participates to changes in the object, however it does not provide any differentiation for those changes. This means that from SwiftUI's perspective, a change to `order` effects things using `hasAccount`. This unfortunately means that there are additional layouts, rendering and updates created. The proposed API cannot only reduce some of the `@Published` repetition but also simplify the SwiftUI view code too!

The previous example can then be written as:

```swift
@Observable final class Model {
    var order: Order?
    var account: Account?
    
    var hasAccount: Bool {
        return userCredential != nil && account != nil
    }
    
    var favoriteSmoothieIDs: Set<Smoothie.ID> = []
    var selectedSmoothieID: Smoothie.ID?
    
    var searchString: String = ""
    
    var isApplePayEnabled: Bool = true
    var allRecipesUnlocked: Bool = false
    var unlockAllRecipesProduct: Product?
}

struct SmoothieList: View {
    var smoothies: [Smoothie]
    var model: Model
    
    var listedSmoothies: [Smoothie] {
        smoothies
            .filter { $0.matches(model.searchString) }
            .sorted(by: { $0.title.localizedCompare($1.title) == .orderedAscending })
    }
    
    var body: some View {
        List(listedSmoothies) { smoothie in
            ...
        }
    }
} 
```

There are some other interesting differences that come up; for example - tracking observation of access within a view can be applied to an Array, an Optional, or even a custom type. This opens up new and interesting ways developers can utilize SwiftUI more easily.

This is a potential future direction for SwiftUI but is not part of this proposal.

## Source compatibility

This proposal is additive and provides no impact to existing source code.

## Effect on ABI stability

This proposal is additive and no impact is made upon existing ABI stability. This does have implication to the marking of inline to functions and back-porting of this feature. In the cases where it is determined to be performance critical to the distribution of change events the methods will be marked as inlineable. 

Changing a type from not observable to `@Observable` has the same ABI impact as changing a property from stored to computed (which is not ABI breaking). Removing `@Observable` not only transitions from computed to stored properties but also removes a conformance (which is ABI breaking).

## Effect on API resilience

This proposal is additive and no impact is made upon existing API resilience. The types that adopt `@Observable` cannot remove it without breaking API contract.

## Location of API

This API will be housed in a module that is part of the swift language but outside of the standard library. To use this module `import Observation` must be used (and provisionally using the preview `import _Observation`).

## Future Directions

The initial implementation will not track changes for key paths that have more than one layer of components. For example, key paths such as `\.account` would work, but `\.account.name` would not. This feature would be possible as soon as the standard library offers a mechanism to iterate components of a key path. Since there is no way to determine this yet, key paths that have more than one component will never observe any changes.

Another area of focus for future enhancements is support for observable `actor` types. This would require specific handling for key paths that currently does not exist for actors.

The current requirement that all stored properties declarations include a type could be lifted in the future, if macros are able to provide semantic type information for properties. This would allow property declarations like `var a = 3`.

Finally, once variadic generics are available, an observation mechanism could be added to observe multiple key paths as an `AsyncSequence`. 

## Alternatives considered

An earlier consideration instead of defining transactions used direct will/did events to the observer. This, albeit being more direct, promoted mechanisms that did not offer the correct granularity for supporting the required synchronization between dependent members. It was determined that building transactions are worth the extra complexity to encourage developers using the API to consider what models for transactionality they need, instead of thinking just in terms of will/did events.

Another design included an `Observer` protocol that could be used to build callback-style observer types. This has been eliminated in favor of the `AsyncSequence` approach.

The `ObservedChange` type could have the `Sendable` requirement relaxed by making the type only conditionally `Sendable` and then allowing access to the subject in all cases; however this poses some restriction to the internal implementations and may have a hole in the sendable nature of the type. Since it is viewed that accessing values is most commonly by one property the values `AsyncSequence` fills most of that role and for cases where more than one field is needed to be accessed on a given actor the iteration can be done with a weak reference to the observable subject.

## Acknowledgments

* [Holly Borla](https://github.com/hborla) - For providing fantastic ideas on how to implement supporting infrastructure to this pitch
* [Pavel Yaskevich](https://github.com/xedin) - For tirelessly iterating on prototypes for supporting compiler features
* Rishi Verma - For bouncing ideas and helping with the design of integrating this idea into other work
* [Kyle Macomber](https://github.com/kylemacomber) - For connecting resources and providing useful feedback
* Matt Ricketson - For helping highlight some of the inner guts of SwiftUI

## Related systems

* [Swift `Combine.ObservableObject`](https://developer.apple.com/documentation/combine/observableobject/)
* [Objective-C Key Value Observing](https://developer.apple.com/documentation/objectivec/nsobject/nskeyvalueobserving?language=objc)
* [C# `IObservable`](https://learn.microsoft.com/en-us/dotnet/api/system.iobservable-1?view=net-6.0)
* [Rust `Trait rx::Observable`](https://docs.rs/rx/latest/rx/trait.Observable.html)
* [Java `Observable`](https://docs.oracle.com/javase/7/docs/api/java/util/Observable.html)
* [Kotlin `observable`](https://kotlinlang.org/api/latest/jvm/stdlib/kotlin.properties/-delegates/observable.html)