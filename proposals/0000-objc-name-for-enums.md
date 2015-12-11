# Feature name

* Proposal: TBD
* Author(s): [Kevin Ballard](https://github.com/kballard)
* Status: **Review**
* Review manager: TBD

## Introduction

Allow for `@objc(name)` declarations on `enum`s to rename the Obj-C enum.

## Motivation

Swift allows the `@objc` attribute on enums with a raw type of `Int`, and it
uses this to synthesize an Obj-C enum declaration in the generated header. The
problem is that it doesn't allow for `@objc(name)` to rename the enum.
Generically-named enums are perfectly fine in Swift as they're scoped by the
module (or nested type), but in Obj-C a generically-named enum can conflict with
other enum declarations. Making these enums safe for use in Obj-C requires
giving them a less-generic name.

## Proposed solution

Allow `@objc(name)` on the `enum` declaration to control the name that the enum
uses in Obj-C. Furthermore, we should allow for using `@objc(name)` on
individual cases in order to rename those cases in Obj-C.

## Detailed design

Update compiler diagnostics to stop emitting an error for `@objc(name)` on
`enum`s, and update PrintObjC to take `@objc(name)` into account for `enum`s.
Also update the compiler to allow for `@objc(name)` on enum cases that are part
of an `@objc` enum (`@objc` with no name may be allowed with a warning;
`@nonobjc` on cases in an `@objc enum` must be disallowed) and update PrintObjC
accordingly.

If an `@objc(name)` declaration is on a case declaration that declares multiple
variants, as in `@objc(Foo) case Foo, Bar`, the attribute applies to both cases.
This will be caught by code that checks to make sure there's no name collisions,
just as if it had been declared as `@objc(Foo) case Foo; @objc(Foo) case Bar`.

## Impact on existing code

No impact. There's no code today that uses `@objc(name)` on `enum`s or `@objc`
on cases, since that's currently disallowed.

## Open Questions

Should the generated Obj-C declarations use the `swift_name` attribute to
indicate the Swift type it came from? Proposal [SE-0005][] generalizes
`swift_name` to apply to any arbitrary C or Obj-C entity, so it will be legal to
put on `enum`s.

[SE-0005]: https://github.com/apple/swift-evolution/blob/master/proposals/0005-objective-c-name-translation.md
