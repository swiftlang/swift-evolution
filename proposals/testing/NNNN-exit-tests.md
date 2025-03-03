# Exit tests

* Proposal: [SWT-NNNN](NNNN-exit-tests.md)
* Authors: [Jonathan Grynspan](https://github.com/grynspan)
* Status: **Awaiting review**
* Bug: [apple/swift-testing#157](https://github.com/apple/swift-testing/issues/157)
* Implementation: [apple/swift-testing#307](https://github.com/apple/swift-testing/pull/307)
* Review: ([pitch](https://forums.swift.org/t/pitch-exit-tests/78071))

## Introduction

One of the first enhancement requests we received for Swift Testing was the
ability to test for precondition failures and other critical failures that
terminate the current process when they occur. This feature is also frequently
requested for XCTest. With Swift Testing, we have the opportunity to build such
a feature in an ergonomic way.

> [!NOTE]
> This feature has various names in the relevant literature, e.g. "exit tests",
> "death tests", "death assertions", "termination tests", etc. We consistently
> use the term "exit tests" to refer to them.

## Motivation

Imagine a function, implemented in a package, that includes a precondition:

```swift
func eat(_ taco: consuming Taco) {
  precondition(taco.isDelicious, "Tasty tacos only!")
  ...
}
```

Today, a test author can write unit tests for this function, but there is no way
to make sure that the function rejects a taco whose `isDelicious` property is
`false` because a test that passes such a taco as input will crash (correctly!)
when it calls `precondition()`.

An exit test allows testing this sort of functionality. The mechanism by which
an exit test is implemented varies between testing libraries and languages, but
a common implementation involves spawning a new process, performing the work
there, and checking that the spawned process ultimately terminates with a
particular (possibly platform-specific) exit status.

Adding exit tests to Swift Testing would allow an entirely new class of tests
and would improve code coverage for existing test targets that adopt them.

## Proposed solution

This proposal introduces new overloads of the `#expect()` and `#require()`
macros that take, as an argument, a closure to be executed in a child process.
When called, these macros spawn a new process using the relevant
platform-specific interface (`posix_spawn()`, `CreateProcessW()`, etc.), call
the closure from within that process, and suspend the caller until that process
terminates. The exit status of the process is then compared against a known
value passed to the macro, allowing the test to pass or fail as appropriate.

The function from earlier can then be tested using either of the new
overloads:

```swift
await #expect(exitsWith: .failure) {
  var taco = Taco()
  taco.isDelicious = false
  eat(taco) // should trigger a precondition failure and process termination
}
```

## Detailed design

### New expectations

We will introduce the following new overloads of `#expect()` and `#require()` to
the testing library:

```swift
/// Check that an expression causes the process to terminate in a given fashion.
///
/// - Parameters:
///   - expectedExitCondition: The expected exit condition.
///   - observedValues: An array of key paths representing results from within
///     the exit test that should be observed and returned by this macro. The
///     ``ExitTest/Result/statusAtExit`` property is always returned.
///   - comment: A comment describing the expectation.
///   - sourceLocation: The source location to which recorded expectations and
///     issues should be attributed.
///   - expression: The expression to be evaluated.
///
/// - Returns: If the exit test passed, an instance of ``ExitTest/Result``
///   describing the state of the exit test when it exited. If the exit test
///   fails, the result is `nil`.
///
/// Use this overload of `#expect()` when an expression will cause the current
/// process to terminate and the nature of that termination will determine if
/// the test passes or fails. For example, to test that calling `fatalError()`
/// causes a process to terminate:
///
/// await #expect(exitsWith: .failure) {
///   fatalError()
/// }
///
/// - Note: A call to this expectation macro is called an "exit test."
///
/// ## How exit tests are run
///
/// When an exit test is performed at runtime, the testing library starts a new
/// process with the same executable as the current process. The current task is
/// then suspended (as with `await`) and waits for the child process to
/// terminate. `expression` is not called in the parent process.
///
/// Meanwhile, in the child process, `expression` is called directly. To ensure
/// a clean environment for execution, it is not called within the context of
/// the original test. If `expression` does not terminate the child process, the
/// process is terminated automatically as if the main function of the child
/// process were allowed to return naturally. If an error is thrown from
/// `expression`, it is handed as if the error were thrown from `main()` and the
/// process is terminated.
///
/// Once the child process terminates, the parent process resumes and compares
/// its exit status against `expectedExitCondition`. If they match, the exit
/// test has passed; otherwise, it has failed and an issue is recorded.
///
/// ## Child process output
///
/// By default, the child process is configured without a standard output or
/// standard error stream. If your test needs to review the content of either of
/// these streams, you can pass its key path in the `observedValues` argument:
///
/// let result = await #expect(
///   exitsWith: .failure,
///   observing: [\.standardOutputContent]
/// ) {
///   print("Goodbye, world!")
///   fatalError()
/// }
/// if let result {
///   #expect(result.standardOutputContent.contains(UInt8(ascii: "G")))
/// }
///
/// - Note: The content of the standard output and standard error streams may
///   contain any arbitrary sequence of bytes, including sequences that are not
///   valid UTF-8 and cannot be decoded by [`String.init(cString:)`](https://developer.apple.com/documentation/swift/string/init(cstring:)-6kr8s).
///   These streams are globally accessible within the child process, and any
///   code running in an exit test may write to it including the operating
///   system and any third-party dependencies you have declared in your package.
///
/// The actual exit condition of the child process is always reported by the
/// testing library even if you do not specify it in `observedValues`.
///
/// ## Runtime constraints
///
/// Exit tests cannot capture any state originating in the parent process or
/// from the enclosing lexical context. For example, the following exit test
/// will fail to compile because it captures an argument to the enclosing
/// parameterized test:
///
/// @Test(arguments: 100 ..< 200)
/// func sellIceCreamCones(count: Int) async {
///   await #expect(exitsWith: .failure) {
///     precondition(
///       count < 10, // ERROR: A C function pointer cannot be formed from a
///                   // closure that captures context
///       "Too many ice cream cones"
///     )
///   }
/// }
///
/// An exit test cannot run within another exit test.
#if SWT_NO_EXIT_TESTS
@available(*, unavailable, message: "Exit tests are not available on this platform.")
#endif
@discardableResult
@freestanding(expression) public macro expect(
  exitsWith expectedExitCondition: ExitTest.Condition,
  observing observedValues: [any PartialKeyPath<ExitTest.Result> & Sendable] = [],
  _ comment: @autoclosure () -> Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing expression: @convention(thin) () async throws -> Void
) -> ExitTest.Result? = #externalMacro(module: "TestingMacros", type: "ExitTestExpectMacro")

/// Check that an expression causes the process to terminate in a given fashion
/// and throw an error if it did not.
///
/// [...]
#if SWT_NO_EXIT_TESTS
@available(*, unavailable, message: "Exit tests are not available on this platform.")
#endif
@discardableResult
@freestanding(expression) public macro require(
  exitsWith expectedExitCondition: ExitTest.Condition,
  observing observedValues: [any PartialKeyPath<ExitTest.Result> & Sendable] = [],
  _ comment: @autoclosure () -> Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation,
  performing expression: @convention(thin) () async throws -> Void
) -> ExitTest.Result = #externalMacro(module: "TestingMacros", type: "ExitTestRequireMacro")
```

> [!NOTE]
> These interfaces are currently implemented and available on **macOS**,
> **Linux**, **FreeBSD**, **OpenBSD**, and **Windows**. If a platform does not
> support exit tests (generally because it does not support spawning or awaiting
> child processes), then we define `SWT_NO_EXIT_TESTS` when we build it.
>
> `SWT_NO_EXIT_TESTS` is not defined during test target builds.

### Representing an exit test in Swift

A new type, `ExitTest`, represents an exit test:

```swift
/// A type describing an exit test.
///
/// Instances of this type describe exit tests you create using the
/// ``expect(exitsWith:observing:_:sourceLocation:performing:)`` or
/// ``require(exitsWith:observing:_:sourceLocation:performing:)`` macro. You
/// don't usually need to interact directly with an instance of this type.
#if SWT_NO_EXIT_TESTS
@available(*, unavailable, message: "Exit tests are not available on this platform.")
#endif
public struct ExitTest: Sendable, ~Copyable {
  /// The exit test that is running in the current process, if any.
  ///
  /// If the current process was created to run an exit test, the value of this
  /// property describes that exit test. If this process is the parent process
  /// of an exit test, or if no exit test is currently running, the value of
  /// this property is `nil`.
  ///
  /// The value of this property is constant across all tasks in the current
  /// process.
  public static var current: ExitTest? { get }
}
```

### Exit conditions

These macros take an argument of the new type `ExitTest.Condition`. This type
describes how the child process is expected to have exited:

- With a specific exit code (as passed to the C standard function `exit()` or a
  platform-specific equivalent);
- With a specific signal (on platforms that support signal handling[^winsig]);
- With any successful status; or
- With any failure status.

[^winsig]: Windows nominally supports signal handling as it is part of the C
  standard, but not to the degree that signals are supported by POSIX-like or
  UNIX-derived operating systems. Swift Testing makes a "best effort" to emulate
  signal-handling support on Windows. See [this](https://forums.swift.org/t/swift-on-windows-question-about-signals-and-exceptions/76640/2)
  Swift forum message for more information. 

The type is declared as:

```swift
#if SWT_NO_EXIT_TESTS
@available(*, unavailable, message: "Exit tests are not available on this platform.")
#endif
extension ExitTest {
  /// The possible conditions under which an exit test will complete.
  ///
  /// Values of this type are used to describe the conditions under which an
  /// exit test is expected to pass or fail by passing them to
  /// ``expect(exitsWith:observing:_:sourceLocation:performing:)`` or
  /// ``require(exitsWith:observing:_:sourceLocation:performing:)``.
  ///
  /// ## Topics
  ///
  /// ### Successful exit conditions
  ///
  /// - ``success``
  ///
  /// ### Failing exit conditions
  ///
  /// - ``failure``
  /// - ``exitCode(_:)``
  /// - ``signal(_:)``
  public struct Condition: Sendable {
    /// A condition that matches when a process terminates successfully with exit
    /// code `EXIT_SUCCESS`.
    ///
    /// The C programming language defines two [standard exit codes](https://en.cppreference.com/w/c/program/EXIT_status),
    /// `EXIT_SUCCESS` and `EXIT_FAILURE` as well as `0` (as a synonym for
    /// `EXIT_SUCCESS`.)
    public static var success: Self { get }

    /// A condition that matches when a process terminates abnormally with any
    /// exit code other than `EXIT_SUCCESS` or with any signal.
    public static var failure: Self { get }

    public init(_ statusAtExit: StatusAtExit)
    
    /// Creates a condition that matches when a process terminates with a given
    /// exit code.
    ///
    /// - Parameters:
    ///   - exitCode: The exit code yielded by the process.
    ///
    /// The C programming language defines two [standard exit codes](https://en.cppreference.com/w/c/program/EXIT_status),
    /// `EXIT_SUCCESS` and `EXIT_FAILURE`. Platforms may additionally define their
    /// own non-standard exit codes:
    ///
    /// | Platform | Header |
    /// |-|-|
    /// | macOS | [`<stdlib.h>`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/_Exit.3.html), [`<sysexits.h>`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysexits.3.html) |
    /// | Linux | [`<stdlib.h>`](https://sourceware.org/glibc/manual/latest/html_node/Exit-Status.html), `<sysexits.h>` |
    /// | FreeBSD | [`<stdlib.h>`](https://man.freebsd.org/cgi/man.cgi?exit(3)), [`<sysexits.h>`](https://man.freebsd.org/cgi/man.cgi?sysexits(3)) |
    /// | OpenBSD | [`<stdlib.h>`](https://man.openbsd.org/exit.3), [`<sysexits.h>`](https://man.openbsd.org/sysexits.3) |
    /// | Windows | [`<stdlib.h>`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/exit-success-exit-failure) |
    ///
    /// On macOS, FreeBSD, OpenBSD, and Windows, the full exit code reported by
    /// the process is yielded to the parent process. Linux and other POSIX-like
    /// systems may only reliably report the low unsigned 8 bits (0&ndash;255) of
    /// the exit code.
    public static func exitCode(_ exitCode: CInt) -> Self
    
    /// Creates a condition that matches when a process terminates with a given
    /// signal.
    ///
    /// - Parameters:
    ///   - signal: The signal that terminated the process.
    ///
    /// The C programming language defines a number of [standard signals](https://en.cppreference.com/w/c/program/SIG_types).
    /// Platforms may additionally define their own non-standard signal codes:
    ///
    /// | Platform | Header |
    /// |-|-|
    /// | macOS | [`<signal.h>`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/signal.3.html) |
    /// | Linux | [`<signal.h>`](https://sourceware.org/glibc/manual/latest/html_node/Standard-Signals.html) |
    /// | FreeBSD | [`<signal.h>`](https://man.freebsd.org/cgi/man.cgi?signal(3)) |
    /// | OpenBSD | [`<signal.h>`](https://man.openbsd.org/signal.3) |
    /// | Windows | [`<signal.h>`](https://learn.microsoft.com/en-us/cpp/c-runtime-library/signal-constants) |
    public static func signal(_ signal: CInt) -> Self
  }
}
```

### Exit status

The set of possible status codes reported by the child process are represented
by the `StatusAtExit` enumeration:

```swift
/// An enumeration describing possible status a process will yield on exit.
///
/// You can convert an instance of this type to an instance of
/// ``ExitTest/Condition`` using ``ExitTest/Condition/init(_:)``. That value
/// can then be used to describe the condition under which an exit test is
/// expected to pass or fail by passing it to
/// ``expect(exitsWith:observing:_:sourceLocation:performing:)`` or
/// ``require(exitsWith:observing:_:sourceLocation:performing:)``.
#if SWT_NO_PROCESS_SPAWNING
@available(*, unavailable, message: "Exit tests are not available on this platform.")
#endif
public enum StatusAtExit: Sendable {
  /// The process terminated with the given exit code.
  ///
  /// [...]
  case exitCode(_ exitCode: CInt)

  /// The process terminated with the given signal.
  ///
  /// [...]
  case signal(_ signal: CInt)
}
```

### Exit test results

These macros return an instance of the new type `ExitTest.Result`. This type
describes the results of the process including its reported exit condition and
the contents of its standard output and standard error streams, if requested.

```swift
#if SWT_NO_EXIT_TESTS
@available(*, unavailable, message: "Exit tests are not available on this platform.")
#endif
extension ExitTest {
  /// A type representing the result of an exit test after it has exited and
  /// returned control to the calling test function.
  ///
  /// Both ``expect(exitsWith:observing:_:sourceLocation:performing:)`` and
  /// ``require(exitsWith:observing:_:sourceLocation:performing:)`` return
  /// instances of this type.
  public struct Result: Sendable {
    /// The status of the process hosting the exit test at the time it exits.
    ///
    /// When the exit test passes, the value of this property is equal to the
    /// exit status reported by the process that hosted the exit test.
    public var statusAtExit: StatusAtExit { get set }

    /// All bytes written to the standard output stream of the exit test before
    /// it exited.
    ///
    /// The value of this property may contain any arbitrary sequence of bytes,
    /// including sequences that are not valid UTF-8 and cannot be decoded by
    /// [`String.init(cString:)`](https://developer.apple.com/documentation/swift/string/init(cstring:)-6kr8s).
    /// Consider using [`String.init(validatingCString:)`](https://developer.apple.com/documentation/swift/string/init(validatingcstring:)-992vo)
    /// instead.
    ///
    /// When checking the value of this property, keep in mind that the standard
    /// output stream is globally accessible, and any code running in an exit
    /// test may write to it including including the operating system and any
    /// third-party dependencies you have declared in your package. Rather than
    /// comparing the value of this property with [`==`](https://developer.apple.com/documentation/swift/array/==(_:_:)),
    /// use [`contains(_:)`](https://developer.apple.com/documentation/swift/collection/contains(_:))
    /// to check if expected output is present.
    ///
    /// To enable gathering output from the standard output stream during an
    /// exit test, pass `\.standardOutputContent` in the `observedValues`
    /// argument of ``expect(exitsWith:observing:_:sourceLocation:performing:)``
    /// or ``require(exitsWith:observing:_:sourceLocation:performing:)``.
    ///
    /// If you did not request standard output content when running an exit test,
    /// the value of this property is the empty array.
    public var standardOutputContent: [UInt8] { get set }

    /// All bytes written to the standard error stream of the exit test before
    /// it exited.
    ///
    /// [...]
    public var standardErrorContent: [UInt8] { get set }
  }
}
```

### Usage

These macros can be used within a test function:

```swift
@Test func `We only eat delicious tacos`() async {
  await #expect(exitsWith: .failure) {
    var taco = Taco()
    taco.isDelicious = false
    eat(taco)
  }
}
```

Given the definition of `eat(_:)` above, this test can be expected to hit a
precondition failure and crash the process; because `.failure` was the specified
exit condition, this is treated as a successful test.

It is often interesting to examine what is written to the standard output and
standard error streams by code running in an exit test. Callers can request that
either or both stream be captured and included in the result of the call to
`#expect(exitsWith:)` or `#require(exitsWith:)`. Capturing these streams can be
a memory-intensive operation, so the caller must explicitly opt in:

```swift
@Test func `We only eat delicious tacos`() async throws {
  let result = try await #require(exitsWith: .failure, observing: [\.standardErrorContent])) { ... }
  #expect(result.standardOutputContent.contains("ERROR: This taco tastes terrible!".utf8)
}
```

There are some constraints on valid exit tests:

1. Because exit tests are run in child processes, they cannot capture any state
   from the calling context (hence their body closures are `@convention(thin)`
   or `@convention(c)`.) See the **Future directions** for further discussion.
1. Exit tests cannot recursively invoke other exit tests; this is a constraint
   that could potentially be lifted in the future, but it would be technically
   complex to do so.

If a Swift Testing issue such as an expectation failure occurs while running an
exit test, it is reported to the parent process and to the user as if it
happened locally. If an error is thrown from an exit test and not caught, it
behaves the same way a Swift program would if an error were thrown from its
`main()` function (that is, the program terminates abnormally.)

## Source compatibility

This is a new interface that is unlikely to collide with any existing
client-provided interfaces. The typical Swift disambiguation tools can be used
if needed.

## Integration with supporting tools

SPI is provided to allow testing environments other than Swift Package Manager
to detect and run exit tests:

```swift
@_spi(ForToolsIntegrationOnly)
extension ExitTest {
  /// A type whose instances uniquely identify instances of ``ExitTest``.
  public struct ID: Sendable, Equatable, Codable { /* ... */ }

  /// A value that uniquely identifies this instance.
  public var id: ID { get set }

  /// Key paths representing results from within this exit test that should be
  /// observed and returned to the caller.
  ///
  /// The testing library sets this property to match what was passed by the
  /// developer to the `#expect(exitsWith:)` or `#require(exitsWith:)` macro.
  /// If you are implementing an exit test handler, you can check the value of
  /// this property to determine what information you need to preserve from your
  /// child process.
  ///
  /// The value of this property always includes ``ExitTest/Result/statusAtExit``
  /// even if the test author does not specify it.
  ///
  /// Within a child process running an exit test, the value of this property is
  /// otherwise unspecified.
  public var observedValues: [any PartialKeyPath<ExitTest.Result> & Sendable] { get set }

  /// Call the exit test in the current process.
  ///
  /// This function invokes the closure originally passed to
  /// `#expect(exitsWith:)` _in the current process_. That closure is expected
  /// to terminate the process; if it does not, the testing library will
  /// terminate the process as if its `main()` function returned naturally.
  public consuming func callAsFunction() async -> Never

  /// Find the exit test function at the given source location.
  ///
  /// - Parameters:
  ///   - id: The unique identifier of the exit test to find.
  ///
  /// - Returns: The specified exit test function, or `nil` if no such exit test
  ///   could be found.
  public static func find(identifiedBy id: ExitTest.ID) -> Self?

  /// A handler that is invoked when an exit test starts.
  ///
  /// - Parameters:
  ///   - exitTest: The exit test that is starting.
  ///
  /// - Returns: The result of the exit test including the condition under which
  ///   it exited.
  ///
  /// - Throws: Any error that prevents the normal invocation or execution of
  ///   the exit test.
  ///
  /// This handler is invoked when an exit test (i.e. a call to either
  /// ``expect(exitsWith:observing:_:sourceLocation:performing:)`` or
  /// ``require(exitsWith:observing:_:sourceLocation:performing:)``) is started.
  /// The handler is responsible for initializing a new child environment
  /// (typically a child process) and running the exit test identified by
  /// `sourceLocation` there.
  ///
  /// In the child environment, you can find the exit test again by calling
  /// ``ExitTest/find(at:)`` and can run it by calling
  /// ``ExitTest/callAsFunction()``.
  ///
  /// The parent environment should suspend until the results of the exit test
  /// are available or the child environment is otherwise terminated. The parent
  /// environment is then responsible for interpreting those results and
  /// recording any issues that occur.
  public typealias Handler = @Sendable (_ exitTest: borrowing ExitTest) async throws -> ExitTest.Result
}

@_spi(ForToolsIntegrationOnly)
extension Configuration {
  /// A handler that is invoked when an exit test starts.
  ///
  /// For an explanation of how this property is used, see ``ExitTest/Handler``.
  ///
  /// When using the `swift test` command from Swift Package Manager, this
  /// property is pre-configured. Otherwise, the default value of this property
  /// records an issue indicating that it has not been configured.
  public var exitTestHandler: ExitTest.Handler { get set }
}
```

Any tools that use `swift build --build-tests`, `swift test`, or equivalent to
compile executables for testing will inherit the functionality provided for
`swift test` and do not need to implement their own exit test handlers. Tools
that directly compile test targets or otherwise do not leverage Swift Package
Manager will need to provide an implementation.

## Future directions

### Support for iOS, WASI, etc.

The need for exit tests on other platforms is just as strong as it is on the
supported platforms (macOS, Linux, FreeBSD/OpenBSD, and Windows). These
platforms do not support spawning new processes, so a different mechanism for
running exit tests would be needed.

Android _does_ have `posix_spawn()` and related API and may be able to use the
same implementation as Linux. Android support is an ongoing area of research for
Swift Testing's core team.

### Recursive exit tests

The technical constraints preventing recursive exit test invocation can be
resolved if there is a need to do so. However, we don't anticipate that this
constraint will be a serious issue for developers.

### Support for passing state

Arbitrary state is necessarily not preserved between the parent and child
processes, but there is little to prevent us from adding a variadic `arguments:`
argument and passing values whose types conform to `Codable`.

The blocker right now is that there is no type information during macro
expansion, meaning that the testing library can emit the glue code to _encode_
arguments, but does not know what types to use when _decoding_ those arguments.
If generic types were made available during macro expansion via the macro
expansion context, then it would be possible to synthesize the correct logic.

Alternatively, if the language gained something akin to C++'s `decltype()`, we
could leverage closures' capture list syntax. Subjectively, capture lists ought
to be somewhat intuitive for developers in this context:

```swift
let (lettuce, cheese, crema) = taco.addToppings()
await #expect(exitsWith: .failure) { [taco, plant = lettuce, cheese, crema] in
  try taco.removeToppings(plant, cheese, crema)
}
```

### More nuanced support for throwing errors from exit test bodies

Currently, if an error is thrown from an exit test without being caught, the
test behaves the same way a program does when an error is thrown from an
explicit or implicit `main() throws` function: the process terminates abnormally
and control returns to the test function that is awaiting the exit test:

```swift
await #expect(exitsWith: .failure) {
  throw TacoError.noTacosFound 
}
```

If the test function is expecting `.failure`, this means the test passes.
Although this behavior is consistent with modelling an exit test as an
independent program (i.e. the exit test acts like its own `main()` function), it
may be surprising to test authors who aren't thinking about error handling. In
the future, we may want to offer a compile-time diagnostic if an error is thrown
from an exit test body without being caught, or offer a distinct exit condition
(i.e. `.errorNotCaught(_ error: Error & Codable)`) for these uncaught errors.
For error types that conform to `Codable`, we could offer rethrowing behavior,
but this is not possible for error types that cannot be sent across process
boundaries.

### Exit-testing customized processes

The current model of exit tests is that they run in approximately the same
environment as the test process by spawning a copy of the executable under test.
There is a very real use case for allowing testing other processes and
inspecting their output. In the future, we could provide API to spawn a process
with particular arguments and environment variables, then inspect its exit
condition and standard output/error streams:

```swift
let result = try await #require(
  executableAt: "/usr/bin/swift",
  passing: ["build", "--package-path", ...],
  environment: [:],
  exitsWith: .success
)
#expect(result.standardOutputContent.contains("Build went well!").utf8)
```

We could also investigate explicitly integrating with [`Foundation.Process`](https://developer.apple.com/documentation/foundation/process)
or the proposed [`Foundation.Subprocess`](https://github.com/swiftlang/swift-foundation/blob/main/Proposals/0007-swift-subprocess.md)
as an alternative:

```swift
let process = Process()
process.executableURL = URL(filePath: "/usr/bin/swift", directoryHint: .notDirectory)
process.arguments = ["build", "--package-path", ...]
let result = try await #require(process, exitsWith: .success)
#expect(result.standardOutputContent.contains("Build went well!").utf8)
```

## Alternatives considered

- Doing nothing.

- Marking exit tests using a trait rather than a new `#expect()` overload:

  ```swift
  @Test(.exits(with: .failure))
  func `We only eat delicious tacos`() {
    var taco = Taco()
    taco.isDelicious = false
    eat(taco)
  }
  ```

  This syntax would require separate test functions for each exit test, while
  reusing the same function for relatively concise tests may be preferable.

  It would also potentially conflict with parameterized tests, as it is not
  possible to pass arbitrary parameters to the child process. It would be
  necessary to teach the testing library's macro target about the
  `.exits(with:)` trait so that it could produce a diagnostic when used with a
  parameterized test function.

