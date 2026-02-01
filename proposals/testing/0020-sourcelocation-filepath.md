# Add a `filePath` property to `SourceLocation`

* Proposal: [ST-0020](0020-sourcelocation-filepath.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Review Manager: [Rachel Brindle](https://github.com/younata)
* Status: **Active Review (01-26...02-09, 2026)**
* Bug: rdar://152999195
* Implementation: [swiftlang/swift-testing#1334](https://github.com/swiftlang/swift-testing/pull/1334), [swiftlang/swift-testing#1472](https://github.com/swiftlang/swift-testing/pull/1472)
* Review: ([pitch](https://forums.swift.org/t/pitch-add-a-filepath-property-to-sourcelocation-in-swift-testing/83995)) ([review](https://forums.swift.org/t/st-0020-add-a-filepath-property-to-sourcelocation/84380))

## Introduction

Swift Testing represents the in-source location of tests, issues, errors, etc.
using a structure called [`SourceLocation`](https://developer.apple.com/documentation/testing/sourcelocation).
This structure contains the line, column, and file ID for a given location in a
Swift source file. I propose adding the file _path_ to this structure for use by
developers and tools.

## Motivation

When we initially designed Swift Testing and `SourceLocation`, our expectation
was that tools like Visual Studio Code or Xcode would be able to translate Swift
file IDs to file paths where needed.

At the time, Swift 6 had not yet been introduced and we were working off the
assumption that `#filePath` would eventually be deprecated (possibly in Swift 6).
This assumption was based on the history behind `#fileID`:

- [SE-0274](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0274-magic-file.md)
  originally proposed repurposing `#file` to generate file IDs (and added
  `#filePath` for use cases that still needed full paths.)
- [SE-0285](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0285-ease-pound-file-transition.md)
  modified the plan to leave `#file` as-is in Swift 5 and introduced `#fileID`
  and planned to have `#file` equal `#fileID` in Swift 6 onward.
- In September 2024, the Language Steering Group [discussed](https://forums.swift.org/t/file-vs-fileid-in-swift-6/74614/4)
  `#file`, `#filePath`, and `#fileID`, and decided to maintain the status quo.

Because the future of these magic values (now expression macros) was unclear, we
opted to provide only a `fileID` property on `SourceLocation`. `SourceLocation`
_does_ gather a full file path, but does not expose a public property to access
this value at runtime or later.

It has become clear since we shipped Swift Testing that tools are much better
equipped to handle file paths than Swift file IDs, and the translation from a
file ID back to the original path on a developer's system may be non-trivial or
even impossible (in the case of strict sandboxing around a tool).

## Proposed solution

I propose adding a `filePath` property to `SourceLocation` and to the JSON event
stream schema.

## Detailed design

The following property is added:

```swift
extension SourceLocation {
  /// The path to the source file.
  public var filePath: String { get set }
}
```

Swift Testing's JSON schema (version `"6.3"` onward) is updated to add a
`"filePath"` key to source location values and to make the `"fileID"` key
optional:

```diff
 <source-location> ::= {
-  "fileID": <string>, ; the Swift file ID of the file
+  ["fileID": <string>,] ; the Swift file ID of the file if available, as per
+                        ; SE-0274 § "Specification of the #file string format"
+  "filePath": <string>, ; the compile-time path to the file
   "line": <number>,
   "column": <number>,
 }
```

The value of the `"filePath"` key is an absolute file system path. It is _not_
guaranteed to refer to an existing file (for instance, it may refer to a file on
a build system that isn't present at runtime). The path style used (POSIX,
Windows, or otherwise) is implementation-defined.

If the `"fileID"` key is not present when Swift Testing decodes an instance of
`SourceLocation`, it is synthesized from `"filePath"` and the module name is
assumed to be `"__C"`[^cModuleName]. This change allows Swift Testing to support source
location information generated in other languages like Objective-C or C++. For
example, a test written in Objective-C could construct a `<source-location>`
JSON value as follows:

```objc
id jsonObject = @{
  @"line": @(__LINE__),
  @"column": @(__builtin_COLUMN()),
  @"filePath": @(__file__)
};
```

And, assuming `__file__` equals `"/foo/bar/quux.m"`, Swift Testing would infer a
file ID of `"__C/quux.m"`.

[^cModuleName]: The Swift compiler and runtime assume a module name of `__C` for
  most imported foreign types.

## Source compatibility

There are no source compatibility concerns.

## Integration with supporting tools

Supporting tools will be able to migrate from the unsupported `"_filePath"` JSON
key to the new `"filePath"` key. We will continue to emit `"_filePath"` where
needed until the ecosystem has moved to `"filePath"`.

## Future directions

N/A

## Alternatives considered

- None.
