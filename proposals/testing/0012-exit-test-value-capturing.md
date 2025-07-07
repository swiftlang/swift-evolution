# Capturing values in exit tests

* Proposal: [ST-0012](0012-exit-test-value-capturing.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Paul LeMarquand](https://github.com/plemarquand)
* Status: **Active Review (Jul 7 - July 21, 2025)**
* Bug: [swiftlang/swift-testing#1157](https://github.com/swiftlang/swift-testing/issues/1157)
* Implementation: [swiftlang/swift-testing#1040](https://github.com/swiftlang/swift-testing/pull/1040) _et al._
* Review: ([pitch](https://forums.swift.org/t/pitch-capturing-values-in-exit-tests/80494)) ([review](https://forums.swift.org/t/st-0012-capturing-values-in-exit-tests/80963))

## Introduction

In Swift 6.2, we introduced the concept of an _exit test_: a section of code in
a test function that would run in an independent process and allow test authors
to test code that terminates the process. For example:

```swift
enum Fruit: Sendable, Codable, Equatable {
  case apple, orange, olive, tomato
  var isSweet: Bool { get }

  consuming func feed(to bat: FruitBat) {
    precondition(self.isSweet, "Fruit bats don't like savory fruits!")
    ...
  }
}

@Test func `Fruit bats don't eat savory fruits`() async {
  await #expect(processExitsWith: .failure) {
    let fruit = Fruit.olive
    let bat = FruitBat(named: "Chauncey")
    fruit.feed(to: bat) // should trigger a precondition failure and process termination
  }
}
```

This proposal extends exit tests to support capturing state from the enclosing
context (subject to several practical constraints.)

## Motivation

Exit tests in their current form are useful, but there is no reliable way to
pass non-constant information from the parent process to the child process,
which makes them difficult to use with parameterized tests. Consider:

```swift
@Test(arguments: [Fruit.olive, .tomato])
func `Fruit bats don't eat savory fruits`(_ fruit: Fruit) async {
  await #expect(processExitsWith: .failure) {
    let bat = FruitBat(named: "Chauncey")
    fruit.feed(to: bat) // 🛑 can't capture 'fruit' from enclosing scope
  }
}
```

In the above example, the test function's argument cannot be passed into the
exit test. In a trivial example like this one, it wouldn't be difficult to write
two tests that differ only in the case of `Fruit` they use in their exit test
bodies, but this approach doesn't scale very far and is generally an
anti-pattern when using Swift Testing.

## Proposed solution

We propose allowing the capture of values in an exit test when they are
specified in a closure capture list on the exit test's body.

## Detailed design

The signatures of the exit test macros `expect(processExitsWith:)` and
`require(processExitsWith:)` are unchanged. A test author may now add a closure
capture list to the body of an exit test:

```swift
@Test(arguments: [Fruit.olive, .tomato])
func `Fruit bats don't eat savory fruits`(_ fruit: Fruit) async {
  await #expect(processExitsWith: .failure) { [fruit] in
    let bat = FruitBat(named: "Chauncey")
    fruit.feed(to: bat)
  }
}
```

This feature has some necessary basic constraints:

### Captured values must be explicitly listed in a closure capture list

Swift Testing needs to know what values need to be encoded, sent to the child
process, and decoded. Swift macros including `#expect(processExitsWith:)` must
rely solely on syntax—that is, the code typed by a test author. An implicit
capture within an exit test body is indistinguishable from any other identifier
or symbol name.

Hence, only values listed in the closure's capture list will be captured.
Implicitly captured values will produce a compile-time diagnostic as they do
today.

### Captured values must conform to Sendable and Codable

Captured values will be sent across process boundaries and, in order to support
that operation, must conform to `Codable`. As well, captured values need to make
their way through the various internal mechanisms of Swift Testing and its host
infrastructure, and so must conform to `Sendable`. Conformance to `Copyable` and
`Escapable` is implied.

If a value that does _not_ conform to the above protocols is specified in an
exit test body's capture list, a diagnostic is emitted:

```swift
let bat: FruitBat = ...
await #expect(processExitsWith: .failure) { [bat] in
  // 🛑 Type of captured value 'bat' must conform to 'Sendable' and 'Codable'
  ...
}
```

### Captured values' types must be visible to the exit test macro

In order for us to successfully _decode_ captured values in the child process,
we must know their Swift types. Type information is not readily available during
macro expansion and we must, in general, rely on the parsed syntax tree for it.

The type of `self` and the types of arguments to the calling function are,
generally, known and can be inferred from context[^shadows]. The types of other
values, including local variables and global state, are not visible in the
syntax tree and must be specified explicitly in the capture list using an `as`
expression:

```swift
await #expect(processExitsWith: .failure) { [fruit = fruit as Fruit] in
  ...
}
```

Finally, the types of captured literals (e.g. `[x = 123]`) are known at compile
time and can always be inferred as `IntegerLiteralType` etc., although we don't
anticipate this will be particularly useful in practice.

If the type of a captured value cannot be resolved from context, the test author
will see an error at compile time:

```swift
await #expect(processExitsWith: .failure) { [fruit] in
  // 🛑 Type of captured value 'fruit' is ambiguous
  //     Fix-It: Add '= fruit as T'
  ...
}
```

See the **Future directions** section of this proposal for more information on
how we hope to lift this constraint. If we are able to lift this constraint in
the future, we expect it will not require (no pun intended) a second Swift
Evolution proposal.

[^shadows]: If a local variable is declared that shadows `self` or a function
  argument, we may incorrectly infer the type of that value when captured. When
  this occurs, Swift Testing emits a diagnostic of the form "🛑 Type of captured
  value 'foo' is ambiguous".

## Source compatibility

This change is additive and relies on syntax that would previously be rejected
at compile time.

## Integration with supporting tools

Xcode, Swift Package Manager, and the Swift VS Code plugin _already_ support
captured values in exit tests as they use Swift Testing's built-in exit test
handling logic.

Tools that implement their own exit test handling logic will need to account for
captured values. The `ExitTest` type now has a new SPI property:

```swift
extension ExitTest {
  /// The set of values captured in the parent process before the exit test is
  /// called.
  ///
  /// This property is automatically set by the testing library when using the
  /// built-in exit test handler and entry point functions. Do not modify the
  /// value of this property unless you are implementing a custom exit test
  /// handler or entry point function.
  ///
  /// The order of values in this array must be the same between the parent and
  /// child processes.
  @_spi(ForToolsIntegrationOnly)
  public var capturedValues: [CapturedValue] { get set }
}
```

In the parent process (that is, for an instance of `ExitTest` passed to
`Configuration.exitTestHandler`), this property represents the values captured
at runtime by the exit test. In the child process (that is, for an instance of
`ExitTest` returned from `ExitTest.find(identifiedBy:)`), the elements in this
array do not have values associated with them until the hosting tool provides
them.

## Future directions

- Supporting captured values without requiring type information

  We need the types of captured values in order to successfully decode them, but
  we are constrained by macros being syntax-only. In the future, the compiler
  may gain a language feature similar to `decltype()` in C++ or `typeof()` in
  C23, in which case we should be able to use it and avoid the need for explicit
  types in the capture list. ([rdar://153389205](rdar://153389205))

- Explicitly marking the body closure as requiring explicit captures

  Currently, if the body closure implicitly captures a value, the diagnostic the
  compiler provides is a bit opaque:

  > 🛑 A C function pointer cannot be formed from a closure that captures context

  In the future, it may be possible to annotate the body closure with an
  attribute, keyword, or other decoration that tells the compiler we need an
  explicit capture list, which would allow it to provide a clearer diagnostic if
  a value is implicitly captured.

- Supporting capturing values that do not conform to `Codable`

  Alternatives to `Codable` exist or have been proposed, such as
  [`NSSecureCoding`](https://developer.apple.com/documentation/foundation/nssecurecoding)
  or [`JSONCodable`](https://forums.swift.org/t/the-future-of-serialization-deserialization-apis/78585).
  In the future, we may want to extend support for values that conform to these
  protocols instead of `Codable`.

## Alternatives considered

- Doing nothing. There is sufficient motivation to support capturing values in
  exit tests and it is within our technical capabilities.

- Passing captured values as arguments to `#expect(processExitsWith:)` and its
  body closure. For example:

  ```swift
  await #expect(
    processExitsWith: .failure,
    arguments: [fruit, bat]
  ) { fruit, bat in
    ...
  }
  ```

  This is technically feasible, but:

  - It requires that the caller state the capture list twice;
  - Type information still isn't available for captured values, so you'd still
    need to _actually_ write `{ (fruit: Fruit, bat: Bat) in ... }` (or otherwise
    specify the types somewhere in the macro invocation); and
  - The language already has a dedicated syntax for specifying lists of values
    that should be captured in a closure.

- Supporting non-`Sendable` or non-`Codable` captured values. Since exit tests'
  bodies are, by definition, in separate isolation domains from the caller, and
  since they, by nature, run in separate processes, conformance to these
  protocols is fundamentally necessary.

- Implicitly capturing `self`. This would require us to statically detect during
  macro expansion whether `self` conformed to the necessary protocols _and_
  would preclude capturing any state from static or free test functions.

- Forking the exit test process such that all captured values are implicitly
  copied by the kernel into the new process. Forking, in the UNIX fashion, is
  fundamentally incompatible with the Swift runtime and the Swift thread pool.
  On Darwin, you [cannot fork a process that links to Core Foundation without
  immediately calling `exec()`](https://duckduckgo.com/?q=__THE_PROCESS_HAS_FORKED_AND_YOU_CANNOT_USE_THIS_COREFOUNDATION_FUNCTIONALITY___YOU_MUST_EXEC__),
  and `fork()` isn't even present on Windows.

## Acknowledgments

Thanks to @rintaro for assistance investigating swift-syntax diagnostic support
and to @xedin for humouring my questions about `decltype()`.

Thanks to the Swift Testing team and the Testing Workgroup as always. And thanks
to those individuals, who shall remain unnamed, who nerd-sniped me into building
this feature.
