# Macro for getting the current source location

* Proposal: [ST-NNNN](NNNN-sourcelocation-macro.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Bug: rdar://178259171
* Implementation: [swiftlang/swift-testing#1733](https://github.com/swiftlang/swift-testing/pull/1733)
* Review: ([pitch](https://forums.swift.org/t/pitch-swift-testing-macro-for-getting-the-current-source-location/87025))

## Introduction

Swift Testing includes a type, [`SourceLocation`](https://developer.apple.com/documentation/testing/sourcelocation),
that represents the precise location of something in a file (typically a .swift
file). Various Swift Testing API takes an instance of this type in order to
correctly attribute diagnostics and test issues that occur at test time. This
proposal covers introducing a macro that can be used as a default argument to
such functions.

## Motivation

The Swift standard library includes macros to get the current file ID, file
path, line, and column at compile time. These macros can then be used as default
function arguments to allow automagical capture of the caller's location in
source. For example, [`fatalError()`](https://developer.apple.com/documentation/swift/fatalerror(_:file:line:))
takes the file and line number and prints them to `stderr` when called.

Swift Testing needs to capture all four of these values, which is quite verbose
and somewhat tedious to work with, so various Swift Testing APIs encapsulate all
of them in a single argument of type `SourceLocation`. Swift Testing provides a
`#_sourceLocation` macro that expands, at compile time, to an appropriate
expression:

```swift
public func withKnownIssue(
  _ comment: Comment? = nil,
  isIntermittent: Bool = false,
  sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () throws -> Void
)
```

This macro, being underscored, is not formally supported, nor does it appear in
Swift Testing's documentation. It is also not sufficient to use something like
[`SourceLocation.init()`](https://developer.apple.com/documentation/testing/sourcelocation/init(fileid:filepath:line:column:))
as it will capture the _wrong_ source location[^wrongLoc]. Thus, test authors have no
supported mechanism for capturing an instance of `SourceLocation` short of
writing out all four arguments and constructing an instance of `SourceLocation`
manually.

[^wrongLoc]: For more information about this constraint, see [SE-0422](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0422-caller-side-default-argument-macro-expression.md).

## Proposed solution

I propose introducing a formally supported `#sourceLocation` macro to Swift
Testing that replaces the existing (unsupported) `#_sourceLocation` macro.

## Detailed design

A new macro is declared in Swift Testing:

```swift
/// Get the current source location.
///
/// - Returns: This expression's location in the current Swift source file.
///
/// At compile time, the testing library expands this macro to an instance of
/// ``SourceLocation`` referring to the location of the macro invocation itself.
/// If you want to create an instance of ``SourceLocation`` from specific file
/// ID, file path, line, and column values, use ``SourceLocation/init(fileID:filePath:line:column:)``
/// instead.
///
/// - Important: You must specify a module selector when you use this expression
///   macro to avoid conflicting with the Swift compiler's [`#sourceLocation(file:line:)`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/statements/#Line-Control-Statement)
///   statement.
///
///   ```swift
///   let here = #Testing::sourceLocation
///   ```
///
/// You can use this expression macro in place of [`#fileID`](https://developer.apple.com/documentation/swift/fileid()),
/// [`#filePath`](https://developer.apple.com/documentation/swift/filepath()),
/// [`#line`](https://developer.apple.com/documentation/swift/line()), and
/// [`#column`](https://developer.apple.com/documentation/swift/column()) as a
/// default argument to a function.
///
/// ```swift
/// func cookBurger(sourceLocation: SourceLocation = #Testing::sourceLocation) {
///   // ...
/// }
/// ```
@freestanding(expression) public macro sourceLocation() -> SourceLocation
```

Note that, as indicated in the documentation for this macro, you must specify
the module name when using this macro to avoid conflicting with the [`#sourceLocation(file:line:)`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/statements/#Line-Control-Statement)
statement built into the Swift language.

The existing `#_sourceLocation` macro will be marked deprecated, and will direct
developers to use `#Testing::sourceLocation` instead in its deprecation message.
The existing macro will remain available to use for source compatibility with
earlier Swift releases:

```diff
 /// Get the current source location.
 ///
 /// - Returns: This expression's location in the current Swift source file.
 ///
 /// At compile time, the testing library expands this macro to an instance of
 /// ``SourceLocation`` referring to the location of the macro invocation itself.
 /// If you want to create an instance of ``SourceLocation`` from specific file
 /// ID, file path, line, and column values, use ``SourceLocation/init(fileID:filePath:line:column:)``
 /// instead.
 ///
 /// You can use this expression macro in place of [`#fileID`](https://developer.apple.com/documentation/swift/fileid()),
 /// [`#filePath`](https://developer.apple.com/documentation/swift/filepath()),
 /// [`#line`](https://developer.apple.com/documentation/swift/line()), and
 /// [`#column`](https://developer.apple.com/documentation/swift/column()) as a
 /// default argument to a function.
 ///
 /// ```swift
 /// func cookBurger(sourceLocation: SourceLocation = #_sourceLocation) {
 ///   // ...
 /// }
 /// ```
+@available(swift, deprecated: 100000.0, renamed: "Testing::sourceLocation")
 @freestanding(expression) public macro _sourceLocation() -> SourceLocation = #externalMacro(module: "TestingMacros", type: "SourceLocationMacro")
```

### Example usage

The macro is straightforward to use as a default argument:

```swift
func expectEdible(
  _ food: some Food,
  sourceLocation: SourceLocation = #Testing::sourceLocation
) {
  #expect(food.isEdible, sourceLocation: sourceLocation)
}
```

## Source compatibility

This macro is additive and has no impact on existing Swift source code.

## Integration with supporting tools

No additional integration with tools is required.

## Future directions

- In the future, we likely want to adjust the Swift compiler to distinguish the
  use of `#sourceLocation` in expression position from its use in statement
  position, and to only use the compiler statement if `#sourceLocation`
  unambiguously refers to it rather than to a macro.

## Alternatives considered

- **Formally supporting the existing `#_sourceLocation` macro.** This symbol is
  underscored and does not appear in documentation, and the use of underscored
  symbols is normally a "tell" for developers that they're using something in
  Swift that isn't guaranteed to exist in future Swift releases.

- **Naming the macro something different.** Because of the existing
  `#sourceLocation(file:line:)` statement, test authors must use a module
  selector to qualify `#sourceLocation` (as `#Testing::sourceLocation`). We
  considered alternatives such as `#here` and `#currentSourceLocation`, but
  `#sourceLocation` seems the most appropriate name for it. It is our hope that,
  in the future, the compiler will allow us to unambiguously use
  `#sourceLocation` as a default argument (see **future directions** for more
  discussion).

- **Including this macro and the `SourceLocation` type in the standard library
  instead of Swift Testing.** The value of `SourceLocation` isn't
  testing-specific. However, it necessarily includes the complete path to a
  source file (i.e. `#filePath`) that may leak proprietary information about a
  developer's build system when used in production. As such, it is not suitable
  for general use in the Swift ecosystem. It may be appropriate for the standard
  library to include some _equivalent_ macro that can optimize away individual
  members the calling code doesn't use, but such a macro is beyond the scope of
  this proposal.