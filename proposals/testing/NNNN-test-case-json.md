# Add test case information to the JSON event stream

* Proposal: [ST-NNNN](NNNN-test-case-json.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#2060](https://github.com/swiftlang/swift-testing/pull/2060)
* Review: ([pitch](https://forums.swift.org/...))

## Introduction

Swift Testing's JSON event stream schema currently does not cover parameterized
tests except for a single `"isParameterized"` field. This proposal adds coverage
for test cases to allow consuming tools to reason about them in detail.

## Motivation

Tools that consume the current JSON event stream have little to no information
about test _cases_, i.e. the individual invocations of parameterized test
functions with a specific set of argument values. This information is important
for tools that consume the JSON event stream. For example, if a single test case
fails, such tools do not have a way to indicate which one it was.

## Proposed solution

I propose adding information about test cases to the JSON event stream schema.
Test case information may be very verbose, so we need some way to report it
once, report it only when the test case is actually going to appear in the event
stream (to avoid dead weight), and later refer back to it in a lightweight
fashion. Hence, I propose a new JSON record type describing a test case that we
emit only on first appearance of the test case, and a test case ID type that we
use to refer to the test case in all subsequent appearances.

I also propose a small addition to Swift Testing's Swift API to make `Test.Case`
conform to `Identifiable`, so test case IDs can be used from within Swift code.

> [!NOTE]
> Non-parameterized test functions have a single implicit test case; this test
> case is ignored by the JSON event stream, and the proposed changes to the JSON
> event stream schema do not apply to such functions unless otherwise specified.

## Detailed design

### Changes to test function rules

The `<test-function>` rule, which describes a test function, is updated to
include information about its parameters when it describes a parameterized test:

```diff
-  "isParameterized": <bool>, ; is this a parameterized test function or not?
+  ["parameters": <array:test-parameter>,] ; the test function's parameters, if any
   ["tags": <array:tag>,] ; the tags associated with this test function
```

If a test function is _not_ parameterized, its description in the event stream
does not include the `"parameters"` field. The `"isParameterized"` field can now
be inferred from the presence of the `"parameters"` field, so the former is
removed from the schema. It is still present in previous schema versions.

The `<test-parameter>` rule is added and describes a test function parameter:

```
<test-parameter> ::= {
  [["label": <string>,]  ; the parameter's label (externally visible name), if any
  "name": <string>,]     ; the parameter's (internally visible) name, if any
  ["type": <type-info>,] ; the parameter's type, if known
}
```

Whether to emit `"label"`, `"name"`, both, or neither depends on which are
available:

- In languages such as Swift where a function parameter can have both an
  externally visible label and an internally visible name, the implementation
  should include both if available.
  - If the label and name are equal, the implementation may emit both fields or
    just the `"name"` field.
- In languages such as C where parameters only have a single name, the
  implementation should emit the `"name"` field only.
- If neither name is available programmatically, or if the language does not
  name parameters at all (I'm looking at you, Bash!), the implementation may
  omit both fields.

### New record type

A new record kind is added, `<test-case-record>`:

```
<test-case-record> ::= {
  <version>,
  "kind": "testCase",
  "payload": <test-case>
}

<test-case> ::= {
  "testID": <test-id>,
  "arguments": <array:test-case-argument>,
  "id": <test-case-id>,
  ["hasStableID": <bool>] ; whether "id" is stable over multiple test runs
}
```

And the `<output-record>` rule is updated:

```diff
-<output-record> ::= <test-record> | <event-record>
+<output-record> ::= <test-record> | <test-case-record> | <event-record>
```

A record of kind `"testCase"` is emitted prior to the first appearance of the
described test case in the event stream, but after the test record describing
the test with ID `"testID"`, so that a consumer can easily reconstruct the graph
of tests and test cases later on. The exact order in which they are emitted
relative to events in the event stream is otherwise unspecified.

If a test case has a stable ID, that means that event stream consumers can rely
on that ID being used for the same test case (that is, the same argument values
to the same test function) on subsequent runs (assuming the code under test has
not changed substantively). If the `"hasStableID"` field is not present, an
event stream consumer must assume the test case's ID is _not_ stable.

If a test case is repeated (i.e. because the implementation runs a parameterized
test function more than once), the implementation should only emit a record for
that test case once.

### Rules about test case arguments

Rules describing test case arguments (distinct from parameters) are added:

```
<test-case-argument> ::= <expression-value> | <test-case-argument-details>

<test-case-argument-details> ::= {
  "value": <expression-value>, ; the argument's value
  ["type": <type-info>,] ; the argument value's type, if different from that of
                         ; the corresponding test parameter
}
```

The order of arguments in the `<test-case>` rule matches the order of parameters
in the updated `<test-function>` rule.

> [!NOTE]
> Due to language features such as tuple destructuring and `zip(_:_:)`, the
> number of arguments may not match the number of _argument lists_ passed to the
> test function's `@Test` attribute (or some equivalent thereof):
>
> ```swift
> @Test(arguments: zip(0 ..< 10, "abcdefghij"))
> func numberAndLetter(_ x: Int, _ y: Character) { /* ... */ }
> ```
>
> In this case, the test function has two parameters, of types `Swift.Int` and
> `Swift.Character`. Each test case has two arguments: `0` and `"a"`, `1` and
> `"b"`, etc.
>
> Regardless, the number of parameters always equals the number of arguments in
> the JSON event stream.

The type of a parameter (as represented by the `"type"` field of the
`<test-parameter>` rule above) is always known in Swift, but may not be known in
weakly-typed languages or may need to be inferred at runtime on a case-by-case
(no pun intended) basis. The `"type"` field is therefore included in the
`<test-case-argument-details>` too. Implementations can include it if the type,
determined at runtime, is different from the corresponding parameter's type.

If the `"type"` field is not present, it can be assumed to equal the value of
the corresponding parameter's `"type"` field. If neither field is present, type
information is not available; the event stream consumer might choose to
represent the type in this case as a [top type](https://en.wikipedia.org/wiki/Any_type)
such as `Swift.Any`, or omit any representation of the type entirely.

Per the [Liskov substitution principle](https://en.wikipedia.org/wiki/Liskov_substitution_principle),
the argument's type must only ever be a subtype of (or equal to) the
corresponding parameter's type. Whether or not this requirement holds in
languages other than Swift is beyond the scope of this proposal.

If the only information available about the argument is its value (e.g. it is a
scalar value), the JSON can be simplified to just `<expression-value>`, i.e. a
string describing that value. `<expression-value>` is updated to clarify the
nature of said string value in existing and new contexts:

```diff
 <expression-value> ::= <string> ; a description of the value
+                                ; produced by passing it to `String(describingForTest:)`
+                                ; or equivalent.
```

### Identifying test cases

A rule describing a test case's unique ID is added:

```
<test-case-id> ::= <string> ; a unique identifier for this test case
```

A test case's ID is an opaque string and, when combined with a test ID, uniquely
identifies that test case in a specific test run. The `"hasStableID"` field of
the corresponding test case record indicates if the ID uniquely identifies the
test case across multiple runs.

The `<event>` rule, which describes an event that occurs during a test run, is
updated to include the test case ID for those events that sometimes or always
apply to a specific test case of a parameterized test function:

```diff
-  ["testID": <test-id>,]
+  ["testID": <test-id>,
+  ["testCaseID": <test-case-id>,]]
   ["iteration": <number>,] ; the iteration number (if the event is recorded
```

An implementation can use the value of the `"testCaseID"` field to subsequently
look up a full test case description. The `"testCaseID"` field is not present
for events related to a non-parameterized test function, nor is it present if
the `"testID"` field is not present.

> [!NOTE]
> The `<event-kind>` rule already includes event kinds for test cases such as
> `"testCaseStarted"`.

Event stream consumers should also note: Swift Testing's test iteration/repetition
feature is implemented such that, when it is enabled, the event stream will
include events of kind `"testCaseStarted"` etc. for each iteration of a
non-parameterized test. These events will not have a `"testCaseID"` field set
(since the test function is non-parameterized).

### Changes to the Swift `Test.Case` type

`Test.Case` is made to conform to `Identifiable`, including the definition of a
new `Test.Case.ID` type and a new `id` property:

```swift
extension Test.Case: Identifiable {
  /// The ID of a test case.
  ///
  /// Instances of this type are considered unique within the scope of a given
  /// parameterized test function. They are not necessarily unique across two
  /// different ``Test`` instances.
  public struct ID: Sendable, Equatable, Hashable, CustomStringConvertible { /* ... */ }

  public var id: ID { get }
}
```

The value of the `Test.Case.ID.description` property is unspecified, but it will
not be a human-readable value. <!-- It'll probably be something like a SHA-256
hash or a UUID, but that's not part of the API contract. -->

The value of the `id` property for the single implicit test case of a
non-parameterized test is unspecified, but valid.

See the **Future Directions** section for a discussion of a `Test.Case.arguments`
property.

## Source compatibility

These changes are additive to our API surface, but see **Integration with Supporting Tools**
for how these changes affect tools SPI.

## Integration with supporting tools

Supporting tools will need to update their JSON schema version support to
version `"6.6"` or higher to get this new data.

Tools that use the existing tools-only SPI definition of `Test.Case.ID` may
need to be updated as the type's declaration will change and its conformance to
`Codable` will be removed.

## Future directions

- **Adding a `Test.Case.arguments` property.** We would also like to include a
  property on `Test.Case` that describes its arguments, however we need to take
  move-only argument values into consideration as another future direction, and
  they affect the overall shape of the API we would propose. It would _likely_
  use `Span` and be shaped something like:

  ```swift
  extension Test.Case {
    public struct Argument.List: Sendable, Iterable, ~Copyable, ~Escapable {
      public typealias Element = any Sendable & ~Copyable & ~Escapable
      public var count: Int { get }
      public subscript(position: Int) -> Element { yielding borrow }
    }

    public var arguments: Argument.List { yielding borrow }
  }
  ```

  Such an API needs to wait for several language features to be implemented
  first.

  This change is tracked by [swift-testing-#1889](https://github.com/swiftlang/swift-testing/issues/1889).

- **Changing `swift test` to allow filtering by test case ID.** It should be
  possible to run only a single test case ID from a given test if you know the
  test case's ID. We need to design this functionality, including providing a
  way for users at the command line to see a test case's programmatic ID, which
  is beyond the scope of this proposal.

## Alternatives considered

- **Excluding the `"hasStableID"` field from the `<test-case>` rule.** This
  field can be useful when designing IDEs and other tools that consume this
  information, but it is not required to identify a test case and likely does
  not apply to other testing libraries. We decided to include it in the schema
  and in Swift Testing's implementation because it enables a better user
  experience (e.g. via the `swift test` improvements mentioned in **Future Directions**),
  but other implementations may omit it if it is not relevant to them.

- **Including information about all of a test's cases in the `<test-function>`
  rule.** This works, more or less, when the sequence of test cases is small and
  precomputed, such as an array of three elements. It faceplants if the sequence
  is extremely large or cannot be known in advance. For example, the following
  would be prohibitive to precompute:

  ```swift
  @Test(arguments: 0...) func isTactile(x: Int) {
    #expect(x.isTactile)
  }
  ```

  And the following is not computable in advance:

  ```swift
  static var arguments: some Sequence<Int> {
    0 ..< Int.random(in: 1...)
  }
  @Test(arguments: arguments) func isScrumptious(x: Int) {
    #expect(x.isScrumptious)
  }
  ```

  Hence, we instead defer describing individual test cases to the point where we
  first encounter them.

- **Including full test case information in every event that might need it.**
  This produces a prohibitively large amount of repeated data.

- **Using a monotonically increasing integer as the test case ID.** For example,
  the first test case of a parameterized test function has ID `0`, the second
  `1`, etc. This is trivial to implement, but is inherently unstable: consider a
  dictionary or set being used as the argument list to a test function, where
  the order in which elements are enumerated is effectively randomized on
  process start due to Swift's random hash seeding feature.