- Inferring exit tests from test functions that return `Never`:

  ```swift
  @Test func `No seafood for me, thanks!`() -> Never {
    var taco = Taco()
    taco.toppings.append(.shrimp)
    eat(taco)
    fatalError("Should not have eaten that!")
  }
  ```

  There's a certain synergy in inferring that a test function that returns
  `Never` must necessarily be a crasher and should be handled out of process.
  However, this forces the test author to add a call to `fatalError()` or
  similar in the event that the code under test does _not_ terminate, and there
  is no obvious way to express that a specific exit code, signal, or other
  condition is expected (as opposed to just "it exited".)

  We might want to support that sort of inference in the future (i.e. "don't run
  this test in-process because it will terminate the test run"), but without
  also inferring success or failure from the process' exit status.

- Naming the macro something else such as:

  - `#exits(with:_:)`;
  - `#exits(because:_:)`;
  - `#expect(exitsBecause:_:)`;
  - `#expect(terminatesBecause:_:)`; etc.

  While "with" is normally avoided in symbol names in Swift, it sometimes really
  is the best preposition for the job. "Because", "due to", and others don't
  sound "right" when the entire expression is read out loud. For example, you
  probably wouldn't say "exits due to success" in English.

- Combining `StatusAtExit` and `ExitTest.Condition` into a single type:

  ```swift
  enum ExitCondition {
  case failure // any failure
  case exitCode(CInt)
  case signal(CInt)
  }
  ```
  
  This simplified the set of types used for exit tests, but made comparing two
  exit conditions complicated and necessitated a `==` operator that did not
  satisfy the requirements of the `Equatable` protocol.

- Naming `StatusAtExit` something else such as:

  - `ExitStatus`, which could be too easily confusable with exit _codes_ such as
    `EXIT_SUCCESS`;
  - `ProcessStatus`, but we don't say "process" in our API surface elsewhere;
  - `Status`, which is too generic,
  - `ExitReason`, but "status" is a more widely-used term of art for this
    concept; or
  - `terminationStatus` (which Foundation to represent approximately the same
    concept), but we don't use "termination" in Swift Testing's API anywhere.

  I settled on `StatusAtExit` because it was distinct and makes it clear that it
  represents the status of a process _at exit time_. `ExitStatus` could be
  interpreted as the status of the exit itself, i.e.:
  
  ```swift
  enum ExitStatus {
    case running
    case suspended
    case exiting
    case exited
  }
  ```

- Changing the implementation of `precondition()`, `fatalError()`, etc. in the
  standard library so that they do not terminate the current process while
  testing, thus removing the need to spawn a child process for an exit test.

  Most of the functions in this family return `Never`, and changing their return
  types would be ABI-breaking (as well as a pessimization in production code.)
  Even if we did modify these functions in the Swift standard library, other
  ways to terminate the process exist and would not be covered:

  - Calling the C standard function `exit()`;
  - Throwing an uncaught Objective-C or C++ exception;
  - Sending a signal to the process; or
  - Misusing memory (e.g. trying to dereference a null pointer.)

  Modifying the C or C++ standard library, or modifying the Objective-C runtime,
  would be well beyond the scope of this proposal.

## Acknowledgments

Many thanks to the XCTest and Swift Testing team. Thanks to @compnerd for his
help with the Windows implementation. Thanks to my colleagues Coops,
Danny&nbsp;N., David&nbsp;R., Drew&nbsp;Y., and Robert&nbsp;K. at Apple for
their help with the nuances of crash reporting on macOS.
