# Data-dependent test serialization

* Proposal: [ST-NNNN](NNNN-serialization-dependencies.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: rdar://135288463
* Implementation: [swiftlang/swift-testing#1232](https://github.com/swiftlang/swift-testing/pull/1232)
* Review: ([pre-pitch](https://forums.swift.org/t/pre-pitch-data-dependent-test-serialization/81251))
  ([pitch](https://forums.swift.org/...))

## Introduction

This proposal introduces new variants of the `.serialized` trait to allow
finer-grained control over test serialization/parallelization.

> [!NOTE]
> This proposal uses the term "data dependency" to describe shared or global
> mutable state that a test may rely upon. This term is unrelated to
> "[dependency injection](https://en.wikipedia.org/wiki/Dependency_injection)",
> a commonly-used pattern when writing tests, and this feature isn't directly
> related to that pattern.

## Motivation

By default, Swift Testing runs all tests in parallel. We believe this is
generally the right choice as it allows tests to complete more quickly and can
help expose hidden dependencies between tests.

Some tests are dependent on shared/global mutable state like environment
variables or singletons and cannot run serially. For example, if these two tests
run in parallel, they may stomp on each other's state despite being valid in
isolation:

```swift
@Test func `Xterm color emulation`() {
  Environment.set("TERM", to: "xterm-256")
  #expect(Terminal.isColorEnabled)
}

@Test func `VT-100 emulation`() {
  Environment.set("TERM", to: "vt100")
  #expect(!Terminal.isColorEnabled)
}
```

This proposal introduces new API to Swift Testing to let test authors document
data dependencies like this one. Swift Testing can then order affected tests
serially while still allowing other tests to run in parallel.

## Proposed solution

We propose introducing new overloads of the existing `.serialized` trait that
take values describing data dependencies. When these overloads are applied to a
test, that test will run serially with respect to other tests that share the
same data dependency, ensuring that those tests do not interfere with each
other.

### Deprecating the existing trait

The existing `.serialized` trait only applies serialization within the context
of the test it is applied to. If it is applied to a suite, it serializes all
test functions in that suite (including those recursively contained in nested
test suites). If it is applied to a parameterized test function, it serializes
all the test cases of that test function.

However, two unrelated test suites that both have the `.serialized` trait
applied may still run in parallel with respect to _each other_. This behavior
has proven surprising to test authors who expect `.serialized` to apply
more-or-less globally. As such, we propose changing the behavior of the existing
`.serialized` trait to match that of the new unbounded-data-dependency trait and
to mark it to-be-deprecated. A change in behavior will not make the existing
trait any less correct, but will allow it to behave the way test authors
generally expect; deprecation will guide test authors toward the new trait whose
name is more expressive.

## Detailed design

A new nested type is added to `ParallelizationTrait` which describes a data
dependency:

```swift
public struct Dependency: Sendable, CustomStringConvertible {}
```

New trait factory functions are added to `ParallelizationTrait`:

```swift
extension Trait where Self == ParallelizationTrait {
  /// Constructs a trait that describes a test's dependency on shared state
  /// using a tag.
  ///
  /// - Parameters:
  ///   - tag: The tag representing the dependency.
  ///
  /// - Returns: An instance of ``ParallelizationTrait`` that marks any test it
  ///   is applied to as dependent on `tag`.
  ///
  /// Use this trait when you write a test function is dependent on global
  /// mutable state and you want to describe that state using a test tag.
  ///
  /// ```swift
  /// extension Tag {
  ///   @Tag static var freezer: Self
  /// }
  ///
  /// @Test(.serialized(for: .freezer))
  /// func `Freezer door works`() {
  ///   let freezer = FoodTruck.shared.freezer
  ///   freezer.openDoor()
  ///   #expect(freezer.isOpen)
  ///   freezer.closeDoor()
  ///   #expect(!freezer.isOpen)
  /// }
  /// ```
  ///
  /// When you apply ``Trait/serialized(for:)-(Tag)`` to a test, the testing
  /// library does _not_ automatically add `tag` to the test. Conversely, if you
  /// add `tag` to a test using the ``Trait/tags(_:)`` trait, the testing
  /// library does _not_ automatically serialize the test.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  public static func serialized(for tag: Tag) -> Self

  /// Constructs a trait that describes a test's dependency on shared state
  /// using a type.
  ///
  /// - Parameters:
  ///   - type: The type representing the dependency.
  ///
  /// - Returns: An instance of ``ParallelizationTrait`` that marks any test it
  ///   is applied to as dependent on `type`.
  ///
  /// Use this trait when you write a test function is dependent on global
  /// mutable state and you want to describe that state using a Swift type.
  ///
  /// ```swift
  /// @Test(.serialized(for: Freezer.self))
  /// func `Freezer door works`() {
  ///   let freezer = FoodTruck.shared.freezer
  ///   freezer.openDoor()
  ///   #expect(freezer.isOpen)
  ///   freezer.closeDoor()
  ///   #expect(!freezer.isOpen)
  /// }
  /// ```
  ///
  /// If you use `type` as a test suite, the testing library does _not_
  /// automatically serialize test functions declared within `type`.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  public static func serialized<T>(for type: T.Type) -> Self where T: ~Copyable & ~Escapable
}
```

When applied to a test suite, these traits are recursively inherited by nested
suites and test functions. When a test function has one of these traits applied
to it, it runs in serial with respect to _all_ other tests in the same process
that have the _same_ data dependency, but may run in parallel with tests that
have other data dependencies. For example:

```swift
@Test(.serialized(for: A)) func a1() {}
@Test(.serialized(for: A)) func a2() {}
@Test(.serialized(for: B)) func b() {}
```

`a1()` and `a2()` will run serially with respect to each other, but `b()` is
allowed to run in parallel with both `a1()` and `a2()`.

### Declaring an unbounded data dependency

Another overload of `.serialized` is added along with a corresponding typealias
to describe its type, which can be referred to in argument position as `*`:

```swift
extension ParallelizationTrait.Dependency {
  /// An unbounded dependency.
  ///
  /// An unbounded dependency is a dependency on the complete state of the
  /// current process. To specify an unbounded dependency when using
  /// ``Trait/serialized(for:)-(Self.Unbounded)``, pass a reference
  /// to this function.
  ///
  /// ```swift
  /// @Test(.serialized(for: *))
  /// func `All food truck environment variables`() { ... }
  /// ```
  ///
  /// If a test has more than one dependency, the testing library automatically
  /// treats it as if it is dependent on the program's complete state.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  public static func *(/*...*/)

  /// A type describing unbounded dependencies.
  ///
  /// An unbounded dependency is a dependency on the complete state of the
  /// current process. To specify an unbounded dependency when using
  /// ``Trait/serialized(for:)-(Self.Dependency.Unbounded)``, pass a reference
  /// to the `*` operator.
  ///
  /// ```swift
  /// @Test(.serialized(for: *))
  /// func `All food truck environment variables`() { ... }
  /// ```
  ///
  /// If a test has more than one dependency, the testing library automatically
  /// treats it as if it is dependent on the program's complete state.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  public typealias Unbounded = /* ... */
}

extension Trait where Self == ParallelizationTrait {
  /// Constructs a trait that describes a dependency on the complete state of
  /// the current process.
  ///
  /// - Returns: An instance of ``ParallelizationTrait`` that adds a dependency
  ///   on the complete state of the current process to any test it is applied
  ///   to.
  ///
  /// Pass `*` to ``serialized(for:)-(Self.Dependency.Unbounded)`` when you
  /// write a test function is dependent on global mutable state in the current
  /// process that cannot be fully described or that isn't known until runtime.
  ///
  /// ```swift
  /// @Test(.serialized(for: *))
  /// func `All food truck environment variables`() { ... }
  /// ```
  ///
  /// If a test has more than one dependency, the testing library automatically
  /// treats it as if it is dependent on the program's complete state.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  public static func serialized(for _: Self.Dependency.Unbounded) -> Self
}
```

And the existing `.serialized` trait is marked to-be-deprecated:

```swift
extension Trait where Self == ParallelizationTrait {
  /// A trait that serializes the test to which it is applied.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  @available(swift, deprecated: 100000.0, renamed: "serialized(for: *)")
  public static var serialized: Self { get }
}
```

A test author can declare that a test has a data dependency on _all_ observable
state in the program by writing `.serialized(for: *)`. This overload of the
trait is useful when a test has complex requirements that cannot be fully
described statically. For example:

```swift
@Test(.serialized(for: *)) func monkey() {
  // https://www.folklore.org/Monkey_Lives.html
  let possibleActions = [
    writeToStandardError,
    readFromStandardInput,
    modifyEnvironment,
    // ...
  ]
  for i in 0 ..< 1000 {
    let action = possibleActions.randomElement()
    action.perform()
  }    
}
```

The `.serialized` trait's behavior will change to match that of
`.serialized(for: *)` as described earlier in this proposal. In cases where the
existing behavior is desireable for a given suite, the suite type itself (or any
other Swift type, for that matter) can be used as the data dependency:

```swift
@Suite(.serialized(for: S.self))
struct S {
  // ...
}
```

### Declaring multiple data dependencies

If a test has multiple distinct data dependencies, it runs in serial with all
other tests that have _any_ of those data dependencies. For example:

```swift
@Test(.serialized(for: A)) func a() {}
@Test(.serialized(for: A), .serialized(for: B)) func ab() {}
@Test(.serialized(for: B)) func b() {}
```

In this case, `a()` and `ab()` must run serially, and `b()` and `ab()` must run
serially, but `a()` and `b()` can run in parallel with each other.

There is a class of deadlock bugs that can occur when tests have moderately
complex interrelated data dependencies. For example:

```swift
@Test(.serialized(for: A), .serialized(for: B)) func ab() {}
@Test(.serialized(for: B), .serialized(for: C)) func bc() {}
@Test(.serialized(for: C), .serialized(for: A)) func ca() {}
```

The execution order for `ab()`, `bc()`, and `ca()` is unspecified, and it is
possible for each of the three tests to end up scheduled to run after the others
(i.e. a deadlock can occur). To avoid that deadlock, Swift Testing cuts the
Gordian knot and treats any test with more than one data dependency as having an
_unbounded_ data dependency instead. In this example, `ab()`, `bc()`, and `ca()`
will run serially with respect to each other.

## Source compatibility

This change is additive only and does not affect source compatibility.

## Integration with supporting tools

This change does not affect supporting tools or the JSON event stream schema.

## Future directions

- **Adding other kinds of data dependency.** We anticipate that tags and Swift
  types are sufficient to describe most, if not all, data dependencies. The
  community may find use for other "key" types, which we can evaluate on a
  case-by-case basis.

- **Formally deprecating `.serialized`.** A future proposal will move this trait
  from to-be-deprecated to formally deprecated.

## Alternatives considered

- **Leaving the behavior of `.serialized` unchanged.** This interface frequently
  confuses test authors who expect it to apply across all tests with the same
  trait. Changing it would resolve this issue for those test authors while not
  affecting the correctness of existing tests that use it (if they are affected,
  it implies a concurrency bug already exists in those tests).

- **Inferring data dependencies from source inspection.** In the general case,
  computing the set of data dependencies in a particular program is undecidable.

- **Using key paths instead of tags or types to describe data dependencies.**
  An earlier version of the experimental implementation used key paths. Key
  paths gave the illusion of finer-grained control than is actually technically
  feasible, and could fail to uncover hidden data dependencies (consider: does
  reading `\A.b` also read or write `\A.c`?)

- **Using unsafe pointers to describe data dependencies.** Pointers allow
  describing data dependencies on C and C++ API. For example, the global
  `stderr` and `environ` variables could be used describe the standard error
  stream and the process environment block, respectively. However, unsafe
  pointers are _unsafe_. Accessing any pointer originating in Swift begs the
  question of why you wouldn't just use a Swift type; accessing a pointer
  originating in C tends to generate errors about concurrency safety in Swift 6.
