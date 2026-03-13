# Custom reflection during testing

* Proposal: [ST-NNNN](NNNN-filename.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#1594](https://github.com/swiftlang/swift-testing/pull/1594)
* Review: ([pitch](https://forums.swift.org/t/pitch-custom-reflection-during-testing/85190))

## Introduction

Swift Testing includes the ability to log details about a failed expectation
including members of values captured while that expectation was evaluated. This
proposal covers adding a customization point for developers to let them specify
exactly what information should be included in test output.

## Motivation

Since we introduced Swift Testing, Xcode has had the ability to break down
expressions produced by an expectation when it fails. These breakdowns can help
test authors quickly figure out exactly why a test failed. For example, given
the following test:

```swift
struct MonsterTruck: Equatable {
  var color: Color
  var numberOfWheels: Int
}

@Test func `Monster trucks`() {
  let crushinator = MonsterTruck(color: .red, numberOfWheels: 4)
  let truckasaurusRex = MonsterTruck(color: .green, numberOfWheels: 5)
  #expect(crushinator == truckasaurusRex)
}
```

Xcode provides a breakdown of the operands to the failed `==` comparison
(`crushinator` and `truckasaurusRex` in this example). As of recent Swift 6.4
development toolchains, our console output via `swift test` also includes
similar output. For the test above, test authors will now see something like:

```
◇ Test "Monster trucks" started.
✘ Test "Monster trucks" recorded an issue at [...]: Expectation failed: crushinator == truckasaurusRex
↳ crushinator == truckasaurusRex → false
↳   crushinator → MonsterTruck(color: Color.red, numberOfWheels: 4)
↳     color → .red
↳     numberOfWheels → 4
↳   truckasaurusRex → MonsterTruck(color: Color.green, numberOfWheels: 5)
↳     color → .green
↳     numberOfWheels → 5
✘ Test "Monster trucks" failed after 0.005 seconds with 1 issue.
```

Swift Testing generates these breakdowns by parsing the `condition` argument to
`#expect()` at compile time and, at runtime, passing interesting subexpressions
to [`Mirror.init(reflecting:)`](https://developer.apple.com/documentation/swift/mirror).

For a typical Swift value, `Mirror.init(reflecting:)` will produce an instance
of `Mirror` that contains a list of all the stored properties of the original
value. Developers can also customize the output of `Mirror.init(reflecting:)` by
making their types conform to [`CustomReflectable`](https://developer.apple.com/documentation/swift/customreflectable).
Swift Testing implicitly honours conformances to `CustomReflectable` in the
output it produces.

At runtime, a developer might only be concerned with reflecting the basic
properties of a value, or they might want to obscure properties that represent
implementation details that shouldn't be presented to users. But when running
tests, that developer may want to be able to see more extensive information.
Alternatively, a developer might want to limit or reformat the information shown
during testing to make it easier to read, understand, or process test logs.

## Proposed solution

I propose adding a new protocol to Swift Testing named `CustomTestReflectable`.
Types that conform to this protocol can provide a custom `Mirror` instance
distinct from the default _and_ distinct from what is available through
`CustomReflectable`.

When Swift Testing constructs a `Mirror` for some value, it will check if the
value conforms to this protocol. If the value conforms, Swift Testing will use
the provided instance of `Mirror`. If not, Swift Testing will proceed to make
its existing call to `Mirror.init(reflecting:)` (and so will continue to use
the mirror produced by a conformance to `CustomReflectable` if one exists.)

## Detailed design

The following protocol is added to Swift Testing:

```swift
/// A protocol describing types with a custom reflection when presented as part
/// of a test's output.
///
/// ## See Also
///
/// - ``Swift/Mirror/init(reflectingForTest:)``
public protocol CustomTestReflectable {
  /// The custom mirror for this instance.
  ///
  /// Do not use this property directly. To get the test reflection of a value,
  /// use ``Swift/Mirror/init(reflectingForTest:)``.
  var customTestMirror: Mirror { get }
}
```

The name of this protocol mirrors that of (no pun intended) the existing
[`CustomStringConvertible`](https://developer.apple.com/documentation/swift/customstringconvertible)
/ [`CustomTestStringConvertible`](https://developer.apple.com/documentation/Testing/CustomTestStringConvertible)
protocol pair.

As well, the following convenience initializers are added to `Mirror`:

```swift
extension Mirror {
  /// Initialize this instance so that it can be presented in a test's output.
  ///
  /// - Parameters:
  ///   - subject: The value to reflect.
  ///
  /// ## See Also
  ///
  /// - ``CustomTestReflectable``
  public init(reflectingForTest subject: some CustomTestReflectable)

  /// Initialize this instance so that it can be presented in a test's output.
  ///
  /// - Parameters:
  ///   - subject: The value to reflect.
  ///
  /// ## See Also
  ///
  /// - ``CustomTestReflectable``
  public init(reflectingForTest subject: some Any)
}
```

These new symbols will only be available in test targets, so they carry no
compile-time or runtime costs in production code.

## Source compatibility

This change is additive.

## Integration with supporting tools

No changes are needed in supporting tools to adopt this protocol as the testing
library adopts it automatically.

The following JSON event stream schema changes are proposed:

```diff
 <issue> ::= {
   "isKnown": <bool>, ; is this a known issue or not?
   ["sourceLocation": <source-location>,] ; where the issue occurred, if known
+  ["expression": <expression>,] ; the expression that generated the issue, if any
 }
+
+<expression> ::= {
+  "sourceCode": <string>, ; the source code of this expression
+  ["runtimeValue": <string>,] ; a description of this expression's runtime
+                              ; value, if available
+  ["runtimeTypeName": <string>,] ; the name of the type of "runtimeValue". If
+                                 ; coming from Swift Testing, a fully-qualified
+                                 ; Swift type name, otherwise unspecified
+  ["children": <array:expression>,] ; any available child expressions within
+                                    ; this expression
+}
```

These changes allow tools that adopt the JSON event stream to inspect the values
that Swift Testing captures when an expectation fails and causes an issue to be
recorded.

## Future directions

None identified.

## Alternatives considered

- **Doing nothing.** Beginning in Swift 6.4, this output is more prominently
  displayed, so it seems apt to give developers the ability to customize it.

- **Just using `CustomReflectable`.** If a type conforms to `CustomReflectable`,
  we do use that conformance, but some developers need more fine-grained control
  over the output produced at test time.

## Acknowledgments

Thanks to Stuart Montgomery for his earlier work to capture values from
expectations and their corresponding reflections.