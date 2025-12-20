# "swift play" and the \#Playground macro

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Chris Miles](https://github.com/chrismiles)
* Review Manager: TBD
* Status: **Working prototype implemented for macOS, Linux, Windows**
* Implementation: [swift play prototype in SwiftPM](https://github.com/chrismiles/swift-package-manager/tree/eng/chrismiles/swift-play-prototype) + [#Playground library/macro](https://github.com/apple/swift-play-experimental)
* Review: [Pitch](https://forums.swift.org/t/playground-macro-and-swift-play-idea-for-code-exploration-in-swift/79435)


## Introduction

Swift Play introduces a new capability to Swift Package Manager that enables interactive code exploration and experimentation within Swift packages. This feature provides a lightweight alternative to tools like Xcode Playgrounds. It allows developers to create executable code snippets directly within their package structure using a `#Playground` macro, and use a new command `swift play` to run playground code. Mac, Linux and Windows are supported initially, with the goal to support as many Swift platforms as is practical.

Swift-evolution thread: [#Playground macro and “swift play” idea for code exploration in Swift](https://forums.swift.org/t/playground-macro-and-swift-play-idea-for-code-exploration-in-swift/79435)

## Motivation

Currently, Swift developers have several options for interactively exploring their code, but each one has downsides:

* **Xcode Playgrounds** - Requires Xcode on a Mac
* **Swift Playground** - Requires Swift Playground on iPad or Mac
* **REPL** - Limited for complex multi-line explorations and doesn't persist work
* **Separate test targets** - Heavyweight and not aimed at exploration
* **Temporary executable targets** - Inconvenient and not designed for rapid iteration

These limitations create friction when developers want to:

* Quickly experiment with APIs during package development
* Create interactive documentation and examples
* Prototype ideas without setting up full applications
* Share executable code snippets with the community

Swift Play addresses these needs by providing a seamless, integrated solution for live code exploration within the Swift package ecosystem.

## Proposed solution

Swift Play introduces two components:
- A new `Playgrounds` library
- A new `play` sub-command for Swift Package manager

The two components work together to provide the following functionality.
### \#Playground Macro

A new macro to declare directly-executable blocks of code:
```swift
import Playgrounds

#Playground("Fibonacci") {
  for n in 0..<10 {
    print("fibonacci(\(n)) = \(fibonacci(n))")
  }
}
```
The macro is provided by the `Playgrounds` library.

### `swift play` Command

A new SwiftPM subcommand to discover and execute playground code:
```bash
# List available playgrounds in package
$ swift play --list
Building for debugging...
Found 1 Playground:
* Fibonacci/Fibonacci.swift:23 "Fibonacci"

# Run a specific playground by name
$ swift play Fibonacci
Building for debugging...
---- Running Playground "Fibonacci" - Hit ^C to quit ----
fibonacci(0) = 0
fibonacci(1) = 1
fibonacci(2) = 1
fibonacci(3) = 2
fibonacci(4) = 3
fibonacci(5) = 5
fibonacci(6) = 8
fibonacci(7) = 13
fibonacci(8) = 21
fibonacci(9) = 34
^C
```

`swift play` provides multiple conveniences for live code exploration:
* **Live updating on code changes**: In the (default) live mode, swift play will monitor the package for file changes and automatically re-build & re-run the playground, providing a simple but effective live coding workflow.
* **Stdin support for interactive playground code**: Playground code can prompt the user for input by reading from stdin.
* **Swift Play continues running** after the playground block has executed, so that any asynchronous code or callbacks can continue to execute and produce output.
* **Flexible playground identification**: A playground can be identified by name (if it was defined with one) or by `filename:line:column` format, where `line` and `column` are optional unless needed to resolve ambiguity.  For example, if `foo.swift` contained only a single (un-named) playground, it could be run using `swift play foo.swift`.

## Detailed design

### Play command

The proposal adds a new `play` subcommand to Swift Package Manager.

```
$ swift play --help
OVERVIEW: Build and run a playground

SEE ALSO: swift build, swift package, swift run, swift test

USAGE: swift play [<options>] [<playground-name>]

ARGUMENTS:
  <playground-name>       The playground name to run

OPTIONS:
  --live-update           Execute playground and automatically re-execute on any source file changes (default: --live-update)
  --one-shot              Execute playground and exit immediately
  --list                  List all Playgrounds
  --version               Show the version.
  -h, -help, --help       Show help information.
```

When a user invokes `swift play` in a package, SwiftPM builds a temporary
"playground" executable, linking the package's library targets and the
Playgrounds library.  SwiftPM then runs the "playground" executable, passing
any necessary arguments to either list all available playgrounds, or to run a
specified playground.

### Macro

Developers can declare playground code blocks in their packages using the
`#Playground` macro, defined by the Playgrounds module. 
```swift
/// Declares a runnable playground block that can be discovered and
/// executed by tools like "swift play".
///
/// The `#Playground` macro creates a discoverable code block that
/// can be run independently from the main program execution.
/// Playgrounds are useful for exploration, experimentation,
/// and demonstration code that can be executed on-demand.
///
/// - Parameters:
///   - name: An optional string that provides a display name
///           for the playground. If `nil`, the playground will
///           be unnamed but still discoverable.
///   - body: A closure containing the code to execute when
///           the playground is run.
@freestanding(declaration)
public macro Playground(
  _ name: String? = nil,
  body: @escaping @Sendable () async throws -> Void
)
```

`#Playground` is a declaration macro that takes 2 arguments:
- `name` - an optional name for the playground
- `body` - a closure (or function reference) providing the body to be executed

To use `#Playground` declarations in code, developers simply need to add
the `Playgrounds` product from 
[swift-play-experimental](https://github.com/apple/swift-play-experimental) 
(to be called "swift-play" after being accepted) as a package dependency.
```swift:
dependencies: [
	.package(url: "https://github.com/apple/swift-play-experimental", branch: "main"),
],

.target(
	name: "MyTarget",
	dependencies: [
		.product(name: "Playgrounds", package: "swift-play-experimental"),
	]
),
```

Then they can `import Playgrounds` to use the `#Playground` macro.

## Swift Build compatibility 

The Swift Play implementation hasn't adopted Swift Build at the time of writing the proposal. However, the goal of the author is to update the implementation to be Swift Build compatible before the proposal is accepted, assuming no blocking issues are encountered.

## Security

No additional security concerns are expected over existing ways to run package code using commands like `swift run` or `swift test`.

In terms of privacy, developers should consider that any code or static data in `#Playground` bodies could end up in builds distributed externally, unless explicitly conditioned out or dead-code stripped.

## Impact on existing packages

There are no expected compatibility issues with existing packages.

## Alternatives considered

`#Playground` code is only relevant to `swift play` builds, so I considered wrapping the macro expansion in a condition like `#if PLAYGROUND_MACRO_EXPANSION_ENABLED`, so the playground code would not be compiled in to non-play builds. The condition would be documented so that developers could condition out any other playground-specific code.  It turns out that this strategy won't work as expected. Swift type checks macros _before_ expansion, meaning that any references within the playground to code that is conditioned out would fail to type check. Instead we'll rely on dead-code stripping.

## Future directions

To remove the need to add `swift-play` as a package dependency, a future direction could be to include the Playgrounds library in the Swift toolchain.  This could be a separate follow-on proposal for the core team to consider.

Expression results: Swift already supports a feature – built originally for Playground environments – that adds instrumentation to capture expression results during execution (as seen in Xcode Playgrounds, for example).  A future enhancement to `swift play` could be to add support for expression results capture and display, providing a richer live coding experience.

IDEs and tools could integrate `swift play` (or the Playgrounds library directly) to offer their own integrated code exploration experiences. Experimental efforts are already underway to add the [support needed](https://github.com/swiftlang/sourcekit-lsp/pull/2340) for integrating `swift play` into tools like VSCode.
