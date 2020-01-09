# Concise magic file names

* Proposal: [SE-NNNN](NNNN-magic-file.md)
* Authors: [Brent Royal-Gordon](https://github.com/brentdax), [Dave DeLong](https://github.com/davedelong)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#25656](https://github.com/apple/swift/pull/25656); merged behind `-enable-experimental-concise-pound-file`

## Introduction

Today, `#file` evaluates to a string literal containing the full path to the current source file. We propose to instead have it evaluate to a human-readable string containing the filename and module name, while preserving the existing behavior in a new `#filePath` expression.

Swift-evolution thread: [Concise Magic File Names](https://forums.swift.org/t/concise-magic-file-names/31297), [We need `#fileName`](https://forums.swift.org/t/we-need-filename/19781)

## Motivation

In Swift today, the magic identifier `#file` evaluates to a string literal containing the full path (that is, the path passed to `swiftc`) to the current file. It's a nice way to trace the location of logic occurring in a Swift process, but its use of a full path has a lot of drawbacks:

* It can inadvertently reveal private or sensitive information. The full path to a source file may contain a developer's username, hints about the configuration of a build farm, proprietary versions or identifiers, or the Sailor Scout you named an external disk after. Developers probably don't know that this information is embedded in their binaries and may not want it to be there. And most uses of `#file` are in default arguments, which makes this information capture invisible at the use site. The information leaks here are quite serious; if other languages hadn't already normalized this, I doubt we would think that `#file` was an acceptable design.

* It bloats binaries produced by the Swift compiler. In testing with the Swift benchmark suite, a shorter `#file` string reduced code size by up to 5%. The large code also impacts runtime performance—in the same tests, a couple dozen benchmarks ran noticeably faster, with several taking 22% less time. While we didn't benchmark app launch times, it's likely that they are also adversely affected by lengthy `#file` strings.

* It introduces artificial differences between binaries built on different machines. For instance, the same code built in two different environments might produce different binaries with different hashes. This makes life difficult for anyone trying to cache build artifacts, find the differences between two binaries, or otherwise hoping to benefit from reproducible builds.

Meanwhile, the benefits you might expect from using a full path aren't really there:

* The paths are not portable between machines, so you can't use it to automatically match an error to a line of source code unless your machine has the same directory layout as the machine that built the binary.

* The paths are not guaranteed to be absolute—XCBuild and SwiftPM happen to use absolute paths, but other build systems like Bazel don't—so you can't be sure that you can resolve paths to a file on disk.
  
* The paths are not even guaranteed to be unique within a process because the same file could be included in several different modules, or different projects could be located at the same paths on different machines or at different times.

For `#file`'s most important use case, it seems like the current string computed by `#file` is suboptimal and a better default would improve Swift in several ways.

### Other uses of `#file`

While `#file` is primarily intended for developer-facing errors, in practice it is also used in other ways. In particular, Swift tests sometimes use `#file` to compute paths to fixtures relative to the source file that uses them. This has historically been necessary in SwiftPM because it did not support resources, but [SE-0271][] has now added a much better solution to this problem than `#file`-based path computation.

  [SE-0271]: https://github.com/apple/swift-evolution/blob/master/proposals/0271-package-manager-resources.md
  
It's worth reiterating that these uses are inherently fragile and unreliable. Not only do they rely on the build system choosing to pass absolute paths, they also rely on a full checkout of the project being present on disk at the same path as when the binary was built. That means these tests will probably fail when run anywhere but on the machine they were built on, including on attached iOS/tvOS/watchOS devices.

Nevertheless, we know that some projects in the wild *do* use `#file` this way; the question is how common these uses are. We attempted to answer this question by analyzing the Swift Source Compatibility Suite in three ways:

1. We used regular expressions to automatically examine the 1,073 uses of `#file` in all 108 projects, trying to categorize them as being either for human display or machine consumption. We concluded that approximately 91–96% of uses are for human display.[1]

2. We manually examined 172 of those uses in sixteen projects. We concluded that approximately 95% of the uses we looked at would benefit from the new `#file` behavior.

3. We ran tests for the 21 projects which had configured test targets and passed in at least one language version mode. Three of these projects—`Html`, `Lark`, and `swift-nio-http2`—showed new failures with a shorter `#file` string. In all three cases, the broken code looked up test fixtures relative to `#file`; the projects themselves appeared to function normally. We concluded that a small number of projects use `#file` in ways that require a full path, but only in their tests.

These three data points together indicate that most code is not sensitive to the exact string generated by `#file` and that adopting SwiftPM resources would probably address the main reason that code might be sensitive to it. However, we should not merely tell projects like these that "your tests are now broken and fixing them will require you to totally redesign how you access fixtures"—we should provide a drop-in solution for projects that are currently using `#file` in these ways.

<details>
<summary>[1] Details of regular expression-based analysis</summary>

We applied several regular expressions to the source code of the projects in the Source Compatibility Suite to try to classify uses of `#file`. We identified four patterns that we believe represent display to humans:

1. `StaticString = #file`: Since `StaticString` is fairly inconvenient to use compared to `String`, we assume these will be passed to one of the few APIs that take them. Most of those—like `precondition(_:_:file:line:)` or `XCTAssertEqual(_:_:_:file:line:)`—are APIs that should show a concise string.

2. `<StaticString typealias> = #file`: A couple of projects use a custom typealias for `StaticString`. We manually confirmed that these projects generally pass those values to something like an `XCTAssert` function which should show a concise string.

3. `String = #file`, but with `#line` on the same line: We take this to indicate that a file and line are being captured for display together.

4. `#file` interpolated into a string: Since `#file` is usually an absolute path that wouldn't need to be concatenated, we take these to be formatting for display.

We also identified two patterns that we conservatively assume represent eventual I/O or other machine-oriented processing (although in many cases they may represent path computation for display):

1. `String = #file`, no `#line` nearby: We assume this will be passed to an API like `URL.init(fileURLWithPath:)` which will then be used to further manipulate the path or perform I/O.

2. `#file` used in a parenthesized list, but not an interpolation: We assume this is being passed to an API like `URL.init(fileURLWithPath:)`.

When we matched these patterns against the source compatibility suite, we got the following results:

| Pattern | Occurrences | Percentage |
| -------- | --------------- | ------------- |
| **Human display patterns** |  |  |
| `StaticString = #file` | 419 | 39.0% |
| `<Project-specific StaticString typealias> = #file` | 281 | 26.1% |
| `#file` and `#line` captured together | 148 | 13.8% |
| `#file` interpolated into string | 132 | 12.3% |
| All human display patterns | 980 | 91.3% |
| **Machine consumption patterns** |  |  |
| `String = #file`, no `#line` | 10 | 0.9% |
| `#file` passed to function | 31 | 2.9% |
| All machine consumption patterns | 41 | 3.8% |
| **None of the above patterns** | 52 | 4.8% |

We therefore estimate that about 6% (±3%) of uses actually want a full path so they can process it, while 94% (±3%) would be better served by a more succinct string designed for human display.

</details>

## Proposed solution

We propose changing the string that `#file` evaluates to. To preserve implementation flexibility, we do not specify the exact format of this string; we merely specify that it must:

1. Be unique to the file and module it refers to. That is, every unique `fileprivate` scope should have a different `#file` value.

2. Be easy for a human to read and map to the matching source file.

`#file` will otherwise behave as it did before, including its special behavior in default arguments. Standard library assertion functions will continue to use `#file`, and we encourage developers to use it in test helpers, logging functions, and most other places where they use `#file` today.

For those rare cases where developers actually need a full path, we propose adding a `#filePath` magic identifier with the same behavior that `#file` had in previous versions of Swift. That is, it contains the path to the file as passed to the Swift compiler.

## Detailed design

We do not specify the exact string produced by `#file` because it is not intended to be machine-parseable and we want to preserve flexibility as the compiler's capabilities change. In the current implementation of this proposal, however, a file at `/Users/brent/Desktop/NNNN-magic-file.swift` in a module named `MagicFile` with this content:

```swift
print(#file)
print(#filePath)
fatalError("Something bad happened!")
```

Would produce this output:

```
NNNN-magic-file.swift (MagicFile)
/Users/brent/Desktop/NNNN-magic-file.swift
Fatal error: Something bad happened!: file NNNN-magic-file.swift (MagicFile), line 3
```

This string is currently sufficient to uniquely identify the file's `fileprivate` scope because the Swift compiler does not allow identically-named files in different directories to be included in the same module.[2]

This implementation is actually already in master and swift-5.2-branch behind a compiler flag; use the `-enable-experimental-concise-pound-file` flag to try it out.

> [2] This limitation ensures that identically-named `private` and `fileprivate` declarations in different files will have unique mangled names. A future version of the Swift compiler could lift this limitation. If this happens, not fully specifying the format of the `#file` string preserves flexibility for that version to adjust its `#file` strings to include additional information, such as selected parent directory names, sufficient to distinguish the two files.

## Source compatibility

All existing source code will continue to compile with this change, and `#file`'s documentation never specified precisely what its contents were; in one of the pitch threads, [Ben Cohen](https://forums.swift.org/t/concise-magic-file-names/31297/19) said that this is sufficient to satisfy Swift's source compatibility requirements. However, the proposal *will* cause behavior to change in existing code, and in some cases it will change in ways that cause existing code to behave incorrectly when run. Code that is adversely affected by this change can access the previous behavior by using `#filePath` instead of `#file`.

## Effect on ABI stability

None. `#file` is a compile-time feature; existing binaries will continue to work as they did before.

## Effect on API resilience

As with any addition to Swift's syntax, older compilers won't be able to use module interface files that have `#filePath` in default arguments or inlinable code. Otherwise, none.

## Alternatives considered

### Deprecate `#file` and introduce two new syntaxes

Rather than changing the meaning of `#file`, we could keep its existing behavior, deprecate it, and provide two alternatives:

* `#filePath` would continue to use the full path.
* `#fileName` would use the new concise string suggested by this proposal.

This is a more conservative approach that would avoid breaking any existing uses. We choose not to propose it for three reasons:

1. The name `#fileName` is misleading because it sounds like the string only contains the file name, but it also contains the module name. `#file` is more vague, so we're more comfortable saying that it's "a string that identifies the file".
  
2. This alternative will force developers to update every use of `#file` to one or the other option. We feel this is burdensome and unnecessary given how much more frequently the `#fileName` behavior would be appropriate.

3. This alternative gives users no guidance on which feature developers ought to use. We feel that giving `#file` a shorter name gives them a soft push towards using it when they can, while resorting to `#filePath` only when necessary.

4. Since all uses of `#file`—not just ones that require a full path—would change, all uses of `#file` in module interfaces—not just ones that require a full path—would become stumbling blocks for backwards compatibility. This includes uses in the swiftinterface files for the standard library and XCTest.

However, if the core team feels that changing `#file`'s behavior will cause unacceptable behavior changes, this ready-made alternative would accomplish most of the goals of this proposal.

### Support more than two `#file` variants

We considered introducing additional `#file`-like features to generate other strings, selecting between them either with a compiler flag or with different magic identifiers. The full set of behaviors we considered included:

1. Path as written in the compiler invocation
2. Guaranteed-absolute path
3. Path relative to the Xcode `SOURCE_DIR` value, or some equivalent
4. Last component of the path (file name only)
5. File name plus module name
6. Empty string (sensible as a compiler flag)

We ultimately decided that supporting only 1 (as `#filePath`) and 5 (as `#file`) would adequately cover the use cases for `#file`. Five different syntaxes would devote a lot of language surface area to a small niche, and controlling the behavior with a compiler flag would create six language dialects that might break some code. Some of these behaviors would also require introducing new concepts into the compiler or would cause trouble for distributed build systems.

### Make `#filePath` always absolute

While we're looking at this area of the language, we could change `#filePath` to always generate an absolute path. This would make `#filePath` more stable and useful, but it would cause problems for distributed builds unless it respected `-debug-prefix-map` or something similar. It would also mean that there'd be no simple way to get the *exact* same behavior as Swift previously provided, which would make it more difficult to adapt code to this change.

Ultimately, we think changing to an absolute path is severable from this proposal and that, if we want to do this, we should consider it separately.

### Other alternatives

We considered making `#file`'s behavior change conditional on enabling a new language version mode. While we're not opposed to that in principle, we don't think the breakage from this change will be severe enough to justify delaying this proposal's implementation until the next release with a language version mode.

We considered introducing a new alternative to `#file` (e.g. `#fileName`) while preserving the existing meaning of `#file`. However, a great deal of code already uses `#file` and would in practice probably never be converted to `#fileName`. The vast majority of this code would benefit from the new behavior, so we think it would be better to automatically adopt it. (Note that clang supports a `__FILE_NAME__` alternative, but most code still uses `__FILE__` anyway.)

We considered switching between the old and new `#file` behavior with a compiler flag. However, this creates a language dialect, and compiler flags are not a natural interface for users.

Finally, we could change the behavior of `#file` without offering an escape hatch. However, we think that the existing behavior is useful in rare circumstances and should not be totally removed.
