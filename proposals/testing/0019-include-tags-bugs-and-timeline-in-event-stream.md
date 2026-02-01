# Include metadata for tags, bugs, and time limit traits in event stream

* Proposal: [ST-0019](0019-include-tags-bugs-and-timeline-in-event-stream)
* Authors: [Sam Khouri](https://github.com/bkhouri)
* Review Manager: [Paul LeMarquand](https://github.com/plemarquand)
* Status: **In Review**
* Implementation: [swiftlang/swift-testing#1429](https://github.com/swiftlang/swift-testing/pull/1429)
* Review: [pitch](https://forums.swift.org/t/adding-additional-information-to-the-abi-json/83426)

## Introduction

This proposal enhances Swift Testing's JSON event ABI by exposing test
metadata that is currently unavailable to external tools. By including test
tags, bug associations, and time limits in the JSON output, this allows third-party
tools to provide richer insights and more sophisticated test management capabilities.

## Motivation

Swift Testing's JSON event stream provides data for external tooling,
enabling developers to build test analysis and reporting tools.
However, the current implementation lacks access to some test metadata that
developers may want to use to organize and manage their test suites.

Currently missing from the JSON output are:
- **Test tags**: Used for categorization
- **Bug associations**: Tracks bugs associated with tests
- **Time limits**: Useful for performance monitoring and timeout management

This missing metadata limits the capabilities of external tools. For example:
- IDE extensions cannot provide tag-based test filtering
- CI/CD systems cannot generate reports grouped by test categories
- Performance monitoring tools cannot track tests with specific time constraints
- Bug tracking integrations cannot correlate test failures with known issues

## Proposed solution

We propose adding new fields to Swift Testing's JSON event stream schema that represent
the described traits.

## Detailed design

We propose adding `"tags"`, `"bugs"`, and `"timeLimit"` fields to the existing
`<test-suite>` and `<test-function>` structures in Swift Testing's JSON event
stream schema starting with version `"6.4"`. This enhancement builds upon the
existing test metadata infrastructure already used internally by Swift Testing. The
implementation reuses established data structures, ensuring consistency and
minimizing complexity.


### JSON Schema Changes

The **Modified Backus-Naur Form (BNF)** delta would be:

```diff
diff --git a/Documentation/ABI/JSON.md b/Documentation/ABI/JSON.md
index e4ff24a4..edcd4481 100644
--- a/Documentation/ABI/JSON.md
+++ b/Documentation/ABI/JSON.md
@@ -157,10 +157,21 @@ additional `"testCases"` field describing the individual test cases.
   ["displayName": <string>,] ; the user-supplied custom display name
   "sourceLocation": <source-location>, ; where the test is defined
   "id": <test-id>,
-  "isParameterized": <bool> ; is this a parameterized test function or not?
+  "isParameterized": <bool>, ; is this a parameterized test function or not?
+  ["tags": <array:tag>,] ; the tags associated with this test function
+  ["bugs": <array:bug>,] ; the bugs associated with this test function
+  ["timeLimit": <number>] ; the time limit associated with this test function
 }

 <test-id> ::= <string> ; an opaque string representing the test case
+
+<tag> ::= <string> ; a string representation of a tag
+
+<bug> ::= {
+  ["url": <string>,] ; the bug URL
+  ["id": <string>,] ; the bug id
+  ["title": <string>] ; the human readable bug title
+}
```

### Sample JSON Output

Given the following test case:

```swift
extension Tag {
  @Tag public static var blue: Self

  /// A tag representing the color red.
  @Tag public static var red: Self

  public enum Foo {
    @Tag public static var bar: Self
  }
}

@Test(
  .tags(.blue),
  .tags(Tag.red),
  .bug("https://my.defect.com/1234"),
  .bug(id: "12345", "other defect"),
  .timeLimit(.minutes(testTimeLimit + 1)),
  .timeLimit(.minutes(testTimeLimit)),
  .timeLimit(.minutes(testTimeLimit + 10)),
  arguments: expectedArgs as [String]
)
func example {}
```

The proposed JSON containing the new fields would look like

```json
{
    "kind": "test",
    <...SNIP...>
    "payload": {
        <...SNIP...>,
        "bugs": [
            {
                "url": "https://my.defect.com/1234"
            },
            {
                "id": "12345",
                "title": "other defect"
            }
        ],
        "tags": [
            "blue",
            "red"
        ],
        "timeLimit": 3
    },
}
```

### Tag representation

Here is a representation of the test tag application, and the string as it would be
represented in the JSON event.

| Trait                        | String      |
| ---------------------------- | ----------- |
| `.tags(.blue)`               | `"blue"`    |
| `.tags(Tag.blue)`            | `"blue"`    |
| `.tags(Testing.Tag.blue)`    | `"blue"`    |
| `.tags(.Foo.bar)`            | `"Foo.bar"` |
| `.tags(Tag.Foo.bar)`         | `"Foo.bar"` |
| `.tags(Testing.Tag.Foo.bar)` | `"Foo.bar"` |

## Source compatibility

This proposal is additive only. Tools using earlier version of the JSON event
stream schema are not affected.

## Integration with supporting tools

Supporting tools like IDEs and CI systems consume the JSON event stream and will
be able to use this new information to provide richer developer experiences. For
example, an IDE could allow developers to sort the content of a test report by tag,
or could highlight failing tests with associated bugs that are incorrectly marked
fixed.

## Future directions

- **`timeLimitInSeconds` vs `timeLimit`**: We chose the shorter `timeLimit` name for
  consistency with Swift Testing's existing API, with the time unit documented in the
  schema specification.  The naming convention was discussed with the Testing Workgroup
  and it was decided that a separate proposal should be made on how to represent
  the time units in the name/value.
- **Additional Metadata**: Other test traits could be exposed as the ecosystem evolves

## Alternatives considered

- **Flattened vs Structured Bug Information**: We chose a structured approach for bug
  metadata to accommodate various bug tracking systems while maintaining extensibility
- **Unconditionally include optional field**: We selected conditional inclusion
  to keep JSON output clean and avoid null values, improving the developer experience
  for tools consuming the data.

## Acknowledgments

Thanks to [Jonathan Grynspan](https://github.com/grynspan) for suggesting to me
I write this proposal and for providing feedback.

Thanks to [Paul LeMarquand](https://github.com/plemarquand) for providing proposal
feedback before it was posted.
