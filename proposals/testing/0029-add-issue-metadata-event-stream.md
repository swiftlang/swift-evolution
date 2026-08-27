# Include additional issue metadata in event stream

- Proposal: [ST-0029](0029-add-issue-metadata-event-stream.md)
- Authors: [Jerry Chen](https://github.com/jerryjrchen)
- Review Manager: [Rachel Brindle](https://github.com/younata)
- Status: **Active Review (Aug 27...Sep 10, 2026)**
- Implementation:
  [swiftlang/swift-testing#1839](https://github.com/swiftlang/swift-testing/pull/1839)
- Review:
  ([pitch](https://forums.swift.org/t/pitch-add-issue-fields-to-json-abi-schema/88898))
  ([review](https://forums.swift.org/t/st-0029-include-additional-issue-metadata-in-event-stream/89234))

## Introduction

The event stream provides a stable interface for external tools to read test
events. When encountering an issue while running tests, Swift Testing generates
an event which includes a limited amount of issue metadata. We propose enriching
this metadata with additional fields.

## Motivation

### Provide richer issue metadata for tools

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

### Support languages and libraries beyond Swift and Swift Testing

We envision that tools which consume Swift Testing events can also support other
test libraries and their respective test events. If Swift Testing defines an
issue schema that can be re-used for issues across testing libraries, tools can
take advantage of the format to unify their issue handling logic for different
test libraries.

Therefore, we designed new data types to support languages other than Swift, and
ensured that new issue fields would be relevant for other testing libraries.

## Proposed solution

We propose adding new fields to the issue event type.

## Detailed design

These changes are proposed for event stream schema version `6.5`.

These new fields provide structured information about issues that previously
weren't available in a machine-readable form:

- **Error:** an error was thrown.

- **Confirmation miscount:** a confirmation was confirmed more/fewer times than
  expected.

- **Time limit:** the test exceeded a time limit. The unit is seconds, which
  follows the precedent set in an
  [earlier event stream proposal](./0019-include-tags-bugs-and-timeline-in-event-stream.md).

- **Expression:** the expression associated with the issue. This is primarily
  used to capture the body of a failed expectation. However, it can also
  describe a confirmation that was miscounted.

Modify these pre-existing fields:

- **Known issue with optional comment:** whether this issue is a [known
  issue][known-issues]. This field becomes optional, and resolves to false by
  default. If an issue was marked as known with a human-readable comment, the
  field contains the comment instead of a boolean.

[known-issues]: https://developer.apple.com/documentation/Testing/known-issues

- **Messages:** in the context of issues, this field contains human-readable
  descriptions of the failure. But, after adding the issue fields in this
  proposal, tools can reconstruct a human-readable description from the updated
  structure. Therefore, this field becomes optional and will no longer be
  included by default to avoid the performance cost of generating and
  serializing this redundant field.

  Tools can continue to receive messages in the event stream using the
  environment variable `SWIFT_TESTING_EVENT_STREAM_MESSAGES_FIELD_ENABLED`.

The following field is added for all events:

- **Comments:** a common event field that stores user provided comments.

  For issues, users can supply comments when recording issues or creating
  expectations, e.g. `Issue.record("A comment")` or
  `#expect(a == b, "A comment")`.

  User-provided comments for `withKnownIssue` are not included here, and are
  instead included in the `isKnown` field.

- **Source Location:** this field is already present in the issue schema, but
  the event stream can include the source location for other event kinds: value
  attached and skipped test cases.

  Since it is a shared field, this proposal moves it to the top-level `<event>`.

### Schema changes

We propose the following changes to the [event stream JSON schema][]:

[event stream JSON schema]:
  https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/JSON.md

New common data types:

- `comment` and `time` are currently type aliases which unify references to
  their respective concepts throughout the schema. In the future, we could
  easily change the definition of these types to more complex nested structures.

- `numeric-range` represents inclusive bounds.

```diff
+<comment> ::= <string> ; human-readable, developer-supplied text

+<time> ::= <number> ; a timestamp or duration expressed in (floating-point) seconds

+<numeric-range> ::= {
+  ["min": <integer>,] ; lower-bound, inclusive
+  ["max": <integer>] ; upper-bound, inclusive, must be ≥ min (if present)
+}
```

Events changes:

```diff
<event> ::= {
...
+  ["comments": <array:comment>,] ; comments provided by the test author
-  "messages": <array:message>,
+  ["messages": <array:message>,] ; messages become optional and are omitted by default
+  ["sourceLocation": <source-location>,] ; source location is moved to the top level event
}

<issue> ::= {
 ...
+  ["expression": <expression>,] ; an expression associated with the issue
+  ["error": <error>,] ; the associated error, if any
+  ["confirmationMiscount": <miscount>,] ; an associated confirmation miscount (too high or too low)
+  ["exceededTimeLimit": <time>,] ; the time limit, in seconds, that was exceeded
-  "isKnown": <bool>,
+  ["isKnown": <bool> | <comment>] ; whether the issue is known (optionally, the comment associated with the known issue)
-  ["sourceLocation": <source-location>,] ; Moved to <event>
}

+<error> ::= {
+  ["code": <integer>,]
+  ["domain": <string>,]
+  ["description": <string>,]
+  ["type": <type-info>]
+}

+<miscount> ::= {
+  "actual": <integer>, ; actual confirmation count
+  "expected": <integer> ; when the confirmation specifies a single count
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

```

`type-info` will support types from all languages, not just Swift, so only
applicable fields will be present. For example, C doesn't have fully qualified
names nor, in most implementations, mangled names.

```diff
+<type-info> ::= {
+  ["fullyQualifiedName": <string>,]  ; e.g. "Swift.Bool", "std::string"
+  ["unqualifiedName": <string>,]   ; e.g. "Bool", "string"
+  ["mangledName": <string>,] ; e.g. "$sSb", "_ZNSt3__112basic_string..."
+}
```

### Sample JSON output

<!-- TODO: Impl details: Fill in <comment>, <time>, <integer> elsewhere in the JSON ABI spec -->

#### Issue recorded with user comment

`Issue.record("Issue recorded with user comment")`

```json
{
  "kind": "event",
  "payload": {
    "comments": [
      "Issue recorded with user comment"
    ],
    "instant": { ... },
    "issue": {
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Issue record`()/SampleTests.swift:3:2"
  },
  "version": "6.5.0"
}
```

#### Thrown error

```swift
struct SampleError: Error {}
throw SampleError()
```

```json
{
  "kind": "event",
  "payload": {
    "comments": [],
    "instant": { ... },
    "issue": {
      "error": {
        "code": 1,
        "description": "SampleError()",
        "domain": "SampleTests.(unknown context at $109ada6ac).(unknown context at $109ada6b8).SampleError",
        "type": {
          "fullyQualifiedName": "SampleTests.SampleError",
          "mangledName": "$s11SampleTests10$109ada6acyXZ10$109ada6b8yXZ0A5ErrorV",
          "unqualifiedName": "SampleError"
        }
      },
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Thrown error`()/SampleTests.swift:11:2"
  },
  "version": "6.5.0"
}
```

#### Expectation failure with expression

`#expect(Bool(false), "Expectation fail with user comment")`

```json
{
  "kind": "event",
  "payload": {
    "comments": [
      "Expectation fail with user comment"
    ],
    "instant": { ... },
    "issue": {
      "expression": {
        "children": [
        {
          "sourceCode": "false",
          "type": {
            "fullyQualifiedName": "()",
            "mangledName": "$syt",
            "unqualifiedName": "()"
          },
          "value": "()"
        }
        ],
          "sourceCode": "Bool(false)",
          "type": {
            "fullyQualifiedName": "Swift.Bool",
            "mangledName": "$sSb",
            "unqualifiedName": "Bool"
          },
          "value": "false"
      },
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Expectation failed`()/SampleTests.swift:7:2"
  },
  "version": "6.5.0"
}
```

#### Test timeout: `@Test(.timeLimit(.minutes(1)))`

```json
{
  "kind": "event",
  "payload": {
    "comments": [],
    "instant": { ... },
    "issue": {
      "exceededTimeLimit": 60,
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Time limit exceeded`()/SampleTests.swift:46:2"
  },
  "version": "6.5.0"
}
```

#### Known Issues

##### Known issue that is matched

```swift
withKnownIssue("This matches and doesn't fail") {
    Issue.record("This is the known issue")
}
```

```json
{
  "kind": "event",
  "payload": {
    "comments": [
      "This is the known issue"
    ],
    "instant": { ... },
    "issue": {
      "isFailure": false,
      "isKnown": "This matches and doesn't fail",
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Known issue, matched`()/SampleTests.swift:16:2"
  },
  "version": "6.5.0"
}
```

##### Known issue NOT matched

```swift
withKnownIssue("This doesn't match and thus fails") {
    // Intentionally empty
}
```

```json
{
  "kind": "event",
  "payload": {
    "comments": [
      "This doesn't match and thus fails"
    ],
    "instant": { ... },
    "issue": {
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Known issue, NOT matched`()/SampleTests.swift:22:2"
  },
  "version": "6.5.0"
}
```

#### Confirmation Miscount

##### Single expected count

`await confirmation { _ in }`

```json
{
  "kind": "event",
  "payload": {
    "comments": [],
    "instant": { ... },
    "issue": {
      "confirmationMiscount": {
        "actual": 0,
        "expected": 1
      },
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Confirmation miscount, expected single`()/SampleTests.swift:42:2"
  },
  "version": "6.5.0"
}
```

##### Ranged of expected counts

```swift
await confirmation(expectedCount: 1...5) { confirmation in
    for _ in 0..<10 {
        confirmation()
    }
}
```

```json
{
  "kind": "event",
  "payload": {
    "comments": [],
    "instant": { ... },
    "issue": {
      "confirmationMiscount": {
        "actual": 10,
        "expected": {
          "max": 5,
          "min": 1
        }
      },
      "isFailure": true,
      "severity": "error"
    },
    "sourceLocation": { ... },
    "iteration": 1,
    "kind": "issueRecorded",
    "testID": "SampleTests.`Confirmation miscount, expected range`()/SampleTests.swift:34:2"
  },
  "version": "6.5.0"
}
```

## Source compatibility

There are no source compatibility concerns.

## Integration with supporting tools

Changes from the 6.4 schema:

- `isKnown` will no longer be a required boolean-valued field, and will instead
  be an optional boolean-valued or string-valued field.

- `messages` field becomes optional.

- `sourceLocation` field moves to `<event>` out of the individual event
  structures.

- All other fields are purely additive to the JSON ABI.

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
inspecting the issue fields. For example, presence of an `confirmationMiscount`
field indicates this issue was the "confirmationMiscounted" kind.

## Acknowledgments

Thanks to Jonathan Grynspan and Stuart Montgomery for providing feedback on the
proposal.
