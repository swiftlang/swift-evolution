# Language support for BufferView
<!-- markdown-toc start - Don't edit this section. Run M-x markdown-toc-refresh-toc -->
**Table of Contents**

- [Introduction](#introduction)
- [Motivation](#motivation)
- [Solution](#solution)
- [Basic (Unsafe) BufferView Implementation](#basic-unsafe-bufferview-implementation)
- [Non-copyable BufferView](#non-copyable-bufferview)
- [Non-copyable BufferView with 'borrowing' and 'mutating' properties](#non-copyable-bufferview-with-borrowing-and-mutating-properties)
- [Non-escaping BufferView](#non-escaping-bufferview)
- [Non-escaping BufferView with lifetime-dependent function results](#non-escaping-bufferview-with-lifetime-dependent-function-results)
- [Non-escaping BufferView with extended access around lifetime-dependent results](#non-escaping-bufferview-with-extended-access-around-lifetime-dependent-results)
- [Non-escaping BufferView with generalized lifetime-dependent function results](#non-escaping-bufferview-with-generalized-lifetime-dependent-function-results)
- [Future work](#future-work)
- [Acknowledgements](#acknowledgements)

<!-- markdown-toc end -->

## Introduction

This roadmap discusses the language and compiler features required to implement a "BufferView" type in Swift. Non-copyable and non-escaping types provide the language foundation for BufferView. These new type constraints provide stronger guarantees about the ownership and lifetime of their values. Such guarantees make it possible to design safe, efficient libraries based on a "container/view" programming pattern. Although, we expect this programming pattern to be broadly applicable, BufferView is a particularly important use case because Swift developers need safe and efficient views over a container's contiguously stored memory.

Swift BufferViews have been informally discussed as a solution to problems that arise with unsafe pointers. This roadmap takes us through a hypothetical design of BufferView one language feature at a time. Each section describes a design variation on BufferView based only the language features that have been introduced so far. We start by introducing unsafe BufferView, followed by non-copyable (a.k.a. move-only) BufferView. They are shown here as examples of what is possible with limited language support, but because of their limitations, we do not intend to make these variants publicly available. The first shipping design of BufferView will likely be based on non-escaping types. Non-escaping BufferView continues to depend on the language features that we first introduce for non-copyable BufferView. Subsequent variations of non-escaping BufferView show how the safety and convenience of non-escaping BufferView can be incrementally improved as Swift gains support for expressing lifetime dependencies.

## Motivation

A container data type often needs to provide limited access to its underlying storage to a more general purpose API that consumes the data but is otherwise independent of the container type. In Swift, this is typically done by having the container provide a "slice" that conforms to the Collection protocol. Since slices depend on their container's storage, they need to keep their container alive by retaining a hidden reference. This incurs reference counting traffic, makes it impossible to reason about the container's lifetime independent of its slices, and is fundamentally incompatible with unmanaged storage. Consequently, developers who want to efficiently abstract over arbitrary storage need to drop down to unsafe pointer types:

```swift
    func parse(buffer: UnsafeRawBufferPointer) {
      // ... Do parsing work here ...
    }
     
    func parse(data: Data) {
      data.withUnsafeBytes {
        parse(buffer: $0)
      }
    }
         
    func parse(array: [UInt8]) {
      array.withUnsafeBytes {
        parse(buffer: $0)
      }
    }
         
    func parse<T: ContiguousBytes>(bytes: T) {
      bytes.withUnsafeBytes {
        parse(buffer: $0)
      }
    }
```

## Solution

BufferViews can be used instead to avoid multiple dangers inherent to unsafe pointers: use-after-free, out-of-bounds, type confusion, and simultaneous modification:

```swift
    func parse(buffer: BufferView<UInt8>) {
      // ... Do parsing work here ...
    }
     
    func parse(data: Data) {
      parse(buffer: data.bufferView)
    }
         
    func parse(array: [UInt8]) {
      parse(buffer: array.bufferView)
    }
         
    func parse<T: ContiguousBytes>(bytes: T) {
      parse(buffer: bytes.bufferView)
    }
```

BufferViews have a concrete representation that supports efficient access without requiring specialization on the parent container. This allows storage to be passed safely and efficiently across module boundaries.

BufferViews can also be used to reinterpret bitwise-copyable elements as a different bitwise-copyable type. This is safe as long as the in-memory bit pattern is a valid value of the new element type. Reinterpreting the buffer's element type cannot otherwise result in undefined behavior because bitwise-copyable types do not contain object references, and BufferViews cannot be directly passed to C APIs. Getting a C compatible pointer out of a BufferView requires calling `withUnsafeBufferPointer`. This introduces an optimization barrier that avoids undefined behavior that can occur when pointers of different types refer to the same memory.

In summary, BufferView
- allows existing unsafe APIs to be replaced with safe and efficient APIs
- enables more efficient storage techniques, such as stack allocation
- supports generalized, safe, efficient communication across module boundaries

New language features are needed to ensure that, when a container provides a BufferView, access to that view inherits the exclusivity and lifetime requirements of its container. Those requirements are laid out in John McCall's post: [Safe element ownership for lifetime-restricted buffer types](https://forums.swift.org/t/safe-element-ownership-for-lifetime-restricted-buffer-types/64405). The following example illustrates the basic exclusivity and lifetime restrictions:

```swift
    func parseSomeThings(_: borrowing BufferView<UInt8>?) ...
    func parseOtherThings(_: borrowing BufferView<UInt8>?) ...
    
    var globalView: BufferView<UInt8>? = nil

    func process(data: Data, views: inout Array<BufferView<UInt8>>) {
        let viewA = data.bufferView
        let viewB = data.bufferView
        parseSomeThings(viewA) // 🆗
        parseOtherThings(viewB) // 🆗
        data.append(0) // 🛑 Cannot modify viewed storage
        globalView = viewA // 🛑 Cannot assign a view to a global
        views.append(viewA) // 🛑 Cannot store a view
        return viewA // 🛑 Cannot return a view
    }
```

## Basic (Unsafe) BufferView Implementation

First we introduce an unsafe implementation of BufferView based on [`swift-foundation/Sources/FoundationEssentials/JSON/BufferView.swift`](https://github.com/apple/swift-foundation/blob/c519273cc3ccca98b1ab84e343688e9d138e21af/Sources/FoundationEssentials/JSON/BufferView.swift). Not all of these design details are relevant to this roadmap--they may change when BufferView is formally proposed. The purpose of showing a reference implementation here is to setup the running examples used throughout the following sections.

 ```swift
    public struct BufferViewIndex<Element> : Equatable, Hashable {
      public typealias Pointer = UnsafeRawPointer
     
      let _rawValue: Pointer
     
      public init(rawValue: Pointer) {
        _rawValue = rawValue
      }
    }
     
    extension BufferViewIndex : Strideable {
      public typealias Stride = Int
     
      public func distance(to other: BufferViewIndex) -> Int {
        _rawValue.distance(to: other._rawValue) / MemoryLayout<Element>.stride
      }
     
      public func advanced(by n: Int) -> BufferViewIndex {
        .init(rawValue: _rawValue.advanced(by: n &* MemoryLayout<Element>.stride))
      }
    }
     
    extension BufferViewIndex : Comparable {
      public static func < (lhs: BufferViewIndex, rhs: BufferViewIndex) -> Bool {
        lhs._rawValue < rhs._rawValue
      }
    }
     
    public struct MutableBufferViewIndex<Element> : Equatable, Hashable {
      public typealias Pointer = UnsafeMutableRawPointer
     
      let _rawValue: Pointer
     
      public init(rawValue: Pointer) {
        _rawValue = rawValue
      }
    }
     
    extension MutableBufferViewIndex : Strideable {
      public typealias Stride = Int
     
      public func distance(to other: MutableBufferViewIndex) -> Int {
        _rawValue.distance(to: other._rawValue) / MemoryLayout<Element>.stride
      }
     
      public func advanced(by n: Int) -> MutableBufferViewIndex {
        .init(rawValue: _rawValue.advanced(by: n &* MemoryLayout<Element>.stride))
      }
    }
     
    extension MutableBufferViewIndex : Comparable {
      public static func < (lhs: MutableBufferViewIndex, rhs: MutableBufferViewIndex) -> Bool {
        lhs._rawValue < rhs._rawValue
      }
    }
     
    public struct BufferView<Element> {
      // BufferView is self-slicing. The implementation is omitted for our purpose.
      public typealias SubSequence = BufferView<Element>

      public typealias Index = BufferViewIndex<Element>
      public typealias Pointer = Index.Pointer

      let start: Index
      let count: Int
     
      // Initialization is internal because a user-specified count is unsafe.
      init(start index: Index, count: Int) {
        precondition(count >= 0, "Count must not be negative")
        self.start = index
        self.count = count
      }
     
      init(baseAddress: Pointer, count: Int) {
        self.init(start: .init(rawValue: baseAddress), count: count)
      }

      // An unsafe public API serves as the low-level entry point for
      // BufferView creation.
      public static func withTemporaryView<ResultType>(
        unsafeBaseAddress: Pointer, unsafeCount: Int,
        _ body: (borrowing BufferView<Element>) throws -> ResultType
      ) rethrows -> ResultType {
        try body(BufferView<Element>(baseAddress: unsafeBaseAddress,
                                     count: unsafeCount))
      }

      public var startIndex: Index { start }
     
      public var endIndex: Index { start.advanced(by: count) }

      func _checkBounds(_ position: Index) {
        precondition(startIndex <= position && position < endIndex, "Index out of bounds")
      }
     
      public subscript(position: Index) -> Element {
        get {
          _checkBounds(position)
          return self[unchecked: position]
        }
      }
     
      public subscript(unchecked position: Index) -> Element {
        get {
          return position._rawValue.loadUnaligned(as: Element.self)
        }
      }
    }
     
    public struct MutableBufferView<Element> {
      // MutableBufferView is self-slicing. The implementation is omitted for
      // our purpose.
      public typealias SubSequence = MutableBufferView<Element>

      public typealias Index = MutableBufferViewIndex<Element>
      public typealias Pointer = Index.Pointer
     
      let start: Index
      let count: Int
     
      // Initialization is internal because a user-specified count is unsafe.
      init(start index: Index, count: Int) {
        precondition(count >= 0, "Count must not be negative")
        self.start = index
        self.count = count
      }

      // An unsafe public initializer serves as an escape hatch.
      init(unsafeBaseAddress: Pointer, unsafeCount: Int) {
        self.init(start: .init(rawValue: unsafeBaseAddress), count: unsafeCount)
      }
     
      // An unsafe public API serves as the low-level entry point for
      // BufferView creation.
      public static func withTemporaryView<ResultType>(
        unsafeBaseAddress: Pointer, unsafeCount: Int,
        _ body: (inout MutableBufferView<Element>) throws -> ResultType
      ) rethrows -> ResultType {
        var view = MutableBufferView<Element>(baseAddress: unsafeBaseAddress, count: unsafeCount)
        return try body(&view)
      }
     
      public var startIndex: Index { start }
     
      public var endIndex: Index { start.advanced(by: count) }
     
      func _checkBounds(_ position: Index) {
        precondition(startIndex <= position && position < endIndex, "Index out of bounds")
      }
     
      public subscript(position: Index) -> Element {
        get {
          _checkBounds(position)
          return self[unchecked: position]
        }
        nonmutating set(newValue) {
          _checkBounds(position)
          self[unchecked: position] = newValue
        }
      }
     
      public subscript(unchecked position: Index) -> Element {
        get {
          position._rawValue.load(as: Element.self)
        }
        nonmutating set(newValue) {
          position._rawValue.storeBytes(of: newValue, as: Element.self)
        }
      }
    }
```

The "unsafe" `BufferView` design achieves as much safety as possible without relying on new language features. Its interface avoids exposing its underlying unsafe pointer, which prevents access to the view's storage beyond its lifetime. The unsafe pointer is a private property within the `BufferViewIndex` type, and an index cannot be used to access memory without an instance of the `BufferView` from which is was derived. The `BufferView` initializer is also internal, so creating a view requires calling the static `withTemporaryView` API. This provides safe access to the storage as long as the view itself is not copied to a storage location that outlives `withTemporaryView`:

```swift
    BufferView<UInt8>.withTemporaryView(unsafeBaseAddress: rawPointer, unsafeCount: count) {
      view in
      view[view.startIndex] // safe access within the closure
      // ⚠️ here an escaping closure captures the view, causing it to escape withTemporaryView.
      return { view[view.startIndex] }
    }
```

## Non-copyable BufferView

A non-copyable implementation of BufferView is mostly possible with language features available in Swift 5.9. See [SE-0390: Noncopyable structs and enums](https://github.com/apple/swift-evolution/blob/b313275b0ac8ffaa39db51189dc32a3a38d52420/proposals/0390-noncopyable-structs-and-enums.md). Here we show how a container can provide a BufferView for a limited scope, meeting both the exclusivity and lifetime requirements for a view of the Container's storage. Despite meeting the most important safety requirements, non-copyable views have usability limitations, which, as we'll see later, make them undesirable, even as an initial design.

### Usage

By convention, views are always borrowed in this model, which prevents them from escaping the scope of the closure passed to `withTemporaryView`. Any attempt to escape the 'view' would necessarily result in an illegal copy:

```swift
    // Make BufferView non-copyable by default.
    public struct BufferView<Element> : ~Copyable {
      //...

      // An unsafe public API serves as the low-level entry point for
      // BufferView creation.
      //
      // ✨BufferView is initially provided as a borrowed value.
      public static func withTemporaryView<ResultType>(
        unsafeBaseAddress: Pointer, unsafeCount: Int,
        _ body: (borrowing BufferView<Element>) throws -> ResultType
      ) rethrows -> ResultType {
        try body(BufferView<Element>(baseAddress: unsafeBaseAddress,
                                     count: unsafeCount))
      }
    }
    
    func borrowingLifetimeIsSafe(count: Int) -> BufferView<UInt8>  {
      let rawPointer =
        UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
      defer { rawPointer.deallocate() }

      return BufferView<UInt8>.withTemporaryView(unsafeBaseAddress: rawPointer, unsafeCount: count) {
        // 🛑 Non-copyable value 'view' is copied
        view in return view
      }
    }
```

Stack allocated memory can, therefore, safely be exposed:

```swift
    public func withTemporaryAllocation<T, R>(
    of type: T.Type,
      capacity: Int,
      _ body: (BufferView<T>) throws -> R
    ) rethrows -> R {
      return try withUnsafeTemporaryAllocation(
        of: type,
        capacity: capacity,
      ) { buffer in
        return try BufferView<T>.withTemporaryView(
          unsafeBaseAddress: buffer.baseAddress!, unsafeCount: buffer.count, body)
      }
    }
```

A Container type manages the underlying storage and provides BufferViews. In this example, the Container itself is non-copyable because it holds a pointer. The container could, however, easily be copyable and refer to reference-counted storage. A non-copyable view is lifetime safe regardless of the storage strategy.

```swift
    public struct Container : ~Copyable {
      var rawPointer: UnsafeMutableRawPointer
      var count: Int

      // The details of allocation and deallocation are irrelevant to
      // BufferView.
      public init(count: Int) {
        rawPointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
      }
     
      deinit {
        rawPointer.deallocate()
      }

      // ✨ A borrowing closure-taking method enforces read-only access to 'self'
      // for the duration of the closure body.
      public borrowing func withBufferView<ResultType>(
        _ body: (borrowing BufferView<UInt8>) throws -> ResultType
      ) rethrows -> ResultType {
        defer { withExtendedLifetime(self){} }
        return try BufferView<UInt8>.withTemporaryView(
          unsafeBaseAddress: rawPointer, unsafeCount: count, body)
      }

      // ✨ A mutating closure-taking method enforces exclusive access to 'self'
      // for the duration of the closure body.
      public mutating func withMutableBufferView<ResultType>(
        _ body: (inout MutableBufferView<UInt8>) throws -> ResultType
      ) rethrows -> ResultType {
        defer { withExtendedLifetime(self){} }
        return try MutableBufferView<UInt8>.withTemporaryView(
          unsafeBaseAddress: rawPointer, unsafeCount: count, body)
      }
    }
```

### Benefits

- Safe view lifetime

- Exclusive access to the container's storage

- Supports mutable view elements

### Requirements

- `~Copyable` concrete type declaration [Available in Swift 5.9]

- `borrowing` parameter modifier for view-taking APIs [Available in Swift 5.9]

- `~Copyable` generic types (conditionally copyable generics) [TBD]

- `BitwiseCopyable` constraint for some mutable and consumable view APIs [TBD]

### Limitation: Future compatibility with copyable views

Each section in this roadmap lists a set of limitations that require more language features to overcome. Most of those limitations can only be overcome by eventually making BufferView a copyable (but non-escaping) type. Adding the Copyable capability after a shipping non-copyable BufferView is problematic both because it significantly affects the design of APIs that will be built on top of BufferView, and because it can introduce source incompatibilities.

Once support for dynamically casting non-copyable types is introduced, the following example will compile, but the dynamic cast will fail. If BufferView later becomes Copyable, the code will still compile, but the cast will succeed, leading to a different result:

```swift
    func readBorrowedView(c: Container) -> UInt8? {
      c.withBufferView { view in
        // cast fails if BufferView is NonCopyable
        guard let any = view as? Any else { return nil }
        let view = any as! BufferView<UInt8>
        return view[view.startIndex]
      }
    }
```

Today, this example raises an error because it's impossible to refine a non-copyable type. But that limitation will be lifted when generic support for NonCopyable types is implemented.

### Limitation: unsafe view construction

The reference implementation of BufferView allows views to be constructed wherever an unsafe pointer is available without any explicit dependence on the container's lifetime. This makes the initializer an inherently unsafe operation.

```swift
    func initializationIsUnsafe(count: Int) -> BufferView<UInt8> {
      consuming container = Container(count: count)

      // ⚠️ A pointer to freed memory persists in the returned view.
      return BufferView<UInt8>(unsafeBaseAddress: container.rawPointer, unsafeCount: count)
    }
```

### Limitation: composition

Embedding a view within other abstractions requires referencing the view from a stored property. This is currently impossible with borrowed values:

```swift
    struct Scanner {
      let bytes: BufferView<UInt8>
      var cursor: BufferViewIndex<UInt8>?
     
      func read() -> UInt8 { bytes[cursor!] }
    }
    
    func borrowingDoesNotCompose(c: Container) -> UInt8 {
      c.withBufferView { view in
        // 🛑 NonCopyable value is copied
        var scanner = Scanner(bytes: view)
        scanner.cursor = view.startIndex
        return scanner.read()
      }
    }
```

## Non-copyable BufferView with 'borrowing' and 'mutating' properties

The most problematic restriction on non-copyable BufferViews is their lack of composability that results from being unable to store a borrowed value in a property. An important reason for exposing a BufferView outside of its container is so that other code can reference the same storage via a different abstraction. Expressing any useful abstraction on top of that view requires embedding the view using a stored property. This restriction can be lifted by adding language support for [`borrowing` and `mutating` properties](https://forums.swift.org/t/pitch-borrow-and-inout-declaration-keywords/62366).

These examples assume that variable declarations also support ownership controls: `borrowing`, `mutating`, `consuming`, along with the operators: `borrow`, `consume`, and `copy`. These ownership controls clarify the proposed programming model, but are are not otherwise central to this roadmap. For background, see [SE-0377: borrowing and consuming parameter ownership modifiers](https://github.com/apple/swift-evolution/blob/b313275b0ac8ffaa39db51189dc32a3a38d52420/proposals/0377-parameter-ownership-modifiers.md) and Joe Groff's post on [Selective control of implicit copying behavior: `take`, `borrow`, and `copy` operators, `@noImplicitCopy`](https://forums.swift.org/t/selective-control-of-implicit-copying-behavior-take-borrow-and-copy-operators-noimplicitcopy/60168).

Note that `borrowing` and `mutating` properties do not affect the implementation of BufferView or its container. They only unlock functionality on the provided view.

### Composition using a 'borrowing' property

Composition via `borrowing` works as long as all the values are immutable:

```swift
    public struct BufferView<Element> : ~Copyable { ... }
    
    // 'struct Container' has the same implementation as above.

    // Scanner must be non-copyable because it contains a 'borrowing' property.
    struct Scanner : ~Copyable { // ~Copyable can be inferred
      // 'bytes' requires a 'borrowing' binding because it holds a non-copyable type
      borrowing bytes: BufferView<UInt8>
      let cursor: BufferViewIndex<UInt8>

      // This Scanner instance effectively depends on any non-copyable initializer argument.
      //
      // ✨ Initializers for types that contain a 'borrowing' property must be declared 'borrowing'
      // to confine the result of initializing the type to a 'borrowing' variable.
      borrowing
      public init(bytes view: borrowing BufferView<UInt8>, cursor: BufferViewIndex<UInt8>) {
        // 🆗 compiler ensures that 'bytes' is assigned to a borrowed argument
        self.bytes = view
        self.cursor = cursor
      }

      func read() -> UInt8 { bytes[cursor!] }
    }
     
    func borrowingComposition(c: borrowing Container) -> UInt8 {
      c.withBufferView { view in // view is borrowed inside the closure
        // 🆗 'view' is copied into 'Scanner.init'
        // Locals that propagate a borrowed non-copyable type require a 'borrowing' binding.
        borrowing scanner = Scanner(bytes: view, cursor: view.startIndex)
        return scanner.read()
      }
    }
```

### Composition using a 'mutating' property

Composition via `mutating` works as long as all values are passed `inout`, which prevents simultaneous modification:

```swift
    // Encoder must be non-copyable because it contains a 'mutating' property.
    struct Encoder : ~Copyable { // ~Copyable can be inferred
      // 'bytes' requires a 'mutating' binding because it holds a non-copyable type
      mutating bytes: MutableBufferView<UInt8>
      var cursor: MutableBufferViewIndex<UInt8>? = nil
     
      // This Encoder instance effectively depends on any non-copyable initializer argument.
      //
      // ✨Initializers for types that contain a 'mutating' property must be declared 'mutating'
      // to confine the result of to an 'inout' argument or 'mutating' variable.
      public mutating init(bytes view: inout MutableBufferView<UInt8>) {
        self.bytes = view
      }
      
      func write(value: UInt8) { bytes[cursor!] = value }
    }
     
    func mutatingComposition(c: inout Container) {
      c.withMutableBufferView { (view : inout MutableBufferView<UInt8>) in
        // 🆗 inout 'view' is exclusively modified in this scope via 'Encoder.init'
        // Locals that exclusively modify a non-copyable type require a 'mutating' binding.
        mutating encoder = Encoder(bytes: &view)
        encoder.cursor = view.startIndex
        encoder.write(value: 3)

        // 🛑 simultaneous access to `view`
        mutating anotherEncoder = Encoder(bytes: &view)
      }
    }
```

### Requirements

- Type system rules for `borrowing` and `mutating` stored properties.

- Allow the `borrowing` keyword on an initializer. Ensure that the
  result is always passed `borrowing` or assigned to a `borrowing` variable.

- Allow the `mutating` keyword on an initializer. Ensure that the
  result is always passed `inout` or assigned to a `mutating` variable.

- Compiler enforcement of access to `borrowing` and `mutating` properties so
  that accessing the property happens within an enforced local exclusivity scope.

- Compiler support for assigning the result of a `borrowing` or `mutating` initializer into a
  `borrowing` or `mutating` local variable. The exclusive access on the
  initializer's arguments must be extended across the variable's lexical scope.

### Limitation: mutable aggregates

The limitation that immutable values must be borrowed makes patterns such as updating an index hard:

```swift
    struct Scanner : ~Copyable { // ~Copyable can be inferred
      borrowing bytes: BufferView<UInt8>
      // Updating the cursor requires a mutable scanner.
      var cursor: BufferViewIndex<UInt8>?

      init(bytes view: borrowing BufferView<UInt8>) {
        self.bytes = view
      }
     
      func read() -> UInt8 { bytes[cursor!] }
    }

    func borrowingCompositionCannotMutate(c: borrowing Container) -> UInt8 {
      c.withBufferView { view in // view is borrowed inside the closure
        borrowing scanner = Scanner(bytes: view)
        // 🛑 cannot assign to value: 'scanner' is a 'let' constant
        scanner.cursor = view.startIndex
        return scanner.read()
      }
    }
```

### Limitation: borrowing does not restrict the lifetime of a copyable view

The solution to the mutability problem above is to allow BufferView to be copied. But as soon as we do that, the `borrowing` keyword no longer suffices to enforce lifetime dependence:

```swift
    func borrowingMayEscape(c: borrowing Container) -> BufferView<UInt8> {
      c.withBufferView { view in // view is borrowed inside the closure
        borrowing scanner = Scanner(bytes: view)
        // ⚠️ explicit copy is allowed
        return copy scanner.bytes
      }
    }
```

The solution is to continue enforcing the lifetime dependence of a BufferView as part of its type without suppressing copyability. In the next section, we see how non-escaping types provide sufficient lifetime constraints without relying on a `borrowing` property.

## Non-escaping BufferView

While view composition based on `borrowing` and `mutating` properties improves usability, severe limitations remain that are inherent to a non-copyable BufferViews. Support for *non-escaping types* can overcome these limitations.  Joe Groff proposed [generalized nonescaping arguments](https://forums.swift.org/t/a-roadmap-for-improving-swift-performance-predictability-arc-improvements-and-ownership-control/54206#generalized-nonescaping-arguments-6) in the performance predictability roadmap. Non-escaping types further generalize this feature, bringing it into the generic type system and improving safety and convenience.

We can consider types to have an "Escapable" capability by default that can be suppressed in the same way that a type's Copyable capability can be suppressed. Any variable whose type is non-escaping in the current context cannot escape the scope of its declaration. This allows immutable views to be copied and allows mutable views to be forwarded. Immutable views can even be copied implicitly because they no longer require a `borrowing` binding. Copying a BufferView merely copies the pointer and count values, so there's no benefit to forcing explicit copies.

### Usage

Here, both the `BufferView` and `BufferViewIndex` types are copyable but non-escaping. The closure-taking APIs that initially provide a view no longer need the `borrowing` keyword, so the view may be implicitly copied within the closure:

```swift
    public struct BufferViewIndex<Element> : ~Escapable {
      // ...
    }

    public struct BufferView<Element> : ~Escapable {
      // An unsafe public API serves as the low-level entry point for
      // BufferView creation.
      //
      // ✨ The closure parameter is no longer 'borrowing'.
      public static func withTemporaryView<ResultType>(
        unsafeBaseAddress: Pointer, unsafeCount: Int,
        _ body: (BufferView<Element>) throws -> ResultType
      ) rethrows -> ResultType {
        try body(BufferView<Element>(baseAddress: unsafeBaseAddress,
                                     count: unsafeCount))
      }
    }
    
    public struct Container : ~Copyable {
      var rawPointer: UnsafeMutableRawPointer
      var count: Int
      
      //...
      
      // The closure's BufferView parameter is inferred from its type to be non-escaping.
      // This forces all access to the view and its copies to be within the closure body.
      public func withBufferView<ResultType>(
        // ✨ The closure parameter is no longer 'borrowing'.
        _ body: (BufferView<UInt8>) throws -> ResultType
        ) rethrows -> ResultType {
        defer { withExtendedLifetime(self){} }
        return try BufferView<UInt8>.withTemporaryView(
          unsafeBaseAddress: rawPointer, unsafeCount: count, body)
      }
    }
```

```swift
    // Scanner must be non-escaping because it contains a non-escaping property.
    // Scanner is now Copyable.
    struct Scanner : ~Escapable { // ~Escapable can be inferred
      // BufferView can be stored in a property without borrowing.
      let bytes: BufferView<UInt8>
      var cursor: BufferViewIndex<UInt8>?
      func read() -> UInt8 { bytes[cursor!] }
   }
      
    func borrowingComposition(container: borrowing Container) -> UInt8 {
      container.withBufferView { view in // view is non-escaping
        // 'scanner' inherits 'view's non-escaping constraint
        var scanner = Scanner(bytes: view)
        // 🆗 'scanner' is mutable
        scanner.cursor = view.startIndex
      }
    }
```

### MutableBufferViews are both non-escaping and non-copyable

Mutable views still need to be non-copyable to avoid simultaneous modification, which violates exclusivity rules. Making them non-escaping does, however, mean that a container can hand off ownership of the view. An owned non-escaping view is confined to the container's exclusive access scope without the need to pass it as an `inout` value:

```swift
    public struct MutableBufferView<Element> : ~Copyable, ~Escapable { ... }

    extension Container {
      // A mutating closure-taking method enforces exclusive access to 'self'
      // for the duration of the closure body.
      //
      // ✨ the closure takes a mutable view as 'consuming' rather than 'inout'
      public mutating func withMutableBufferView<ResultType>(
        _ body: (consuming MutableBufferView<UInt8>) throws -> ResultType
        ) rethrows -> ResultType {
        defer { withExtendedLifetime(self){} }
        var view = MutableBufferView<UInt8>(unsafeBaseAddress: rawPointer, unsafeCount: count)
        return try body(view)
      }
    }
```

Simultaneous modification of the mutable view is still protected by regular exclusivity enforcement:

```swift
    func simultaneousAccess(container: inout Container) -> () {
      container.withMutableView { mutableView in
        // 🛑 simultaneous access of 'mutableView' and 'borrowedView'
        borrowing viewB = mutableView
        copyTwo(from: viewB, &mutableView)
      }
    }

    // Assumes viewIn and viewOut are disjoint. (We don't need to read both
    // `viewIn` elements before writing any `viewOut` elements.)
    func copyTwo(from viewIn: BufferView<UInt8>, to viewOut: inout MutableBufferView<UInt8>) {
      viewOut[viewOut.startIndex] = viewIn[viewIn.startIndex]
      viewOut[viewOut.startIndex.advanced(by: 1)] = viewIn[viewIn.startIndex.advanced(by: 1)]
    }
```

### Requirements

- Generic type system support for conditionally non-escaping types (~Escapable)

- Inferred non-escaping parameters, local variables, and properties

### Limitation: consuming APIs

Some Collection-style APIs expect to consume self. No equivalent API exists that works with borrowed views:

```swift
    extension BufferView {
      public consuming func dropFirst() -> BufferView {
        // 🛑 Non-escapable value is returned
        return BufferView(start: start.advanced(by: 1), unsafeCount: count - 1)
      }
    }
```

## Non-escaping BufferView with lifetime-dependent function results

With non-escaping types, a value's lifetime restriction naturally propagates through function arguments, guaranteeing that the non-escaping argument does not escape the function body. But without being able to return a non-escaping value, BufferView still has usability limitations. To fix this, the compiler can recognize functions that return a non-escaping type, infer the argument that the result depends on, and propagate the lifetime restriction from the argument to the result.

Lifetime dependence will be inferred in two cases:

1. Nonescaping propagation: A function's result is lifetime-dependent if it takes a non-escaping type as an argument and returns that argument or another non-escaping value that transitively depends on that argument.

2. Nonescaping members: A method or computed property's result is lifetime-dependent on self if its result is non-escaping.

Lifetime inference must be determined solely from the function signature. In practice, therefore, non-escaping propagation is only inferred when the function has a single non-escaping argument, and nonescaping members are inferred only when the function has no non-escaping arguments.

For non-escaping propagation, the function implementation promises that the result transitively depends on the single non-escaping argument. The compiler can optionally perform diagnostics on the function body to verify the dependence. For nonescaping members, the method implementation promises that access to `self` is sufficient to safely access the nonescaping result. No verification is possible.

### Forwarding BufferViews through consuming APIs

Lifetime dependent methods support forwarding ownership of `self`. This allows updating a view without direct mutation. Revisiting to the `dropFirst` example, we see that the compiler can propagate any lifetime requirement on the consumed `self` argument to the resulting truncated view:

```swift
    extension BufferView {
      // The non-escaping result has an implicit dependence on non-escaping self.
      public consuming func dropFirst() -> Self {
        // 🆗 Implicit lifetime dependence from self -> self.start -> result.init()
        return BufferView(start: start.advanced(by: 1), count: count - 1)
      }
    }

    func scan(view: borrowing BufferView<UInt8>) { /*...*/ }

    func forwardView(c: Container) {
      c.withBufferView { view in
        // 🆗 'view' is implicitly copied before being consumed by 'dropFirst'.
        // The result of dropFirst inherits the 'view' argument's lifetime dependence.
        scan(view.dropFirst())
      }
    }
```

### Forwarding MutableBufferViews through consuming APIs

Mutable non-escaping views can also be forwarded through consuming APIs with some extra care not to simultaneously access the new and old views:

```swift
    extension MutableBufferView {
      // The non-escaping result has an implicit dependence on non-escaping self.
      public consuming func dropFirst() -> Self {
        // 🆗 Implicit lifetime dependence from self -> self.start -> result.init()
        //
        // ⚠️ Calling the internal initializer here is unsafe because effectively
        // copies the view behind the compiler's back, and MutableBufferView cannot
        // safely be copied. The public dropFirst is safe as a whole because the
        // returned view takes the place of the incoming view as the exclusive view
        // of its storage.
        return MutableBufferView(start: start.advanced(by: 1), count: count - 1)
      }
    }

    func scan(view: borrowing BufferView<UInt8>) { /*...*/ }
     
    func consume(c: inout Container) {
      c.withMutableBufferView { view in
        // 🆗 'view' is owned by the closure and directly consumed by 'dropFirst'
        // without needing any temporary copies.
        // The result of dropFirst inherits the 'view' argument's lifetime dependence.
        scan(view.dropFirst())
      }
    }
```

Note that initializing a MutableBufferView does not write to the elements. It is safe, therefore, to initialize a mutable view with a new position and size as long as the viewed elements are contained within the incoming view. The incoming view must be consumed before the new view can be used to mutate elements.

### Non-escaping BufferView composition

Propagating a value's lifetime into the result of an initializer allows non-escaping immutable views to automatically compose into mutable aggregates without borrowing:

```swift
    public struct BufferView<Element> : ~Escapable { ... }
    
    // Scanner must be non-escaping because it contains a non-escaping property.
    // Scanner is now Copyable.
    struct Scanner : ~Escapable { // ~Escapable can be inferred
      // BufferView can be stored in a property without borrowing.
      let bytes: BufferView<UInt8>
      var cursor: BufferViewIndex<UInt8>?

      // This Scanner instance implicitly depends on any non-escaping argument
      // passed to its initializer.
      init(bytes view: BufferView<UInt8>) {
        // 🆗 Assignment to 'bytes' copies 'view' without allowing it to escape.
        self.bytes = view
      }
     
      func read() -> UInt8 { bytes[cursor!] }
    }
     
    func borrowingComposition(container: borrowing Container) -> UInt8 {
      container.withBufferView { view in // view is non-escaping
        // 'scanner' inherits 'view's non-escaping constraint
        var scanner = Scanner(bytes: view)
        // 🆗 'scanner' is mutable
        scanner.cursor = view.startIndex
        return scanner.read()
      }
    }
```

A non-escaping buffer view can be forwarded transitively. The following example wraps a BufferView in another non-escaping struct and returns the wrapper:

```swift
    func forwardReturnedView(view: BufferView<UInt8>) -> Scanner {
      // 🆗 Scanner encapsulates a copy of the incoming borrowed view, but inherits the
      // incoming view's non-escaping scope.
      return Scanner(bytes: view)
    }
```

The view's lifetime first propagates into the initialization of `Scanner`, then propagates through the lifetime-dependent return value.

### Non-escaping MutableBufferView composition

Because MutableBufferViews are non-copyable, composing them into an aggregate still requires mutating property bindings:

```swift
    // Encoder must be non-copyable because it contains a 'mutating' property.
    //
    // Encoder must be non-escaping because it contains a non-escaping property.
    struct Encoder : ~Copyable, ~Escapable { // ~Copyable and ~Escapable can be inferred
      // 'bytes' requires a 'mutating' binding because it holds a
      // non-copyable type
      mutating bytes: MutableBufferView<UInt8>
      var cursor: MutableBufferViewIndex<UInt8>? = nil

      // The new non-escaping Encoder instance effectively depends on any
      // non-escaping initializer argument.
      public init(bytes view: consuming MutableBufferView<UInt8>) {
        self.bytes = view
      }
      
      func write(value: UInt8) { bytes[cursor!] = value }
    }
```

### Benefits

- Forwarding both immutable and mutable views

- Composition using both immutable and mutable views

### Requirements

- Allow non-escaping result types for methods and computed properties
  in which lifetime-dependence on an argument can be inferred

- Diagnose expected lifetime dependence by analyzing the implementation of
  functions that transitively propagate the lifetime of an argument to the
  function result.
  
- `mutating` property bindings for composition of mutable views.

### Limitation: nested closures

Relying on nested closures for view scopes is not especially usable:

```swift
    func nestedClosuresAreEvil(c1: Container, c2: Container) {
      c1.withBufferView { view1 in
        c2.withMutableBufferView { view2 in
          view2[view2.startIndex] = view1[view1.startIndex]
        }
      }
    }
```

### Limitation: non-escaping property getters can violate exclusivity

An earlier example showed a non-escaping `Scanner` type with a stored `bytes` property that was itself a non-escaping `BufferView`. Accessing that `bytes` property within a `Scanner` method is safe because the method call itself ensures exclusive access to the Scanner. If, however, we want to access the stored property from outside a method, we will access the Scanner only for the duration of the stored property getter. One the getter returns, 'bytes' can continue to be accessed without exclusive access to the parent Scanner object: 

```swift
    public struct BufferView<Element> : ~Escapable { ... }
    
    // Scanner must be non-escaping because it contains a non-escaping property.
    // Scanner is now Copyable.
    struct Scanner : ~Escapable { // ~Escapable can be inferred
      // bytes is mutable now, so it can be replaces by a different view.
      var bytes: BufferView<UInt8>
      var cursor: BufferViewIndex<UInt8>?
      
      func updateBytes(bytes: BufferView<UInt8>) {
        self.bytes = bytes
        self.cursor = bytes.startIndex
      }
    }
    
    func accessBytes(scanner: inout Scanner) {
      let bytes = scanner.bytes
      scanner.updateBytes(bytes: anotherView)
      return bytes[scanner.cursor] // 🛑 assert: index out of range
    }
```

### Limitation: MutableBufferView construction can violate exclusivity

Initializing a MutableBufferView effectively copies the view that provides the initial index, circumventing exclusivity enforcement:

```swift
    func swapFirst(_ viewA: inout MutableBufferView<UInt8>,
                   _ viewB: inout MutableBufferView<UInt8>) -> () {
      // assumption that viewA and viewB are disjoint
      swap(&viewA[viewA.startIndex], &viewB[viewB.startIndex])
    }

    func initializationViolatesExclusivity(viewA: inout MutableBufferView<UInt8>) {
      consuming viewB = MutableBufferView<UInt8>(start: viewA.start), count: viewA.count)
      // ⚠️ no exclusivity violation reported
      swapFirst(&viewA, &viewB)
    }
```

## Non-escaping BufferView with extended access around lifetime-dependent results 

The solutions above rely on closure-taking `withBufferView` because there was no way to restrict the result of a method to an exclusive access scope on `self`. As explained in the previous section, the compiler can infer a dependence on `self` whenever a method or computed property returns a non-escaping property. The `Container` interface can now expose a view via a computed property rather than a closure-taking method:

```swift
    public struct BufferView<Element> : ~Escapable { ... }

    public struct Container : ~Copyable {
      public var rawPointer: UnsafeMutableRawPointer? = nil
      public var count: Int = 0

      // ✨ the computed view is only valid within the lifetime of 'self' because it is non-escaping
      public var view: BufferView<UInt8> {
        return BufferView<UInt8>(unsafeBaseAddress: rawPointer!, unsafeCount: count, storage: self)
      }
    }
```

Making this safe requires new rules for enforcing exclusive access on the argument that the result depends on. All uses of the result must now be contained within the argument's exclusive access scope. This extended access rule applies the same way for stored properties, computed properties, method results, and free-standing function that propagate lifetime dependence from a non-escaping argument.

### Extending exclusive access to 'self' in the caller's scope

As with accessing a stored property, accessing a computed property or calling a method already establishes an access scope for `self` in the caller. For normal escapable types, this scope only covers the expression that computes the property's value. A copy of that value is then passed along without exclusivity:

```swift
    let value = container.property
    // exclusive access to container.property is released here, before 'value' goes out of scope
    process(value)
```

Contrast this with a non-escaping property or method result, which, along with all of its copies, must be confined to the lifetime of `self`. If the result of the property or method is assigned to `let` or `var`, the lifetime of `self` is automatically extended to cover the variable's scope. Extending the lifetime of `self` also extends its exclusive access scope. This is similar to the effect of assigning a property to a `borrowing` or `mutating` local variable.

```swift
    let v = container.view
    lookAt(view: v)
    // exclusive access to container.view is released here, after 'v' is no longer used.
```

The compiler may optimize the variable's lifetime using the usual lifetime rules. The access scope, however, must always extend beyond the last use of the variable. If destroying the variable results in deinitialization, then the deinitializer runs within the access scope.
 
Extended exclusive access is only supported when the lifetime-dependent property's value is assigned as part of a variable declaration. Any other assignment is an error:

```swift
    let v: View?
    if let container = container {
      // 🛑 'v' is not declared in the current scope
      v = container.view
      lookAt(view: v)
    }
    lookAt(view: v)
```

A mutable view may temporarily be borrowed, and, while it is borrowed, cannot be modified. Regular static exclusivity enforcement ensures that any attempt to modify the view result directly or via a nested `inout` access while it is borrowed is an error:

```swift
    func viewsExtendsExclusivity(from container: inout Container) -> UInt8 {
      mutating viewOut = container.mutableView
      // 'viewIn' is a copy of the view, but still forces 'container' to be borrowed
      // until the end of this scope.
      let viewIn = viewOut

      // 🛑 simultaneous access of 'viewIn' and 'viewOut'
      copyTwo(from: viewIn, to: &viewOut)
    }

    // Assumes viewIn and viewOut are disjoint. (We don't need to read both
    // `viewIn` elements before writing any `viewOut` elements.)
    func copyTwo(from viewIn: BufferView<UInt8>, to viewOut: inout MutableBufferView<UInt8>) {
      viewOut[viewOut.startIndex] = viewIn[viewIn.startIndex]
      viewOut[viewOut.startIndex.advanced(by: 1)] = viewIn[viewIn.startIndex.advanced(by: 1)]
    }
```

### Eliminating nested closures

Lifetime-dependent properties do not require a closure scope. The computed property can safely return a non-escaping result for use in the same scope:

```swift
    func viewWithoutAClosure(container: Container) {
      scan(container.view)
    }
```

By extending the scope of the property access, dependent properties naturally extend the lifetime of the parent object. This means that the container's storage can neither be modified nor destroyed while the view exists.

If the dependent getter is used in a subexpression, its scope now covers the entire expression. Here, the exclusivity scope covers all transformations applied by `map`:

```swift
    container.view.map { ... }
```

View types may provide their own non-escaping properties that expose the same underlying storage. Here, the iterator's exclusivity scope is nested within the view's scope. Both the container's and the view's access scopes extend past the last use of the iterator:

```swift
    container.view.iterator
```

### Mutable lifetime-dependent results

Returning a mutable view requires mutation of `self` to ensure exclusive access:

```swift
    public struct Container : ~Copyable {
      //...

      // ✨ the computed view is only valid within the lifetime of 'self' because it is non-escaping
      public var mutableView: MutableBufferView<UInt8> {
        mutating get {
          return MutableBufferView<UInt8>(unsafeBaseAddress: rawPointer!,
                                          unsafeCount: count, storage: self)
        }
      }
    }

    func copyFirstWithoutClosures(from c1: Container, to c2: Container) {
      c2.mutableView[c2.mutableView.startIndex] = c1.view2[c1.view.startIndex]
    }
```

The resulting owned mutable view is non-escaping, so it cannot be used outside the container's exclusive access scope.

### Scoped containers

Without the need to retrieve views with nested closures, it becomes possible to expose views easily from the public API of other types. A temporary storage container, for example, can be defined as a non-escaping type that manages memory initialization and provides views into the initialized elements. By making the container itself non-escaping, we can take advantage of stack-allocated storage:

```swift
    struct StackAllocatedBuffer : ~Escapable {
     
      let baseAddress: UnsafeRawPointer
      let capacity: Int
     
      // Internal unsafe initializer
      init(baseAddress: UnsafeRawPointer, capacity: Int) {
        self.baseAddress = baseAddress
        self.capacity = capacity
      }
     
      public static func withTemporaryStorage<ResultType>(count: Int,
        _ body: (StackAllocatedBuffer) throws -> ResultType
      ) rethrows -> ResultType {
        let unsafeBaseAddress = /* Builtin stack allocation */
        try body(StackAllocatedBuffer(baseAddress: unsafeBaseAddress, count: count))
        /* Builtin stack deallocation */
      } 

      // The getter result depends on the formal access scope of 'self'.
      public var view: BufferView<UInt8> {
        return BufferView<UInt8>(unsafeBaseAddress: rawPointer!, unsafeCount: count, storage: self)
      }

      public var mutableView: MutableBufferView<UInt8> {
        mutating get {
          return MutableBufferView<UInt8>(unsafeBaseAddress: rawPointer!, unsafeCount: count,
                                          storage: self)
        }
      }
    }
    
    func useStack(count: Int) {
      // 🆗 neither 'stackBuffer' nor 'view' escape 'withTemporarystorage'
      StackAllocatedBuffer.withTemporaryStorage(count: count) { stackBuffer in
        stackBuffer.initialize(count: count) { /* ... */ }
        scan(stackBuffer.view)
      }
    }
```

### Benefits

- Avoids nested closures

- Avoids cumbersome and pessimistic `withExtendedLifetime`

### Requirements

- Support for extending the exclusive access scope on a function
  argument over the scope of the function result. This is analogous to
  extending access over a local `borrowing` or `mutating` local
  variable binding.

### Limitation: BufferView construction is still locally unsafe

Even if a BufferView does not escape the scope in which it was constructed, it may still exceed its container's lifetime:

```swift
    func initializationIsNotLifetimeSafe(count: Int) -> UInt8 {
      consuming container = Container(count: count)
      // This view cannot escape the current scope.
      let view = BufferView<UInt8>(unsafeBaseAddress: container.rawPointer,
                                   unsafeCount: count)
      // ⚠️ But consuming the container before the end of the scope
      // still results in a dangling pointer.
      consume container
      return view[view.startIndex]
    }
```

### Limitation: returning a new BufferView is an error

Non-escaping types ensure the a BufferView cannot escape the scope. In previous examples, the compiler was able to propagate the non-escaping constraint from a function argument to a function result. That's not always the case: 

```swift
    func noFactoriesAllowed(count: Int) -> BufferView<UInt8> {
      consuming container = Container(count: count)
      // This view cannot escape the current scope.
      let view = BufferView<UInt8>(unsafeBaseAddress: container.rawPointer,
                                   unsafeCount: count)
      // 🛑 'view' escapes its declaration scope
      return view
    }
```

## Non-escaping BufferView with generalized lifetime-dependent function results

Composition and forwarding of non-escaping types relies on making certain function results lifetime-dependent on a function argument. In the sections above, this dependence was inferred in two special cases: propagating lifetime-dependence on a non-escaping argument and lifetime-dependence of non-escaping members on `self`.

To further improve BufferView safety and usability, we can generalize this concept of lifetime-dependent function results. This can be expressed with a new `@resultDependsOn` parameter annotation and a `@resultDependsOnSelf` function annotation. The latter can typically be inferred from context.

### Lifetime-safe view construction

The basic implementation of BufferView shown above allows views to be unsafely constructed by an initializer that directly takes an `unsafeBaseAddress` and `unsafeCount` without any explicit dependence on the container. An `@unsafeEscapingResult` annotation will be required on any such function that returns a non-escaping type where no lifetime dependence on an argument can be inferred:

```swift
    public struct BufferViewIndex<Element> : ~Escapable { ... }

    public struct BufferView : ~Escapable {
      // Lifetime dependence cannot be inferred for the low-level initializer.
      @unsafeEscapingResult
      init(unsafeBaseAddress: Pointer, unsafeCount: Int) {
        self.init(start: .init(rawValue: unsafeBaseAddress), count: unsafeCount)
      }

      // The index-based initializer is lifetime-safe because the initializer's result
      // is inferred to be lifetime-dependent on `index`. 
      init(start index: Index, count: Int) { ... }
    }
```

By adding an explicit a lifetime dependence to the initializer, BufferView construction becomes lifetime-safe:

```swift
    public struct BufferView : ~Escapable {
      public init<Storage>(unsafeBaseAddress: Pointer, unsafeCount: Int,
                           storage: @resultDependsOn Storage) {
        self.init(start: .init(rawValue: baseAddress), count: unsafeCount, storage: storage)
      }
      
      //...
    }

    func initializationIsSafe(count: Int) -> UInt8 {
      consuming container = Container(count: count)
      // 🆗 This initializer's lifetime dependence ensures that 'container'
      // cannot be consumed prior to the last use of 'view'.
      let view = BufferView<UInt8>(unsafeBaseAddress: container.rawPointer,
                                   unsafeCount: count,
                                   storage: container)
      return view[view.startIndex]
    }
```

It is still up to the library author to ensure that the storage object passed to BufferView's initializer owns the pointed-to memory. Adding a lifetime-dependent storage argument avoids blatant misuse by forcing the author to be deliberate about lifetime dependence when initializing a view.

### Alternative: view construction using BufferViewStorage

It is tempting to simplify `BufferView` initialization using a protocol:

```swift
    public protocol BufferViewStorage {
      var baseAddress: UnsafeRawPointer { get }
      var count: Int { get }
    }

    public struct BufferView: ~Escapable {
      //...

      init(storage: @resultDependsOn some BufferViewStorage, count: count) {
        assert(count <= storage.count)
        self.init(start: .init(rawValue: storage.baseAddress), count: count)
      }
    }
```

It isn't clear, however, that this would improve safety overall. The `BufferViewStorage` protocol either exposes an unsafe pointer in the container's public interface, or it requires an internal proxy object. That proxy object would need to propagate lifetime dependence from the original container, which is the same problem in a different place.

### Benefits

- Safe initialization of non-escaping types

### Requirements

- `@resultDependsOn` parameter annotations

## Future work

### Consuming views

In addition to BufferView and MutableBufferView, we can provide a non-copyable ConsumableBufferView:

```swift
    public struct ConsumableBufferView<Element> : ~Copyable, ~Escapable { ... }

    extension Container { // Container is non-copyable
      // A consuming closure-taking method enforces exclusive access to 'self'
      // for the duration of the closure body and destroys 'self'.
      public consuming func withConsumableBufferView<ResultType>(
        _ body: (consuming ConsumableBufferView<UInt8>) throws -> ResultType
        ) rethrows -> ResultType {
        var view = ConsumableBufferView<UInt8>(unsafeBaseAddress: rawPointer, unsafeCount: count)
        return try body(view)
      }
    }

    extension ConsumableBufferView {
      public consuming func dropFirst() -> ConsumableBufferView {
        // Explicitly destroy the first element here before returning
        // ...
        return ConsumableBufferView(start: start.advanced(by: 1), unsafeCount: count - 1)
      }
    }

    func scan(view: borrowing BufferView<UInt8>) { /*...*/ }

    func consumeContainer(c: consuming Container) {
      c.withConsumingBufferView { view in
        scan(view.dropFirst())
      }
      // 'c' is consumed and can no longer be used
    }
```

Since `self` must be destroyed before the consuming method returns, this feature does not benefit from lifetime-dependent results.

### Source compatibility with existing protocols

Adding a `~Escapable` constraint to existing generics parameters removes its implied escaping requirement. 

This is not source breaking as long as the implementation does not actually escape its parameter. For APIs that are provided only as default implementation, without an overridable requirement, this is as straightforward as removing the implied escaping constraint from the existing implementation: 

```swift
    container.withBufferView { view in // view is non-escaping
      view.map {...} // ok after adding '~Escapable to 'map'
    }
    container.withMutableBufferView { view in // view is non-escaping
      view.sort()    // ok after adding '~Escapable' to 'sort'
    }
```

But protocol requirements will either be incompatible with views or will require removing the implied escaping requirement, and removing the requirement could break existing conformances:

```swift
    container.withBufferView { view in // view is non-escaping
    
      view.index(after: i) // ok - concrete type has no escaping requirement
      view.swapAt(i, j)    // ok - concrete type has no escaping requirement

      let collection: Collection = view
      collection.index(after: i)         // 🛑 'Collection.index()' may escape 'self'
      collection.swapAt(i, j)            // 🛑 'Collection.swapAt()' may escape 'self'
    }
```

This limitation will not be fixed by improvements to the BufferView design. A solution requires evolution of the standard library along with a migration strategy to new Collection protocols.

## Acknowledgements

Thanks to Joe Groff and John McCall for continually pushing all the language features proposed here in a coherent direction. Thanks to Guillaume Lessard for prototyping a BufferView implementation and validating the approach.
