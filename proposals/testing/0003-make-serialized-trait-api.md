# Make .serialized trait API

* Proposal: [ST-0003](0003-make-serialized-trait-api.md)
* Authors: [Dennis Weissmann](https://github.com/dennisweissmann)
* Status: **Implemented (Swift 6.0)**
* Implementation: 
[swiftlang/swift-testing#535](https://github.com/swiftlang/swift-testing/pull/535)
* Review: 
([pitch](https://forums.swift.org/t/pitch-make-serialized-trait-public-api/73147)),
([acceptance](https://forums.swift.org/t/pitch-make-serialized-trait-public-api/73147/5))

> [!NOTE]
> This proposal was accepted before Swift Testing began using the Swift
> evolution review process. Its original identifier was
> [SWT-0003](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Proposals/0003-make-serialized-trait-api.md).

## Introduction

We propose promoting the existing `.serialized` trait to public API. This trait 
enables developers to designate tests or test suites to run serially, ensuring 
sequential execution where necessary.

## Motivation

The Swift Testing library defaults to parallel execution of tests, promoting 
efficiency and isolation. However, certain test scenarios demand strict 
sequential execution due to shared state or complex dependencies between tests. 
The `.serialized` trait provides a solution by allowing developers to enforce 
serial execution for specific tests or suites.

While global actors ensure that only one task associated with that actor runs 
at any given time, thus preventing concurrent access to actor state, tasks can 
yield and allow other tasks to proceed, potentially interleaving execution. 
That means global actors do not ensure that a specific test runs entirely to 
completion before another begins. A testing library requires a construct that 
guarantees that each annotated test runs independently and completely (in its 
suite), one after another, without interleaving.

## Proposed Solution

We propose exposing the `.serialized` trait as a public API. This attribute can 
be applied to individual test functions or entire test suites, modifying the 
test execution behavior to enforce sequential execution where specified.

Annotating just a single test in a suite does not enforce any serialization 
behavior - the testing library encourages parallelization and the bar to 
degrade overall performance of test execution should be high.
Additionally, traits apply inwards - it would be unexpected to impact the exact 
conditions of a another test in a suite without applying a trait to the suite 
itself. 
Thus, this trait should only be applied to suites (to enforce serial execution 
of all tests inside it) or parameterized tests. If applied to just a test this 
trait does not have any effect.

## Detailed Design

The `.serialized` trait functions as an attribute that alters the execution 
scheduling of tests. When applied, it ensures that tests or suites annotated 
with `.serialized` run serially.

```swift
/// A type that affects whether or not a test or suite is parallelized.
///
/// When added to a parameterized test function, this trait causes that test to
/// run its cases serially instead of in parallel. When applied to a
/// non-parameterized test function, this trait has no effect. When applied to a
/// test suite, this trait causes that suite to run its contained test functions
/// and sub-suites serially instead of in parallel.
///
/// This trait is recursively applied: if it is applied to a suite, any
/// parameterized tests or test suites contained in that suite are also
/// serialized (as are any tests contained in those suites, and so on.)
///
/// This trait does not affect the execution of a test relative to its peers or
/// to unrelated tests. This trait has no effect if test parallelization is
/// globally disabled (by, for example, passing `--no-parallel` to the
/// `swift test` command.)
///
/// To add this trait to a test, use ``Trait/serialized``.
public struct ParallelizationTrait: TestTrait, SuiteTrait {}

extension Trait where Self == ParallelizationTrait {
  /// A trait that serializes the test to which it is applied.
  ///
  /// ## See Also
  ///
  /// - ``ParallelizationTrait``
  public static var serialized: Self { get }
}
```

The call site looks like this:

```swift
@Test(.serialized, arguments: Food.allCases) func prepare(food: Food) {
  // This function will be invoked serially, once per food, because it has the
  // .serialized trait.
}

@Suite(.serialized) struct FoodTruckTests {
  @Test(arguments: Condiment.allCases) func refill(condiment: Condiment) {
    // This function will be invoked serially, once per condiment, because the
    // containing suite has the .serialized trait.
  }

  @Test func startEngine() async throws {
    // This function will not run while refill(condiment:) is running. One test
    // must end before the other will start.
  }
}

@Suite struct FoodTruckTests {
  @Test(.serialized) func startEngine() async throws {
    // This function will not run serially - it's not a parameterized test and
    // the suite is not annotated with the `.serialized` trait.
  }

  @Test func prepareFood() async throws {
    // It doesn't matter if this test is `.serialized` or not, traits applied 
    // to other tests won't affect this test don't impact other tests.
  }
}
```

## Source Compatibility

Introducing `.serialized` as a public API does not have any impact on existing 
code. Tests will continue to run in parallel by default unless explicitly 
marked with `.serialized`.

## Integration with Supporting Tools

N/A.

## Future Directions

There might be asks for more advanced and complex ways to affect parallelization
which include ways to specify dependencies between tests ie. "Require `foo()` to
run before `bar()`".

## Alternatives Considered

Alternative approaches, such as relying solely on global actors for test 
isolation, were considered. However, global actors do not provide the 
deterministic, sequential execution required for certain testing scenarios. The 
`.serialized` trait offers a more explicit and flexible mechanism, ensuring 
that each designated test or suite runs to completion without interruption.

Various more complex parallelization and serialization options were discussed 
and considered but ultimately disregarded in favor of this simple yet powerful 
implementation.

## Acknowledgments

Thanks to the swift-testing team and managers for their contributions! Thanks 
to our community for the initial feedback around this feature.
