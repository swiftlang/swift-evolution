# A stable JSON-based ABI for tools integration

* Proposal: [ST-0002](0002-json-abi.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Status: **Implemented (Swift 6.0)**
* Implementation: [swiftlang/swift-testing#383](https://github.com/swiftlang/swift-testing/pull/383),
  [swiftlang/swift-testing#402](https://github.com/swiftlang/swift-testing/pull/402)
* Review: ([pitch](https://forums.swift.org/t/pitch-a-stable-json-based-abi-for-tools-integration/72627)), ([acceptance](https://forums.swift.org/t/pitch-a-stable-json-based-abi-for-tools-integration/72627/4))

> [!NOTE]
> This proposal was accepted before Swift Testing began using the Swift
> evolution review process. Its original identifier was
> [SWT-0002](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Proposals/0002-json-abi.md).

## Introduction

One of the core components of Swift Testing is its ability to interoperate with
Xcode 16, VS Code, and other tools. Swift Testing has been fully open-sourced
across all platforms supported by Swift, and can be added as a package
dependency (or—eventually—linked from the Swift toolchain.)

## Motivation

Because Swift Testing may be used in various forms, and because integration with
various tools is critical to its success, we need it to have a stable interface
that can be used regardless of how it's been added to a package. There are a few
patterns in particular we know we need to support:

- An IDE (e.g. Xcode 16) that builds and links its own copy of Swift Testing:
  the copy used by the IDE might be the same as the copy that tests use, in
  which case interoperation is trivial, but it may also be distinct if the tests
  use Swift Testing as a package dependency.

  In the case of Xcode 16, Swift Testing is built as a framework much like
  XCTest and is automatically linked by test targets in an Xcode project or
  Swift package, but if the test target specifies a package dependency on Swift
  Testing, that dependency will take priority when the test code is compiled.

- An IDE (e.g. VS Code) that does _not_ link directly to Swift Testing (and
  perhaps, as with VS Code, cannot because it is not natively compiled): such an
  IDE needs a way to configure and invoke test code and then to read events back
  as they occur, but cannot touch the Swift symbols used by the tests.

  In the case of VS Code, because it is implemented using TypeScript, it is not
  able to directly link to Swift Testing or other Swift libraries. In order for
  it to interpret events from a test run like "test started" or "issue
  recorded", it needs to receive those events in a format it can understand.

Tools integration is important to the success of Swift Testing. The more tools
provide integrations for it, the more likely developers are to adopt it. The
more developers adopt, the more tests are written. And the more tests are
written, the better our lives as software engineers will be.

## Proposed solution

We propose defining and implementing a stable ABI for using Swift Testing that
can be reliably adopted by various IDEs and other tools. There are two aspects
of this ABI we need to implement:

- A stable entry point function that can be resolved dynamically at runtime (on
  platforms with dynamic loaders such as Darwin, Linux, and Windows.) This
  function needs a signature that will not change over time and which will take
  input and pass back asynchronous output in a format that a wide variety of
  tools will be able to interpret (whether they are written in Swift or not.)

  This function should be implemented in Swift as it is expected to be used by
  code that can call into Swift, but which cannot rely on the specific binary
  minutiae of a given copy of Swift Testing.

- A stable format for input that can be passed to the entry point function and
  which can also be passed at the command line; and a stable format for output
  that can be consumed by tools to interpret test results.

  Some tools cannot directly link to Swift code and must instead rely on
  command-line invocations of `swift test`. These tools will be able to pass
  their test configuration and options as an argument in the stable format and
  will be able to receive event information in the same stable format via a
  dedicated channel such as a file or named pipe.

> [!NOTE]
> This document proposes defining a stable format for input and output, but only
> actually defines the JSON schema for _output_. We intend to define the schema
> for input in a subsequent proposal.
>
> In the interim, early adopters can encode an instance of Swift Testing's
> `__CommandLineArguments_v0` type using `JSONEncoder`.

## Detailed design

We propose defining the stable input and output format using JSON as it is
widely supported across platforms and languages. The proposed JSON schema for
output is defined [here](https://github.com/swiftlang/swift-testing/blob/main/Documentation/ABI/JSON.md).

### Example output

The proposed schema is a sequence of JSON objects written to an event handler or
file stream. When a test run starts, Swift Testing first emits a sequence of
JSON objects representing each test that is part of the planned run. For
example, this is the JSON representation of Swift Testing's own `canGetStdout()`
test function:

```json
{
  "kind": "test",
  "payload": {
    "displayName": "Can get stdout",
    "id": "TestingTests.FileHandleTests/canGetStdout()/FileHandleTests.swift:33:4",
    "isParameterized": false,
    "kind": "function",
    "name": "canGetStdout()",
    "sourceLocation": {
      "column": 4,
      "fileID": "TestingTests/FileHandleTests.swift",
      "line": 33
    }
  },
  "version": 0
}
```

A tool that is observing this data stream can build a map or dictionary of test
IDs to comprehensive test details if needed. Once all tests in the planned run
have been written out, testing begins. Swift Testing writes a sequence of JSON
objects representing various events such as "test started" or "issue recorded".
For example, here is an abridged sequence of events generated for a test that
records a failed expectation:

```json
{
  "kind": "event",
  "payload": {
    "instant": {
      "absolute": 266418.545786299,
      "since1970": 1718302639.76747
    },
    "kind": "testStarted",
    "messages": [
      {
        "symbol": "default",
        "text": "Test \"Can get stdout\" started."
      }
    ],
    "testID": "TestingTests.FileHandleTests/canGetStdout()/FileHandleTests.swift:33:4"
  },
  "version": 0
}

{
  "kind": "event",
  "payload": {
    "instant": {
      "absolute": 266636.524236724,
      "since1970": 1718302857.74857
    },
    "issue": {
      "isKnown": false,
      "sourceLocation": {
        "column": 7,
        "fileID": "TestingTests/FileHandleTests.swift",
        "line": 29
      }
    },
    "kind": "issueRecorded",
    "messages": [
      {
        "symbol": "fail",
        "text": "Expectation failed: (EOF → -1) == (feof(fileHandle) → 0)"
      }
    ],
    "testID": "TestingTests.FileHandleTests/canGetStdout()/FileHandleTests.swift:33:4"
  },
  "version": 0
}

{
  "kind": "event",
  "payload": {
    "instant": {
      "absolute": 266636.524741106,
      "since1970": 1718302857.74908
    },
    "kind": "testEnded",
    "messages": [
      {
        "symbol": "fail",
        "text": "Test \"Can get stdout\" failed after 0.001 seconds with 1 issue."
      }
    ],
    "testID": "TestingTests.FileHandleTests/canGetStdout()/FileHandleTests.swift:33:4"
  },
  "version": 0
}
```

Each event includes zero or more "messages" that Swift Testing intends to
present to the user. These messages contain human-readable text as well as
abstractly-specified symbols that correspond to the output written to the
standard error stream of the test process. Tools can opt to present these
messages in whatever ways are appropriate for their interfaces.

### Invoking from the command line

When invoking `swift test`, we propose adding three new arguments to Swift
Package Manager:

| Argument | Value Type | Description |
|---|:-:|---|
| `--configuration-path` | File system path | Specifies a path to a file, named pipe, etc. containing test configuration/options. |
| `--event-stream-output-path` | File system path | Specifies a path to a file, named pipe, etc. to which output should be written. |
| `--event-stream-version` | Integer | Specifies the version of the stable JSON schema to use for output. |

The process for adding arguments to Swift Package Manager is separate from the
process for Swift Testing API changes, so the names of these arguments are
speculative and are subject to change as part of the Swift Package Manager
review process.

If `--configuration-path` is specified, Swift Testing will open it for reading
and attempt to decode its contents as JSON. If `--event-stream-output-path` is
specified, Swift Testing will open it for writing and will write a sequence of
[JSON Lines](https://jsonlines.org) to it representing the data and events
produced by the test run. `--event-stream-version` determines the stable schema
used for output; pass `0` to match the schema proposed in this document.

> [!NOTE]
> If `--event-stream-output-path` is specified but `--event-stream-version` is
> not, the format _currently_ used is based on direct JSON encodings of the
> internal Swift structures used by Swift Testing. This format is necessary to
> support Xcode 16 Beta 1. In the future, the default value of this argument
> will be assumed to equal the newest available JSON schema version (`0` as of
> this document's acceptance, i.e. the JSON schema will match what we are
> proposing here until a new schema supersedes it.)
>
> Tools authors that rely on the JSON schema are strongly advised to specify a
> version rather than relying on this behavior to avoid breaking changes in the
> future.

On platforms that support them, callers can use a named pipe with
`--event-stream-output-path` to get live results back from the test run rather
than needing to wait until the file is closed by the test process. Named pipes
can be created on Darwin or Linux with the POSIX [`mkfifo()`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mkfifo.2.html)
function or on Windows with the [`CreateNamedPipe()`](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createnamedpipew)
function.

If `--configuration-path` is specified in addition to explicit command-line
options like `--no-parallel`, the explicit command-line options take priority.

### Invoking from Swift

Tools that can link to and call Swift directly have the option of instantiating
the tools-only SPI type `Runner`, however this is only possible if the tools and
the test target link to the exact same copy of Swift Testing. To support tools
that may link to a different copy (intentionally or otherwise), we propose
adding an exported symbol to the Swift Testing library with the following Swift
signature:

```swift
@_spi(ForToolsIntegrationOnly)
public enum ABIv0 {
  /* ... */

  /// The type of the entry point to the testing library used by tools that want
  /// to remain version-agnostic regarding the testing library.
  ///
  /// - Parameters:
  ///   - configurationJSON: A buffer to memory representing the test
  ///     configuration and options. If `nil`, a new instance is synthesized
  ///     from the command-line arguments to the current process.
  ///   - recordHandler: A JSON record handler to which is passed a buffer to
  ///     memory representing each record as described in `ABI/JSON.md`.
  ///
  /// - Returns: Whether or not the test run finished successfully.
  ///
  /// - Throws: Any error that occurred prior to running tests. Errors that are
  ///   thrown while tests are running are handled by the testing library.
  public typealias EntryPoint = @convention(thin) @Sendable (
    _ configurationJSON: UnsafeRawBufferPointer?,
    _ recordHandler: @escaping @Sendable (_ recordJSON: UnsafeRawBufferPointer) -> Void
  ) async throws -> Bool

  /// The entry point to the testing library used by tools that want to remain
  /// version-agnostic regarding the testing library.
  ///
  /// The value of this property is a Swift function that can be used by tools
  /// that do not link directly to the testing library and wish to invoke tests
  /// in a binary that has been loaded into the current process. The value of
  /// this property is accessible from C and C++ as a function with name
  /// `"swt_abiv0_getEntryPoint"` and can be dynamically looked up at runtime
  /// using `dlsym()` or a platform equivalent.
  ///
  /// The value of this property can be thought of as equivalent to
  /// `swift test --event-stream-output-path` except that, instead of streaming
  /// JSON records to a named pipe or file, it streams them to an in-process
  /// callback.
  public static var entryPoint: EntryPoint { get }
}
```

The inputs and outputs to this function are typed as `UnsafeRawBufferPointer`
rather than `Data` because the latter is part of Foundation, and adding a public
dependency on a Foundation type would make it very difficult for Foundation to
adopt Swift Testing. It is a goal of the Swift Testing team to keep our Swift
dependency list as small as possible.

### Invoking from C or C++

We expect most tools that need to make use of this entry point will not be able
to directly link to the exported Swift symbol and will instead need to look it
up at runtime using a platform-specific interface such as [`dlsym()`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/dlsym.3.html)
or [`GetProcAddress()`](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getprocaddress).
The `ABIv0.entryPoint` property's getter will be exported to C and C++ as:

```c++
extern "C" const void *_Nonnull swt_abiv0_getEntryPoint(void);
```

The value returned from this C function is a direct representation of the value
of `ABIv0.entryPoint` and can be cast back to its Swift function type using
[`unsafeBitCast(_:to:)`](https://developer.apple.com/documentation/swift/unsafebitcast%28_%3Ato%3A%29).

On platforms where data-pointer-to-function-pointer conversion is disallowed per
the C standard, this operation is unsupported. See §6.3.2.3 and §J.5.7 of
[the C standard](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1256.pdf).

> [!NOTE]
> Swift Testing is statically linked into the main executable when it is
> included as a package dependency. On Linux and other platforms that use the
> ELF executable format, symbol information for the main executable may not be
> available at runtime unless the `--export-dynamic` flag is passed to the
> linker.

## Source compatibility

The changes proposed in this document are additive.

## Integration with supporting tools

Tools are able to use the proposed additions as described above.

## Future directions

- Extending the JSON schema to cover _input_ as well as _output_. As discussed,
  we will do so in a subsequent proposal.

- Extending the JSON schema to include richer information about events such as
  specific mismatched values in `#expect()` calls. This information is complex
  and we need to take care to model it efficiently and clearly.

- Adding Markdown or other formats to event messages. Rich text can be used by
  tools to emphasize values, switch to code voice, provide improved
  accessibility, etc.

- Adding additional entry points for different access patterns. We anticipate
  that a Swift function and a command-line interface are sufficient to cover
  most real-world use cases, but it may be the case that tools could use other
  mechanisms for starting test runs such as:
  - Pure C or Objective-C interfaces;
  - A WebAssembly and/or JavaScript [`async`-compatible](https://github.com/WebAssembly/component-model/blob/2f447274b5028f54c549cb4e28ceb493a471dd4b/design/mvp/Async.md)
    interface;
  - Platform-specific interfaces; or
  - Direct bindings to other languages like Rust, Go, C#, etc.

## Alternatives considered

- Doing nothing. If we made no changes, we would be effectively requiring
  developers to use Xcode for all Swift Testing development and would be
  requiring third-party tools to parse human-readable command-line output. This
  approach would run counter to several of the Swift project's high-level goals
  and would not represent a true cross-platform solution.

- Using direct JSON encodings of Swift Testing's internal types to represent
  output. We initially attempted this and you can see the results in the Swift
  Testing repository if you look for "snapshot" types. A major downside became
  apparent quickly: these data types don't make for particularly usable JSON
  unless you're using `JSONDecoder` to convert back to them, and the default
  JSON encodings produced with `JSONEncoder` are not stable if we e.g. add
  enumeration cases with associated values or add non-optional fields to types.

- Using a format other than JSON. We considered using XML, YAML, Apple property
  lists, and a few other formats. JSON won out pretty quickly though: it is
  widely supported across platforms and languages and it is trivial to create
  Swift structures that encode to a well-designed JSON schema using
  `JSONEncoder`. Property lists would be just as easy to create, but it is a
  proprietary format and would not be trivially decodable on non-Apple platforms
  or using non-Apple tools.

- Exposing the C interface as a function that returns heap-allocated memory
  containing a Swift function reference. This allows us to emit a "thick" Swift
  function but requires callers to manually manage the resulting memory, and it
  may be difficult to reason about code that requires an extra level of pointer
  indirection. By having the C entry point function return a thin Swift function
  instead, the caller need only bitcast it and can call it directly, and the
  equivalent Swift interface can simply be a property getter rather than a
  function call.

- Exposing the C interface as a function that takes a callback and a completion
  handler as might traditionally used by Objective-C callers, of the form:

  ```c++
  extern "C" void swt_abiv0_entryPoint(
    __attribute__((__noescape__)) const void *_Nullable configurationJSON,
    size_t configurationJSONLength,
    void *_Null_unspecified context,
    void (*_Nonnull recordHandler)(
      __attribute__((__noescape__)) const void *recordJSON,
      size_t recordJSONLength,
      void *_Null_unspecified context
    ),
    void (*_Nonnull completionHandler)(
      _Bool success,
      void *_Null_unspecified context
    )
  );
  ```

  The known clients of the native entry point function are all able to call
  Swift code and do not need this sort of interface. If there are other clients
  that would need the entry point to use a signature like this one, it would be
  straightforward to implement it in a future amendment to this proposal.

## Acknowledgments

Thanks much to [Dennis Weissmann](https://github.com/dennisweissmann) for his
tireless work in this area and to [Paul LeMarquand](https://github.com/plemarquand)
for putting up with my incessant revisions and nitpicking while he worked on
VS Code's Swift Testing support.

Thanks to the rest of the Swift Testing team for reviewing this proposal and the
JSON schema and to the community for embracing Swift Testing!
