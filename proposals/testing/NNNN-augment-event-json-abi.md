# Enhance Swift Testing JSON ABI with Rich Test Metadata

* Proposal: [ST-NNNN](NNNN-augment-event-json-abi.md)
* Authors: [Sam Khouri](https://github.com/bkhouri),
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-testing#1429](https://github.com/swiftlang/swift-testing/pull/1429)
* Review: [pitch](https://forums.swift.org/t/adding-additional-information-to-the-abi-json/83426)

## Introduction

This proposal enhances Swift Testing's event JSON ABI by exposing test
metadata that is currently unavailable to external tools. By including test
tags, bug associations, and time limits in the JSON output, this allows third-party
tools to provide richer insights and more sophisticated test management capabilities.

## Motivation

Swift Testing's event JSON stream provides data for external tooling,
enabling developers to build test analysis and reporting tools.
However, the current implementation lacks access to some test metadata that
developers may want to use to organize and manage their test suites.

Currently missing from the JSON output are:
- **Test tags**: Used for categorization
- **Bug associations**: Critical for tracking which tests verify specific bug fixes
- **Time limits**: Essential for performance monitoring and timeout management

This missing metadata limits the capabilities of external tools. For example:
- IDE extensions cannot provide tag-based test filtering
- CI/CD systems cannot generate reports grouped by test categories
- Performance monitoring tools cannot track tests with specific time constraints
- Bug tracking integrations cannot correlate test failures with known issues

By exposing this information, we unlock new possibilities for Swift Testing
tooling ecosystem.

## Proposed solution

We propose enriching the test payload in the event JSON stream by adding three
metadata fields:

- **`tags`**: An array of string tags associated with the test, enabling categorization
  and filtering
- **`bugs`**: An array of bug references, providing traceability between tests
  and issue tracking
- **`timeLimit`**: The test's time limit in seconds, enabling performance monitoring
  and timeout analysis

These additions leverage existing internal data structures, ensuring minimal performance
impact while maximizing the value delivered to external tools.

## Detailed design

This enhancement builds upon the existing test metadata infrastructure already used
internally by Swift Testing. The implementation reuses established data structures,
ensuring consistency and minimizing complexity.

### Implementation Strategy

The new fields are conditionally included in the JSON output based on test
configuration:
- Fields are only included when the test actually uses the corresponding traits
- Empty or unused traits result in omitted fields, keeping the JSON clean and
  efficient
- This approach maintains backward compatibility while providing rich information
  when available

### JSON Schema Changes

The **Modified Backus-Naur Form (BNF)** delta would be:

```diff
diff --git a/Documentation/ABI/JSON.md b/Documentation/ABI/JSON.md
index e4ff24a..1a82996 100644
--- a/Documentation/ABI/JSON.md
+++ b/Documentation/ABI/JSON.md
@@ -157,10 +157,26 @@ additional `"testCases"` field describing the individual test cases.
   ["displayName": <string>,] ; the user-supplied custom display name
   "sourceLocation": <source-location>, ; where the test is defined
   "id": <test-id>,
-  "isParameterized": <bool> ; is this a parameterized test function or not?
+  "isParameterized": <bool>, ; is this a parameterized test function or not?
+  ["tags": <array:tag>,] ; the tags associated with this test function
+  ["bugs": <array:bug>,] ; the bugs associated with this test function
+  ["timeLimit": <timeLimit>] ; the time limits associated with this test function
+
 }

 <test-id> ::= <string> ; an opaque string representing the test case
+
+<tag> ::= <string>  ; a string representation of a tag
+
+<bug> ::= {
+  ["url": <string>,] ; the bug url
+  ["id": <string>,] ; the bug id
+  "title": <string> ; the human readable bug title
+} ;
+
+<timeLimit> ::= <number> ; the test time limit (in seconds)
```

## Source compatibility

This proposal maintains full backward compatibility through careful design:

- **ABI Version Protection**: New fields are conditionally included based on ABI
  version checks, ensuring older tools continue to function without modification
- **Experimental Feature Migration**: The existing experimental `_tag` field is
  replaced with the `tags` array. Since experimental features don't provide
  stability guarantees, this replacement doesn't constitute a breaking change
- **Graceful Degradation**: Tools that don't expect the new fields will simply ignore
them, while updated tools can leverage the enhanced metadata

No existing functionality is affected, making this a purely additive enhancement.

## Integration with supporting tools

The enhanced JSON ABI opens up exciting possibilities for the Swift Testing ecosystem:

### Immediate Benefits for Tool Developers
- **IDE Extensions**: Can now provide tag-based test filtering and organization
- **CI/CD Integrations**: Can generate more detailed reports with test categorization
- **Performance Monitoring**: Can track and alert on time limit violations
- **Bug Tracking Integration**: Can correlate test results with known issues

### Migration Path
Existing tools will continue to work unchanged, as the new fields are purely additive.
Tool developers can incrementally adopt the enhanced metadata at their own pace,
choosing which fields provide the most value for their specific use cases.

### Enhanced Capabilities
With access to this metadata, tools can now offer features like:
- Filtering test runs by tags for faster feedback cycles
- Generating reports that group results by test categories
- Tracking performance regressions against defined time limits
- Automatically linking test failures to relevant bug reports

## Future directions

This enhancement establishes future richer tooling experiences:

### Potential Extensions
- **Additional Metadata**: Other test traits could be exposed as the ecosystem evolves
- **Enhanced Bug Integration**: More sophisticated bug tracking integration with status updates
- **Performance Analytics**: Historical time limit data for performance trend analysis

### Ecosystem Growth
By providing this metadata, we anticipate growth in the Swift Testing tooling
ecosystem, with new tools emerging to take advantage of the richer data available.
This proposal positions Swift Testing as a platform that truly enables innovative
testing tools and workflows.

## Alternatives considered

### Alternative Field Naming
- **`timeLimitInSeconds` vs `timeLimit`**: We chose the shorter `timeLimit` name for
  consistency with Swift Testing's existing API, with the time unit documented in the
  schema specification.  The naming convention was discussed with the Testing Workgroup
  and it was decided that a seperata proposal should be made to on how to represent
  the time units in the name/value.

### Alternative Data Structures
- **Flattened vs Structured Bug Information**: We chose a structured approach for bug
  metadata to accommodate various bug tracking systems while maintaining extensibility

### Implementation Approaches
- **Always Include vs Conditional Fields**: We selected conditional inclusion to
  keep JSON output clean and avoid null values, improving the developer experience
  for tools consuming the data

## Acknowledgments

Thanks to [Jonathan Grynspan](https://github.com/grynspan) for suggesting to me
I write this proposal and for providing feedback.

Thanks to [Paul LeMarqaund](https://github.com/plemarquand) for providing proposal
feedback before it was posted.
