# Feature name

* Proposal: TBD
* Author(s): [Kevin Ballard](https://github.com/kballard)
* Status: **Review**
* Review manager: TBD

## Introduction

We have a way to declare Obj-C APIs that are "refined" for Swift. We should have
a way to declare Swift APIs that are "refined" for Obj-C, and by that I mean
Obj-C-compatible Swift APIs that are considered private in Swift but are public
in the generated Obj-C header.

Swift-evolution thread: [Proposal: Add public(objc) modifier](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002572.html)

## Motivation

When writing a Swift class that wants to be usable from Obj-C, it's common to
end up with Swift APIs that can't be bridged. In those cases, a separate
Obj-C-compatible API must be written. The problem with doing so is the
Obj-C-compatible API is still visible to other Swift code even though they
should be using the Swift API. This is because only `public` APIs get put in the
Obj-C bridging header (or `internal` APIs for applications).

There is a workaround which is to write code like

```swift
@objc(doFoo:bar:)
public func __objc_doFoo(foo: Int, bar: String)
```

but this is awkward and it clutters up the code completion list.

## Proposed solution

Add a new access type modifier `public(objc)`. What this says is "this method
should be public only for the purposes of generating the Obj-C bridging header".
It also implies `@objc`. With this new access type, we can write our
compatibility APIs like

```swift
private public(objc) func doFoo(foo: Int, bar: String)
```

## Detailed design

Extend the access type grammar to support `public(objc)`. There's already
precedent for this form in `private(set)`. This modifier can be used on any
declaration that supports `@objc`, including classes and methods. Any item with
this attribute is treated as though it has an explicit `@objc` attribute (if it
does already have an `@objc(name)` attribute, that attribute takes precedence).
It is an error to use this modifier on a declaration that has `@nonobjc` or
otherwise cannot support an `@objc` declaration (either due to `@objc` not being
valid on that declaration, or the declaration being a member of a type that is
not `@objc`).

This new `public(objc)` access modifier does not affect the access of the item
from Swift code at all. All it does affect is the generation of the Obj-C
bridging header, where any item annotated with `public(objc)` is treated as
though the item were itself `public`.

It is an error to use `public(objc)` on a member of a type that is not
sufficiently public as to be exposed to Obj-C. The simple rule here is that any
declaration that has `public(objc)` must actually show up in the Obj-C header,
and if it cannot show up there, the `public(objc)` modifier is an error.

For the sake of simplicity, in application code, `public(objc)` may be used on
members of `internal` type, as long as the `internal` type meets all the
qualifications to be exposed to Obj-C. This is done so APIs can be exposed to
Obj-C using the same modifier (`public(objc)`) regardless of context.

Writing `internal(objc)` should be considered an error, with a Fix-It that
rewrites the modifier as `public(objc)`.

Writing `public(objc)` on an API that is already `public` (or, for application
code, an API that is already `internal`) should be considered an error, with a
Fix-It that changes the `public` / `internal` access modifier to `private` (or
inserts `private` if no access modifier is specified).

## Impact on existing code

None. This change is purely additive, no existing code will be impacted.

## Alternatives considered

* Use `internal(objc)` instead of `public(objc)` in application code. I don't
  like this because it means the user must be aware of the context they're in
  for how to expose things to Obj-C, and this interferes with text snippets. In
  addition, it's very rare for anyone to actually write the `internal` modifier
  and I didn't want to start that now.
* Define some sort of attribute like `@objc_public` that has the same effect.
  It's certainly doable, but it feels more straightforward to say
  
  ```swift
private public(objc) func foo()
  ```

  than it does to say

  ```swift
@objc_public private func foo()
  ```
