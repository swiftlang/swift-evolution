# `#warning`

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author: [Harlan Haskins](https://github.com/harlanhaskins)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

It's really common for developers to add `TODO`/`FIXME` comments in their
source code, but there currently isn't a supported facility to make these
visible. People have [implemented special workarounds](https://bendodson.com/weblog/2014/10/02/showing-todo-as-warning-in-swift-xcode-project/)
to coax Xcode into emitting `TODO`s and `FIXME`s as warnings, but there isn't
an accessible way to provide arbitrary warnings, and does not work in a non-Xcode
environment.

## Motivation

A `#warning` is for something you intend to fix before submitting your code or for writing future tasks that you or your teammates intend to complete later. Because this is such a common programming pattern, Swift should have a similar facility.

## Proposed solution

Add `#warning` as a new compiler directive that emits a warning
diagnostic with the contents, pointing to the start of the message.

```swift
func configPath() -> String {
  #warning "TODO: load this more safely" // expected-warning {{TODO: load this more safely}}
  return Bundle.main().path(forResource: "Config", ofType: "plist")!
}
```

## Detailed design

This will add two new productions to the Swift grammar:

```
compiler-control-statement → warning-directive
warning-directive → #warning static-string-literal
```

Upon parsing this statement, the Swift compiler will immediately
emit a warning and discard the statement.

If a `#warning` exists inside a branch of a `#if` statement that is not
taken, then no warning is emitted.

```swift
#if false
#warning "This will not trigger a warning."
#endif
```

## Impact on existing code

This change is purely additive; no migration will be required.

## Alternatives considered

We could do some kind of comment-parsing based approach to surface
`TODO`s and `FIXME`s, but `#warning` serves as a general-purpose facility
for reporting at compile time. Plus, not all `TODO` or `FIXME` comments should
surface as warnings in the source.

`#error` and `#message`, though discussed on the mailing list, are intentially
left out of this proposal.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.