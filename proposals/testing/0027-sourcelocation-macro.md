# Macro for getting the current source location

* Proposal: [ST-0027](0027-sourcelocation-macro.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Stuart Montgomery](https://github.com/stmontgomery)
* Status: **Active Review (August 3...August 13, 2026)**
* Bug: rdar://178259171
* Implementation: [swiftlang/swift-testing#1733](https://github.com/swiftlang/swift-testing/pull/1733)
* Review: ([pitch](https://forums.swift.org/t/pitch-swift-testing-macro-for-getting-the-current-source-location/87025)) ([review](https://forums.swift.org/t/st-0027-macro-for-getting-the-current-source-location/88743))

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
  unambiguously refers to it rather than to a macro. Such a change would be
  source-compatible with any existing uses of `#Testing::sourceLocation`.

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
  testing-specific.  The Swift Testing code owners discussed this alternative
  with some of the standard library code owners and determined that Swift
  Testing's use case doesn't align with what we'd expect to see in the standard
  library:
  
  - Swift Testing needs to include the complete path to a source file (i.e.
    `#filePath`) in its macro expansion. Including that path may leak
    proprietary information about a developer's build system when used in
    production. Swift Testing also needs to include the source file's file ID,
    but it is unlikely that a standard library version of this macro would
    include both.
  - If the standard library added a `SourceLocation` type, Swift Testing would
    not be able to adopt it until its Darwin deployment targets were minimally
    aligned with the version of the standard library that first included said
    type. (This constraint is also the reason Swift Testing's attachments
    feature does not make use of `RawSpan`).
  - If the standard library added its own `#sourceLocation` macro, it would
    return a value of a type not equal to our own, so Swift Testing would need
    to indefinitely maintain _two_ copies of most of our API surface: one that
    used our existing type and one that used the standard library type. The
    Swift Testing code owners do not consider the scope of this maintenance
    burden to be worth the potential benefits.

    It might be possible for the standard library to introduce a protocol such
    as `ExpressibleByTupleLiteral` and have its macro return a value of type
    `T: ExpressibleByTupleLiteral`, similar to what is done for `#fileID` etc.
    However, that protocol would necessarily have an availability constraint and
    therefore so would the macro, and therefore so would any APIs that use the
    macro. We would still need to maintain two overloads for most of our API
    suface (one relying on the standard library type/macro and one relying
    solely on symbols from Swift Testing).
