# Return errors from `#expect(throws:)`

* Proposal: [ST-0006](0006-return-errors-from-expect-throws.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Status: **Implemented (Swift 6.1)**
* Bug: rdar://138235250
* Implementation: [swiftlang/swift-testing#780](https://github.com/swiftlang/swift-testing/pull/780)
* Review: ([pitch](https://forums.swift.org/t/pitch-returning-errors-from-expect-throws/75567)), ([acceptance](https://forums.swift.org/t/pitch-returning-errors-from-expect-throws/75567/5))

> [!NOTE]
> This proposal was accepted before Swift Testing began using the Swift
> evolution review process. Its original identifier was
> [SWT-0006](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Proposals/0006-return-errors-from-expect-throws.md).

## Introduction

Swift Testing includes overloads of `#expect()` and `#require()` that can be
used to assert that some code throws an error. They are useful when validating
that your code's failure cases are correctly detected and handled. However, for
more complex validation cases, they aren't particularly ergonomic. This proposal
seeks to resolve that issue by having these overloads return thrown errors for
further inspection.

## Motivation

We offer three variants of `#expect(throws:)`:

- One that takes an error type, and matches any error of the same type;
- One that takes an error _instance_ (conforming to `Equatable`) and matches any
  error that compares equal to it; and
- One that takes a trailing closure and allows test authors to write arbitrary
  validation logic.

The third overload has proven to be somewhat problematic. First, it yields the
error to its closure as an instance of `any Error`, which typically forces the
developer to cast it before doing any useful comparisons. Second, the test
author must return `true` to indicate the error matched and `false` to indicate
it didn't, which can be both logically confusing and difficult to express
concisely:

```swift
try #require {
  let potato = try Sack.randomPotato()
  try potato.turnIntoFrenchFries()
} throws: { error in
  guard let error = error as PotatoError else {
    return false
  }
  guard case .potatoNotPeeled = error else {
    return false
  }
  return error.variety != .russet
}
```

The first impulse many test authors have here is to use `#expect()` in the
second closure, but it doesn't return the necessary boolean value _and_ it can
result in multiple issues being recorded in a test when there's really only one.

## Proposed solution

I propose deprecating [`#expect(_:sourceLocation:performing:throws:)`](https://developer.apple.com/documentation/testing/expect(_:sourcelocation:performing:throws:))
and [`#require(_:sourceLocation:performing:throws:)`](https://developer.apple.com/documentation/testing/require(_:sourcelocation:performing:throws:))
and modifying the other overloads so that, on success, they return the errors
that were thrown.

## Detailed design

All overloads of `#expect(throws:)` and `#require(throws:)` will be updated to
return an instance of the error type specified by their arguments, with the
problematic overloads returning `any Error` since more precise type information
is not statically available. The problematic overloads will also be deprecated:

```diff
--- a/Sources/Testing/Expectations/Expectation+Macro.swift
+++ b/Sources/Testing/Expectations/Expectation+Macro.swift
+@discardableResult
 @freestanding(expression) public macro expect<E, R>(
   throws errorType: E.Type,
   _ comment: @autoclosure () -> Comment? = nil,
   sourceLocation: SourceLocation = #_sourceLocation,
   performing expression: () async throws -> R
-)
+) -> E? where E: Error

+@discardableResult
 @freestanding(expression) public macro require<E, R>(
   throws errorType: E.Type,
   _ comment: @autoclosure () -> Comment? = nil,
   sourceLocation: SourceLocation = #_sourceLocation,
   performing expression: () async throws -> R
-) where E: Error
+) -> E where E: Error

+@discardableResult
 @freestanding(expression) public macro expect<E, R>(
   throws error: E,
   _ comment: @autoclosure () -> Comment? = nil,
   sourceLocation: SourceLocation = #_sourceLocation,
   performing expression: () async throws -> R
-) where E: Error & Equatable
+) -> E? where E: Error & Equatable

+@discardableResult
 @freestanding(expression) public macro require<E, R>(
   throws error: E,
   _ comment: @autoclosure () -> Comment? = nil,
   sourceLocation: SourceLocation = #_sourceLocation,
   performing expression: () async throws -> R
-) where E: Error & Equatable
+) -> E where E: Error & Equatable

+@available(swift, deprecated: 100000.0, message: "Examine the result of '#expect(throws:)' instead.")
+@discardableResult
 @freestanding(expression) public macro expect<R>(
   _ comment: @autoclosure () -> Comment? = nil,
   sourceLocation: SourceLocation = #_sourceLocation,
   performing expression: () async throws -> R,
   throws errorMatcher: (any Error) async throws -> Bool
-)
+) -> (any Error)?

+@available(swift, deprecated: 100000.0, message: "Examine the result of '#require(throws:)' instead.")
+@discardableResult
 @freestanding(expression) public macro require<R>(
   _ comment: @autoclosure () -> Comment? = nil,
   sourceLocation: SourceLocation = #_sourceLocation,
   performing expression: () async throws -> R,
   throws errorMatcher: (any Error) async throws -> Bool
-)
+) -> any Error
```

(More detailed information about the deprecations will be provided via DocC.)

The `#expect(throws:)` overloads return an optional value that is `nil` if the
expectation failed, while the `#require(throws:)` overloads return non-optional
values and throw instances of `ExpectationFailedError` on failure (as before.)

> [!NOTE]
> Instances of `ExpectationFailedError` thrown by `#require(throws:)` on failure
> are not returned as that would defeat the purpose of using `#require(throws:)`
> instead of `#expect(throws:)`.

Test authors will be able to use the result of the above functions to verify
that the thrown error is correct:

```swift
let error = try #require(throws: PotatoError.self) {
  let potato = try Sack.randomPotato()
  try potato.turnIntoFrenchFries()
}
#expect(error == .potatoNotPeeled)
#expect(error.variety != .russet)
```

The new code is more concise than the old code and avoids boilerplate casting
from `any Error`.

## Source compatibility

In most cases, this change does not affect source compatibility. Swift does not
allow forming references to macros at runtime, so we don't need to worry about
type mismatches assigning one to some local variable.

We have identified two scenarios where a new warning will be emitted.

### Inferred return type from macro invocation

The return type of the macro may be used by the compiler to infer the return
type of an enclosing closure. If the return value is then discarded, the
compiler may emit a warning:

```swift
func pokePotato(_ pPotato: UnsafePointer<Potato>) throws { ... }

let potato = Potato()
try await Task.sleep(for: .months(3))
withUnsafePointer(to: potato) { pPotato in
  // ^ ^ ^ ⚠️ Result of call to 'withUnsafePointer(to:_:)' is unused
  #expect(throws: PotatoError.rotten) {
    try pokePotato(pPotato)
  }
}
```

This warning can be suppressed by assigning the result of the macro invocation
or the result of the function call to `_`:

```swift
withUnsafePointer(to: potato) { pPotato in
  _ = #expect(throws: PotatoError.rotten) {
    try pokePotato(pPotato)
  }
}
```

### Use of `#require(throws:)` in a generic context with `Never.self`

If `#require(throws:)` (but not `#expect(throws:)`) is used in a generic context
where the type of thrown error is a generic parameter, and the type is resolved
to `Never`, there is no valid value for the invocation to return:

```swift
func wrapper<E>(throws type: E.Type, _ body: () throws -> Void) throws -> E {
  return try #require(throws: type) {
    try body()
  }
}
let error = try #require(throws: Never.self) { ... }
```

We don't think this particular pattern is common (and outside of our own test
target, I'd be surprised if anybody's attempted it yet.) However, we do need to
handle it gracefully. If this pattern is encountered, Swift Testing will record
an "API Misused" issue for the current test and advise the test author to switch
to `#expect(throws:)` or to not pass `Never.self` here.

## Integration with supporting tools

N/A

## Future directions

- Adopting [typed throws](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md)
  to statically require that the error thrown from test code is of the correct
  type.

  If we adopted typed throws in the signatures of these macros, it would force
  adoption of typed throws in the code under test even when it may not be
  appropriate. For example, if we adopted typed throws, the following code would
  not compile:

  ```swift
  func cook(_ food: consuming some Food) throws { ... }

  let error: PotatoError? = #expect(throws: PotatoError.self) {
    var potato = Potato()
    potato.fossilize()
    try cook(potato) // 🛑 ERROR: Invalid conversion of thrown error type
                     // 'any Error' to 'PotatoError'
  }
  ```

  We believe it may be possible to overload these macros or their expansions so
  that the code sample above _does_ compile and behave as intended. We intend to
  experiment further with this idea and potentially revisit typed throws support
  in a future proposal.

## Alternatives considered

- Leaving the existing implementation and signatures in place. We've had
  sufficient feedback about the ergonomics of this API that we want to address
  the problem.

- Having the return type of the macros be `any Error` and returning _any_ error
  that was thrown even on mismatch. This would make the ergonomics of the
  subsequent test code less optimal because the test author would need to cast
  the error to the appropriate type before inspecting it.

  There's a philosophical argument to be made here that if a mismatched error is
  thrown, then the test has already failed and is in an inconsistent state, so
  we should allow the test to fail rather than return what amounts to "bad
  output".

  If the test author wants to inspect any arbitrary thrown error, they can
  specify `(any Error).self` instead of a concrete error type.

## Acknowledgments

Thanks to the team and to [@jakepetroules](https://github.com/jakepetroules) for
starting the discussion that ultimately led to this proposal.
