# Compiler Diagnostic Directives

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author: [Harlan Haskins](https://github.com/harlanhaskins)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

This proposal introduces `#warning` and `#error` directives that will cause
the Swift compiler to emit a custom warning or an error during compilation.

## Motivation

During the development lifecycle, it's common to leave bits of code unfinished
while focusing on other parts. Frequently, developers leave `TODO` or `FIXME`
comments around unfinished or suboptimal portions of their code to signal
to themselves and their teammates that the code needs work. Many editors pick
up on these comments and present them in code navigators, but these don't
materialize in command-line builds or continuous integration. Allowing #warning
gives a predictable, universal way to ensure a message will be displayed during
compilation.  

Additionally, it's possible for two build configurations to be mutually
exclusive, and there isn't a canonical way to ensure those configurations
don't happen. `#error` solves this problem:

```swift
#if MYLIB_VERSION < 3 && os(macOS)
#error "MyLib versions < 3 are not supported on macOS"
#endif
```

`#warning` can be used for code templates where the user is meant to fill in
the values of global constants or implement missing routines:

```swift
enum APICredentials {
  #warning "fill in your API key below"
  static let key = ""
  #warning "fill in your API secret below"
  static let secret = ""
}
```

## Proposed solution

Add `#warning` and `#error` as compiler directives that emit an appropriate
diagnostic with the contents, pointing to the start of the message.

```swift
func configPath() -> String {
  #warning "this should be made more safe"
  return Bundle.main().path(forResource: "Config", ofType: "plist")!
}
```

## Detailed design

This will add four new productions to the Swift grammar:

```
compiler-control-statement → warning-directive
compiler-control-statement → error-directive
warning-directive → #warning static-string-literal
error-directive → #error static-string-literal
```

Upon parsing a `#error` directive, the Swift compiler will emit the provided
string literal as an error, pointing to the beginning of the
string, and ignore the directive.

Upon parsing a `#warning` directive, the Swift compiler will emit the provided
string literal as a warning, pointing to the beginning of the
string, and ignore the directive.

If a `#warning` or `#error` exists inside a branch of a `#if` directive that is
not taken, then no diagnostic is emitted.

```swift
#if false
#warning "this will not trigger a warning"
#error "this will not trigger an error"
#endif

#if true
#warning "this will trigger a warning"
#error "this will trigger an error"
#endif
```

## Impact on existing code

This change is purely additive; no migration will be required.

## Alternatives considered

- We could do some kind of comment-parsing based approach to surface
  `TODO`s and `FIXME`s, but `#warning` serves as a general-purpose facility
  for reporting at compile time. It is also likely that there are `TODO` and
  `FIXME` comments that are not urgent, but that should be revisited. 

- [Alexander Momchilov](https://forums.swift.org/t/pitch-warning/2819/41) brought
  up the idea of using `TODO` and `warning` as functions in the standard
  library with special compiler magic that will warn on their uses.

  ```swift
  func TODO(_ message: StaticString? = nil) {
    if let s = message { print("TODO: \(s)") }
  }

  @discardableResult
  func TODO<T>(_ message: StaticString? = nil, _ temporaryValue: T) -> T {
    if let s = message { print("TODO: \(s)") }
    return temporaryValue
  }
  ```
  While these could be useful, I think `#warning` and `#error` have uses beyond
  just marking unfinished code that would be unwieldy or impossible with
  just an expression-oriented approach.

- [Erik Little](https://forums.swift.org/t/pitch-warning/2819/42?) refined that
  to instead use special directives `#warning` and `#error` in expression
  position, like:

  ```swift
  let somethingSuspect = #warning("This is really the wrong function to call, but I'm being lazy", suspectFunction())
  ```
  However, I think there's not much of a benefit to this syntax vs. just
  adding a `#warning` above the line:
  ```swift
  #warning "This is really the wrong function to call, but I'm being lazy"
  let somethingSuspect = suspectFunction()
  ```

- [A few](https://forums.swift.org/t/pitch-warning/2819/39)
  [people](https://forums.swift.org/t/pitch-warning/2819/37) have requested
  `#message` or `#info`, as an analogue for Clang's `#pragma message`. This may
  be something we want, but I didn't include it in this proposal because as of
  this writing, Clang treats `#pragma message` as a warning and flags it
  as `-W#pragma-message`.

## Future directions

Both `#message` and an expression-based `#warning` are additive with respect
to this proposal, and both could be addressed in future proposals.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
