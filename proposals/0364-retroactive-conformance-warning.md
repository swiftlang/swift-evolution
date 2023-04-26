# Warning for Retroactive Conformances of External Types

* Proposal: [SE-0364](0364-retroactive-conformance-warning.md)
* Author: [Harlan Haskins](https://github.com/harlanhaskins)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Active review (April 25...May 9)**
* Implementation: [apple/swift#36068](https://github.com/apple/swift/pull/36068)
* Review: ([first pitch](https://forums.swift.org/t/warning-for-retroactive-conformances-if-library-evolution-is-enabled/45321))
         ([second pitch](https://forums.swift.org/t/pitch-warning-for-retroactive-conformances-of-external-types-in-resilient-libraries/56243))
         ([first review](https://forums.swift.org/t/se-0364-warning-for-retroactive-conformances-of-external-types/58922))
        ([second review](https://forums.swift.org/t/second-review-se-0364-warning-for-retroactive-conformances-of-external-types/64615))

## Introduction

Many Swift libraries vend currency protocols, like Equatable, Hashable, Codable,
among others, that unlock worlds of common functionality for types that conform
to them. Sometimes, if a type from another module does not conform to a common
currency protocols, developers will declare a conformance of that type to that
protocol within their module. However, protocol conformances are globally unique
within a process in the Swift runtime, and if multiple modules declare the same
conformance, it can cause major problems for library clients and hinder the
ability to evolve libraries over time.

## Motivation

Consider a library that, for one of its core APIs, declares a conformance of
`Date` to `Identifiable`, in order to use it with an API that diffs elements
of a collection by their identity.

```swift
// Not a great implementation, but I suppose it could be useful.
extension Date: Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}
```

Now that this client has declared this conformance, if Foundation decides to
add this conformance in a later revision, this client will fail to build.
Before the client removes their conformance and rebuilds, however, their
application will exhibit undefined behavior, as it is indeterminate which
definition of this conformance will "win". Foundation may well have defined
it to use `Date.timeIntervalSinceReferenceDate`, and if the client had persisted
these IDs to a database or some persistent storage beyond the lifetime of the process,
then their dates will have completely different IDs.

Worse, if this is a library target, this conformance propagates down to every
client that imports the library. This is especially bad for frameworks that
are built with library evolution enabled, as their clients link against
binary frameworks and usually are not aware these conformances don't come from
the actual owning module.

## Proposed solution

This proposal adds a warning that explicitly calls out this pattern as
problematic and unsupported.

```swift
/tmp/retro.swift:3:1: warning: extension declares a conformance of imported type
'Date' to imported protocol 'Identifiable'; this will not behave correctly if
the owners of 'Foundation' introduce this conformance in the future
extension Date: Identifiable {
^
```

If absolutely necessary, clients can silence this warning by adding a new attribute,
`@retroactive`, to the protocol in question.

The compiler will enforce that there is an explicit `@retroactive` conformance
for each protocol included up the hierarchy. If needed, it will emit a fix-it to
generate extensions for each retroactive conformance in the hierarchy.

```swift
extension Date: @retroactive Identifiable {
    // ...
}
```

## Detailed design

This warning will appear only if all of the following conditions are met, with a few exceptions.

- The type being extended was declared in a different module from the extension.
- The protocol for which the extension introduces the conformance is declared in a different
  module from the extension.

The following exceptions apply to either the conforming type or the protocol:

- If it is declared in a Clang module, and the extension in question is declared
  in a Swift overlay of that module, this is not considered a retroactive conformance.
- If it is declared or transitively imported in a bridging header or through the
  `-import-objc-header` flag, and the type does not belong to any other module, the warning is not
  emitted. This could be a retroactive conformance, but since these are added to an implicit module
  called `__ObjC`, we have to assume the client takes responsibility for these declaration.
- If it is declared in one module, but uses the `@_originallyDefined(in:)` attribute to
  signify that it has moved from a different module, then this will not warn.

For clarification, the following are still valid, safe, and allowed:
- Conformances of external types to protocols defined within the current module.
- Extensions of external types that do not introduce a conformance. These do not introduce runtime conflicts, since the
  module name is mangled into the symbol.

The `@retroactive` attribute may only be used in extensions, and only when used
to introduce a conformance that requires its existence. It will be an error to
use `@retroactive` outside of the declaration of a retroactive conformance.

## Source compatibility

`@retroactive` is a new attribute, but it is purely additive; it can be accepted
by all language versions. It does mean projects building with an older Swift
will not have access to this syntax, so as a source compatible fallback,
a client can silence this warning by fully-qualifying all types in the extension.
As an example, the above conformance can also be written as

```swift
extension Foundation.Date: Swift.Identifiable {
    // ...
}
```

This will allow projects that need to build with multiple versions of Swift, and
which have valid reason to declare such conformances, to declare them without
tying their project to a newer compiler build.

## Effect on ABI stability

This proposal has no effect on ABI stability.

## Effect on API resilience

This proposal has no direct effect on API resilience, but has the indirect effect of reducing
the possible surface of client changes introduced by the standard library adding new conformances.

## Alternatives considered

#### Enabling this warning only for resilient libraries

A previous version of this proposal proposed enabling this warning only for resilient libraries, as those
are meant to be widely distributed and such a conformance is much more difficult to remove from clients
who expect ABI stability. However, review feedback showed a clear preference to enable this warning always,
to give library authors more freedom to introduce conformances.

#### Putting it behind a flag

This warning could very well be enabled by a flag, but there's not much
precedent in Swift for flags to disable individual warnings.
