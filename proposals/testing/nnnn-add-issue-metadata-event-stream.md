# Include additional issue metadata in event stream

- Proposal: [ST-NNNN](NNNN-filename.md)
- Authors: [Jerry Chen](https://github.com/jerryjrchen)
- Review Manager: TBD
- Status: **Awaiting implementation**
- Implementation:
  [swiftlang/swift-testing#NNNNN](https://github.com/swiftlang/swift-testing/pull/NNNNN)
- Review: ([pitch](https://forums.swift.org/...))

## Introduction

The event stream provides a stable interface for external tools to read test
events. When encountering an issue while running tests, Swift Testing generates
an event which includes a limited amount of issue metadata. We propose enriching
this metadata with additional fields.

## Motivation

Tools such as Xcode and VS Code can consume the "issue recorded" event from
Swift Testing's JSON event stream and use that to present test failure details
to the user. However, there isn't enough structured information present to
distinguish between different kinds of issues.

For example, the following test fail due to different kinds of issues:

```swift
@Test func `Issue A`() async throws {
    Issue.record("Issue A")
}
@Test func `Issue B`() async throws {
    struct ErrorB: Error {}
    throw ErrorB()
}
```

The event stream will contain similar issue metadata for both, differing only in
their `sourceLocation`:

```json
"issue": {
  "isFailure": true,
  "isKnown": false,
  "severity": "error",
  "sourceLocation": { ... }
}
```

With the proposed solution, tools can access additional metadata to distinguish
between issue types and provide richer context for test failures to their end
users.

## Proposed solution

We propose adding new fields to the issue event type.

## Detailed design

These changes are proposed for event stream schema version `6.5`.

These new fields provide structured information about issues that previously
weren't available in a machine-readable form:

- **Error:** an error was thrown.

- **Miscount:** a miscount of something led to this issue. Currently, Swift
  Testing will fill this if a confirmation was confirmed more/fewer times than
  expected.

<!-- TODO: Consider a more specific field name e.g. "confirmationMiscount"-->

- **Time limit:** the test exceeded a time limit. The unit is seconds, which
  follows the precedent set in an
  [earlier event stream proposal](./0019-include-tags-bugs-and-timeline-in-event-stream.md).

- **Known issue comment:** if a known issue [that was expected but did not occur
  at test time][resolve-a-known-issue] has a human-readable comment, it is
  included as the value of the existing `"isKnown"` field.

[resolve-a-known-issue]:
  https://developer.apple.com/documentation/Testing/known-issues#Resolve-a-known-issue

- **Expression:** the expression associated with the issue. This is primarily
  used to capture the body of a failed expectation. However, it can also
  describe a confirmation that was miscounted.

The following field is added for all events:

- **Comments:** a common event field that stores user provided comments.

  For issues, users can supply comments when recording issues or creating
  expectations, e.g. `Issue.record("A comment")` or
  `#expect(a == b, "A comment")`.

### Schema changes

We propose the following changes to the [event stream JSON schema][]:

[event stream JSON schema]:
  https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/JSON.md

New common data types:

- `comment` and `time` are currently type aliases which unify references to
  their respective concepts throughout the schema. In the future, we could
  easily change the definition of these types to more complex nested structures.

- `numeric-range` is limited, for simplicity, to representing inclusive bounds.

<!-- TODO: we might need to support exclusive bounds since the confirmation
range is a RangeExpression which could be a Range and not just a ClosedRange-->

```diff
+<comment> ::= <string> ; human-readable, developer-supplied text

+<time> ::= <number> ; a timestamp or duration expressed in (floating-point) seconds

+<numeric-range> ::= {
+  ["min": <number>,] ; lower-bound, inclusive
+  ["max": <number>] ; upper-bound, inclusive, must be ≥ min (if present)
+}
```

Events changes:

<!-- TODO: fill out justification for messages -->

```diff
<event> ::= {
...
+  ["comments": <array:comment>,] ; comments provided by the test author
-  "messages": <array:message>,
+  ["messages": <array:message>,] ; messages become optional and are omitted by default
}

<issue> ::= {
 ...
+  ["expression": <expression>,] ; an expression associated with the issue
+  ["error": <error>,] ; the associated error, if any
+  ["miscount": <miscount>,] ; an associated miscount (too high or too low)
+  ["exceededTimeLimit": <time>,] ; the time limit, in seconds, that was exceeded
-  "isKnown": <bool>,
+  ["isKnown": <bool> | <comment>] ; whether the issue is known (optionally, the comment associated with the known issue)
}

+<error> ::= {
+  ["code": <number>,]
+  ["domain": <string>,]
+  ["description": <string>,]
+  ["type": <type-info>]
+}

+<miscount> ::= {
+  "actual": <number>,
+  "expected": <number> ; when the confirmation specifies a single count
+            | <numeric-range> ; when the confirmation specifies a range
+}

+<expression> ::= {
+  "sourceCode": <string>, ; unmodified source code
+  ["value": <expression-value>,] ; the expression's value if available
+  ["type": <type-info>,] ; type for the runtime value
+  ["children": <array:expression>] ; subexpressions, if present
+}
+
+<expression-value> ::= <string> ; a description of the value
+                       | <number> ; the value, if numeric

```

`type-info` will support types from all languages, not just Swift, so only
applicable fields will be present. For example, C doesn't have fully qualified
names nor, in most implementations, mangled names.

```diff
+<type-info> ::= {
+  ["fullyQualifiedName": <string>,]  ; e.g. "Swift.Bool", "std::string"
+  ["unqualifiedName": <string>,]   ; e.g. "Bool", "string"
+  ["mangledName": <string>,] ; e.g. "Sb", "NSt3__112basic_string..."
+}
```

<!-- TODO: Impl details:
- Fill in <comment> elsewhere in the JSON ABI spec
- Fill in <time> elsewhere in the JSON ABI spec
-->

### Sample JSON output

<!-- TODO: after demo impl is ready -->

## Source compatibility

There are no source compatibility concerns.

## Integration with supporting tools

The definition of the `isKnown` field will change from the 6.4 schema. It will
no longer be a required boolean-valued field, and will instead be an optional
boolean-valued or string-valued field.

All other fields are purely additive to the JSON ABI.

Existing tools that integrate with Swift Testing will need to update their
integration code to read the new fields. For example, the implementation of
targeted interoperability needs to be updated to read the error from the
`EncodedIssue` type.

## Future directions

<!-- TODO: check the current status of symbolication on Linux -->

- We considered including the **issue backtrace** as an optional field. However,
  as of this proposal, there is no yet a way to symbolicate `Issue` backtrace
  addresses on Linux. Furthermore, in-process symbolication is an expensive
  operation, so the design will warrant additional care and scrutiny.

  Issue backtrace can be added in a follow-up proposal once there are solutions
  to both of these challenges. For consistency, the backtrace field should be
  included in the API for the `Issue` structure at the time it is included in
  the JSON schema.

- We'd also like to include **exception information** in the `<issue>`
  structure. Although Swift doesn't use exceptions for error handling, test code
  may interoperate with languages which do (e.g. Objective-C, Java). The `error`
  field in the issue metadata may be a good candidate to place exception
  metadata, but exceptions do not share many of the same fields (code, domain,
  type) as errors derived from `NSError` in Foundation.

## Alternatives considered

We considered introducing a "kind" field to issue, which follows the existing
pattern set by event kind:

```diff
<issue> ::= {
 ...
+  "kind": <issue-kind>
}

+<issue-kind> ::= "unconditional" | "expectationFailed" | "confirmationMiscounted" | ...

<event> ::= {
  "kind": <event-kind>,
  ...
}

<event-kind> ::= "runStarted" | "testStarted" | "testCaseStarted" | ...
```

However, issue kind is primarily an implementation detail of the testing
library, and not all tools that consume test events support all the issue kinds
that the testing library emits.

Furthermore, tools can derive the same information that issue kind provides by
inspecting the issue fields. For example, presence of an `miscount` field
indicates this issue was the "confirmationMiscounted" kind.

## Acknowledgments

Thanks to Jonathan Grynspan and Stuart Montgomery for providing feedback on the
proposal.
