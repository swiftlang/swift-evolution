# Test Scoping Traits

* Proposal: [ST-0007](0007-test-scoping-traits.md)
* Authors: [Stuart Montgomery](https://github.com/stmontgomery)
* Status: **Implemented (Swift 6.1)**
* Implementation: [swiftlang/swift-testing#733](https://github.com/swiftlang/swift-testing/pull/733), [swiftlang/swift-testing#86](https://github.com/swiftlang/swift-testing/pull/86)
* Review: ([pitch](https://forums.swift.org/t/pitch-custom-test-execution-traits/75055)), ([review](https://forums.swift.org/t/proposal-test-scoping-traits/76676)), ([acceptance](https://forums.swift.org/t/proposal-test-scoping-traits/76676/3))

> [!NOTE]
> This proposal was accepted before Swift Testing began using the Swift
> evolution review process. Its original identifier was
> [SWT-0007](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Proposals/0007-test-scoping-traits.md).

### Revision history

* **v1**: Initial pitch.
* **v2**: Dropped 'Custom' prefix from the proposed API names (although kept the
  word in certain documentation passages where it clarified behavior).
* **v3**: Changed the `Trait` requirement from a property to a method which
  accepts the test and/or test case, and modify its default implementations such
  that custom behavior is either performed per-suite or per-test case by default.
* **v4**: Renamed the APIs to use "scope" as the base verb instead of "execute".

## Introduction

This introduces API which enables a `Trait`-conforming type to provide a custom
execution scope for test functions and suites, including running code before or
after them.

## Motivation

One of the primary motivations for the trait system in Swift Testing, as
[described in the vision document](https://github.com/swiftlang/swift-evolution/blob/main/visions/swift-testing.md#trait-extensibility),
is to provide a way to customize the behavior of tests which have things in
common. If all the tests in a given suite type need the same custom behavior,
`init` and/or `deinit` (if applicable) can be used today. But if only _some_ of
the tests in a suite need custom behavior, or tests across different levels of
the suite hierarchy need it, traits would be a good place to encapsulate common
logic since they can be applied granularly per-test or per-suite. This aspect of
the vision for traits hasn't been realized yet, though: the `Trait` protocol
does not offer a way for a trait to customize the execution of the tests or
suites it's applied to.

Customizing a test's behavior typically means running code either before or
after it runs, or both. Consolidating common set-up and tear-down logic allows
each test function to be more succinct with less repetitive boilerplate so it
can focus on what makes it unique.

## Proposed solution

At a high level, this proposal entails adding API to the `Trait` protocol
allowing a conforming type to opt-in to providing a custom execution scope for a
test. We discuss how that capability should be exposed to trait types below.

### Supporting scoped access

There are different approaches one could take to expose hooks for a trait to
customize test behavior. To illustrate one of them, consider the following
example of a `@Test` function with a custom trait whose purpose is to set mock
API credentials for the duration of each test it's applied to:

```swift
@Test(.mockAPICredentials)
func example() {
  // ...
}

struct MockAPICredentialsTrait: TestTrait { ... }

extension Trait where Self == MockAPICredentialsTrait {
  static var mockAPICredentials: Self { ... }
}
```

In this hypothetical example, the current API credentials are stored via a
static property on an `APICredentials` type which is part of the module being
tested:

```swift
struct APICredentials {
  var apiKey: String

  static var shared: Self?
}
```

One way that this custom trait could customize the API credentials during each
test is if the `Trait` protocol were to expose a pair of method requirements
which were then called before and after the test, respectively:

```swift
public protocol Trait: Sendable {
  // ...
  func setUp() async throws
  func tearDown() async throws
}

extension Trait {
  // ...
  public func setUp() async throws { /* No-op */ }
  public func tearDown() async throws { /* No-op */ }
}
```

The custom trait type could adopt these using code such as the following:

```swift
extension MockAPICredentialsTrait {
  func setUp() {
    APICredentials.shared = .init(apiKey: "...")
  }

  func tearDown() {
    APICredentials.shared = nil
  }
}
```

Many testing systems use this pattern, including XCTest. However, this approach
encourages the use of global mutable state such as the `APICredentials.shared`
variable, and this limits the testing library's ability to parallelize test
execution, which is
[another part of the Swift Testing vision](https://github.com/swiftlang/swift-evolution/blob/main/visions/swift-testing.md#parallelization-and-concurrency).

The use of nonisolated static variables is generally discouraged now, and in
Swift 6 the above `APICredentials.shared` property produces an error. One way
to resolve that is to change it to a `@TaskLocal` variable, as this would be
concurrency-safe and still allow tests accessing this state to run in parallel:

```swift
extension APICredentials {
  @TaskLocal static var current: Self?
}
```

Binding task local values requires using the scoped access
[`TaskLocal.withValue()`](https://developer.apple.com/documentation/swift/tasklocal/withvalue(_:operation:isolation:file:line:))
API though, and that would not be possible if `Trait` exposed separate methods
like `setUp()` and `tearDown()`.

For these reasons, I believe it's important to expose this trait capability
using a single, scoped access-style API which accepts a closure. A simplified
version of that idea might look like this:

```swift
public protocol Trait: Sendable {
  // ...

  // Simplified example, not the actual proposal
  func executeTest(_ body: @Sendable () async throws -> Void) async throws
}

extension MockAPICredentialsTrait {
  func executeTest(_ body: @Sendable () async throws -> Void) async throws {
    let mockCredentials = APICredentials(apiKey: "...")
    try await APICredentials.$current.withValue(mockCredentials) {
      try await body()
    }
  }
}
```

### Avoiding unnecessarily lengthy backtraces

A scoped access-style API has some potential downsides. To apply this approach
to a test function, the scoped call of a trait must wrap the invocation of that
test function, and every _other_ trait applied to that same test which offers
custom behavior _also_ must wrap the other traits' calls in a nesting fashion.
To visualize this, imagine a test function with multiple traits:

```swift
@Test(.traitA, .traitB, .traitC)
func exampleTest() {
  // ...
}
```

If all three of those traits provide a custom scope for tests, then each of them
needs to wrap the call to the next one, and the last trait needs to wrap the
invocation of the test, illustrated by the following:

```
TraitA.executeTest {
  TraitB.executeTest {
    TraitC.executeTest {
      exampleTest()
    }
  }
}
```

Tests may have an arbitrary number of traits applied to them, including those
inherited from containing suite types. A naïve implementation in which _every_
trait is given the opportunity to customize test behavior by calling its scoped
access API might cause unnecessarily lengthy backtraces that make debugging the
body of tests more difficult. Or worse: if the number of traits is great enough,
it could cause a stack overflow.

In practice, most traits probably do _not_ need to provide a custom scope for
the tests they're applied to, so to mitigate these downsides it's important that
there be some way to distinguish traits which customize test behavior. That way,
the testing library can limit these scoped access calls to only traits which
need it.

### Avoiding unnecessary (re-)execution

Traits can be applied to either test functions or suites, and traits applied to
suites can optionally support inheritance by implementing the `isRecursive`
property of the `SuiteTrait` protocol. When a trait is directly applied to a
test function, if the trait customizes the behavior of tests it's applied to, it
should be given the opportunity to perform its custom behavior once for every
invocation of that test function. In particular, if the test function is
parameterized and runs multiple times, then the trait applied to it should
perform its custom behavior once for every invocation. This should not be
surprising to users, since it's consistent with the behavior of `init` and
`deinit` for an instance `@Test` method.

It may be useful for certain kinds of traits to perform custom logic once for
_all_ the invocations of a parameterized test. Although this should be possible,
we believe it shouldn't be the default since it could lead to work being
repeated multiple times needlessly, or unintentional state sharing across tests,
unless the trait is implemented carefully to avoid those problems.

When a trait conforms to `SuiteTrait` and is applied to a suite, the question of
when its custom scope (if any) should be applied is less obvious. Some suite
traits support inheritance and are recursively applied to all the test functions
they contain (including transitively, via sub-suites). Other suite traits don't
support inheritance, and only affect the specific suite they're applied to.
(It's also worth noting that a sub-suite _can_ have the same non-recursive suite
trait one of its ancestors has, as long as it's applied explicitly.)

As a general rule of thumb, we believe most traits will either want to perform
custom logic once for _all_ children or once for _each_ child, not both.
Therefore, when it comes to suite traits, the default behavior should depend on
whether it supports inheritance: a recursive suite trait should by default
perform custom logic before each test, and a non-recursive one per-suite. But
the APIs should be flexible enough to support both, for advanced traits which
need it.

## Detailed design

I propose the following new APIs:

- A new protocol `TestScoping` with a single required `provideScope(...)` method.
  This will be called to provide scope for a test, and allows the conforming
  type to perform custom logic before or after.
- A new method `scopeProvider(for:testCase:)` on the `Trait` protocol whose
  result type is an `Optional` value of a type conforming to `TestScoping`. A
  `nil` value returned by this method will skip calling the `provideScope(...)`
  method.
- A default implementation of `Trait.scopeProvider(...)` which returns `nil`.
- A conditional implementation of `Trait.scopeProvider(...)` which returns `self`
  in the common case where the trait type conforms to `TestScoping` itself.

Since the `scopeProvider(...)` method's return type is optional and returns `nil`
by default, the testing library cannot invoke the `provideScope(...)` method
unless a trait customizes test behavior. This avoids the "unnecessarily lengthy
backtraces" problem above.

Below are the proposed interfaces:

```swift
/// A protocol that allows providing a custom execution scope for a test
/// function (and each of its cases) or a test suite by performing custom code
/// before or after it runs.
///
/// Types conforming to this protocol may be used in conjunction with a
/// ``Trait``-conforming type by implementing the
/// ``Trait/scopeProvider(for:testCase:)-cjmg`` method, allowing custom traits
/// to provide custom scope for tests. Consolidating common set-up and tear-down
/// logic for tests which have similar needs allows each test function to be
/// more succinct with less repetitive boilerplate so it can focus on what makes
/// it unique.
public protocol TestScoping: Sendable {
  /// Provide custom execution scope for a function call which is related to the
  /// specified test and/or test case.
  ///
  /// - Parameters:
  ///   - test: The test under which `function` is being performed.
  ///   - testCase: The test case, if any, under which `function` is being
  ///     performed. When invoked on a suite, the value of this argument is
  ///     `nil`.
  ///   - function: The function to perform. If `test` represents a test suite,
  ///     this function encapsulates running all the tests in that suite. If
  ///     `test` represents a test function, this function is the body of that
  ///     test function (including all cases if it is parameterized.)
  ///
  /// - Throws: Whatever is thrown by `function`, or an error preventing this
  ///   type from providing a custom scope correctly. An error thrown from this
  ///   method is recorded as an issue associated with `test`. If an error is
  ///   thrown before `function` is called, the corresponding test will not run.
  ///
  /// When the testing library is preparing to run a test, it starts by finding
  /// all traits applied to that test, including those inherited from containing
  /// suites. It begins with inherited suite traits, sorting them
  /// outermost-to-innermost, and if the test is a function, it then adds all
  /// traits applied directly to that functions in the order they were applied
  /// (left-to-right). It then asks each trait for its scope provider (if any)
  /// by calling ``Trait/scopeProvider(for:testCase:)-cjmg``. Finally, it calls
  /// this method on all non-`nil` scope providers, giving each an opportunity
  /// to perform arbitrary work before or after invoking `function`.
  ///
  /// This method should either invoke `function` once before returning or throw
  /// an error if it is unable to provide a custom scope.
  ///
  /// Issues recorded by this method are associated with `test`.
  func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws
}

public protocol Trait: Sendable {
  // ...

  /// The type of the test scope provider for this trait.
  ///
  /// The default type is `Never`, which cannot be instantiated. The
  /// ``scopeProvider(for:testCase:)-cjmg`` method for any trait with this
  /// default type must return `nil`, meaning that trait will not provide a
  /// custom scope for the tests it's applied to.
  associatedtype TestScopeProvider: TestScoping = Never

  /// Get this trait's scope provider for the specified test and/or test case,
  /// if any.
  ///
  /// - Parameters:
  ///   - test: The test for which a scope provider is being requested.
  ///   - testCase: The test case for which a scope provider is being requested,
  ///     if any. When `test` represents a suite, the value of this argument is
  ///     `nil`.
  ///
  /// - Returns: A value conforming to ``Trait/TestScopeProvider`` which may be
  ///   used to provide custom scoping for `test` and/or `testCase`, or `nil` if
  ///   they should not have any custom scope.
  ///
  /// If this trait's type conforms to ``TestScoping``, the default value
  /// returned by this method depends on `test` and/or `testCase`:
  ///
  /// - If `test` represents a suite, this trait must conform to ``SuiteTrait``.
  ///   If the value of this suite trait's ``SuiteTrait/isRecursive`` property
  ///   is `true`, then this method returns `nil`; otherwise, it returns `self`.
  ///   This means that by default, a suite trait will _either_ provide its
  ///   custom scope once for the entire suite, or once per-test function it
  ///   contains.
  /// - Otherwise `test` represents a test function. If `testCase` is `nil`,
  ///   this method returns `nil`; otherwise, it returns `self`. This means that
  ///   by default, a trait which is applied to or inherited by a test function
  ///   will provide its custom scope once for each of that function's cases.
  ///
  /// A trait may explicitly implement this method to further customize the
  /// default behaviors above. For example, if a trait should provide custom
  /// test scope both once per-suite and once per-test function in that suite,
  /// it may implement the method and return a non-`nil` scope provider under
  /// those conditions.
  ///
  /// A trait may also implement this method and return `nil` if it determines
  /// that it does not need to provide a custom scope for a particular test at
  /// runtime, even if the test has the trait applied. This can improve
  /// performance and make diagnostics clearer by avoiding an unnecessary call
  /// to ``TestScoping/provideScope(for:testCase:performing:)``.
  ///
  /// If this trait's type does not conform to ``TestScoping`` and its
  /// associated ``Trait/TestScopeProvider`` type is the default `Never`, then
  /// this method returns `nil` by default. This means that instances of this
  /// trait will not provide a custom scope for tests to which they're applied.
  func scopeProvider(for test: Test, testCase: Test.Case?) -> TestScopeProvider?
}

extension Trait where Self: TestScoping {
  // Returns `nil` if `testCase` is `nil`, else `self`.
  public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self?
}

extension SuiteTrait where Self: TestScoping {
  // If `test` is a suite, returns `nil` if `isRecursive` is `true`, else `self`.
  // Otherwise, `test` is a function and this returns `nil` if `testCase` is
  // `nil`, else `self`.
  public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self?
}

extension Trait where TestScopeProvider == Never {
  // Returns `nil`.
  public func scopeProvider(for test: Test, testCase: Test.Case?) -> Never?
}

extension Never: TestScoping {}
```

Here is a complete example of the usage scenario described earlier, showcasing
the proposed APIs:

```swift
@Test(.mockAPICredentials)
func example() {
  // ...validate API usage, referencing `APICredentials.current`...
}

struct MockAPICredentialsTrait: TestTrait, TestScoping {
  func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
    let mockCredentials = APICredentials(apiKey: "...")
    try await APICredentials.$current.withValue(mockCredentials) {
      try await function()
    }
  }
}

extension Trait where Self == MockAPICredentialsTrait {
  static var mockAPICredentials: Self {
    Self()
  }
}
```

## Source compatibility

The proposed APIs are purely additive.

This proposal will replace the existing `CustomExecutionTrait` SPI, and after
further refactoring we anticipate it will obsolete the need for the
`SPIAwareTrait` SPI as well.

## Integration with supporting tools

Although some built-in traits are relevant to supporting tools (such as
SourceKit-LSP statically discovering `.tags` traits), custom test behaviors are
only relevant within the test executable process while tests are running. We
don't anticipate any particular need for this feature to integrate with
supporting tools.

## Future directions

### Access to suite type instances

Some test authors have expressed interest in allowing custom traits to access
the instance of a suite type for `@Test` instance methods, so the trait could
inspect or mutate the instance. Currently, only instance-level members of a
suite type (including `init`, `deinit`, and the test function itself) can access
`self`, so this would grant traits applied to an instance test method access to
the instance as well. This is certainly interesting, but poses several technical
challenges that puts it out of scope of this proposal.

### Convenience trait for setting task locals

Some reviewers of this proposal pointed out that the hypothetical usage example
shown earlier involving setting a task local value while a test is executing
will likely become a common use of these APIs. To streamline that pattern, it
would be very natural to add a built-in trait type which facilitates this. I
have prototyped this idea and plan to add it once this new trait functionality
lands.

## Alternatives considered

### Separate set up & tear down methods on `Trait`

This idea was discussed in [Supporting scoped access](#supporting-scoped-access)
above, and as mentioned there, the primary problem with this approach is that it
cannot be used with scoped access-style APIs, including (importantly)
`TaskLocal.withValue()`. For that reason, it prevents using that common Swift
concurrency technique and reduces the potential for test parallelization.

### Add `provideScope(...)` directly to the `Trait` protocol

The proposed `provideScope(...)` method could be added as a requirement of the
`Trait` protocol instead of being part of a separate `TestScoping` protocol, and
it could have a default implementation which directly invokes the passed-in
closure. But this approach would suffer from the lengthy backtrace problem
described above.

### Extend the `Trait` protocol

The original, experimental implementation of this feature included a protocol
named`CustomExecutionTrait` which extended `Trait` and had roughly the same
method requirement as the `TestScoping` protocol proposed above. This design
worked, provided scoped access, and avoided the lengthy backtrace problem.

After evaluating the design and usage of this SPI though, it seemed unfortunate
to structure it as a sub-protocol of `Trait` because it means that the full
capabilities of the trait system are spread across multiple protocols. In the
proposed design, the ability to return a test scoping provider is exposed via
the main `Trait` protocol, and it relies on an associated type to conditionally
opt-in to custom test behavior. In other words, the proposed design expresses
custom test behavior as just a _capability_ that a trait may have, rather than a
distinct sub-type of trait.

Also, the implementation of this approach within the testing library was not
ideal as it required a conditional `trait as? CustomExecutionTrait` downcast at
runtime, in contrast to the simpler and more performant Optional property of the
proposed API.

### API names

We first considered "execute" as the base verb for the proposed new concept, but
felt this wasn't appropriate since these trait types are not "the executor" of
tests, they merely customize behavior and provide scope(s) for tests to run
within. Also, the term "executor" has prior art in Swift Concurrency, and
although that word is used in other contexts too, it may be helpful to avoid
potential confusion with concurrency executors.

We also considered "run" as the base verb for the proposed new concept instead
of "execute", which would imply the names `TestRunning`, `TestRunner`,
`runner(for:testCase)`, and `run(_:for:testCase:)`. The word "run" is used in
many other contexts related to testing though, such as the `Runner` SPI type and
more casually to refer to a run which occurred of a test, in the past tense, so
overloading this term again may cause confusion.

## Acknowledgments

Thanks to [Dennis Weissmann](https://github.com/dennisweissmann) for originally
implementing this as SPI, and for helping promote its usefulness.

Thanks to [Jonathan Grynspan](https://github.com/grynspan) for exploring ideas
to refine the API, and considering alternatives to avoid unnecessarily long
backtraces.

Thanks to [Brandon Williams](https://github.com/mbrandonw) for feedback on the
Forum pitch thread which ultimately led to the refinements described in the
"Avoiding unnecessary (re-)execution" section.
