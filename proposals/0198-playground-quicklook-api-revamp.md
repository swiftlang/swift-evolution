# Playground QuickLook API Revamp #

* Proposal: [SE-0198](0198-playground-quicklook-api-revamp.md)
* Authors: [Connor Wakamo](https://github.com/cwakamo)
* Implementation: Swift 4.1 deprecation ([apple/swift#13911](https://github.com/apple/swift/pull/13911)], introduction of new protocol ([apple/swift-xcode-playground-support#21](https://github.com/apple/swift-xcode-playground-support/pull/21)), Swift 5 removal + shim library ([apple/swift#14252](https://github.com/apple/swift/pull/14252), [apple/swift-corelibs-foundation#1415](https://github.com/apple/swift-corelibs-foundation/pull/1415), [apple/swift-xcode-playground-support#20](https://github.com/apple/swift-xcode-playground-support/pull/20))
* Review Manager: [Ben Cohen](https://github.com/airspeedswift/)
* Review thread: [SE-0198 review](https://forums.swift.org/t/se-0198-playground-quicklook-api-revamp/9448/16)
* Status: **Implemented in 4.1**

<!--
*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction ##

The standard library currently includes API which allows a type to customize its
description in Xcode playgrounds and Swift Playgrounds. This API takes the
form of the `PlaygroundQuickLook` enum which enumerates types which are
supported for quick looks, and the `CustomPlaygroundQuickLookable` protocol
which allows a type to return a custom `PlaygroundQuickLook` value for an
instance.

This is brittle, and to avoid dependency inversions, many of the cases are typed
as taking `Any` instead of a more appropriate type. This proposal suggests that
we deprecate `PlaygroundQuickLook` and `CustomPlaygroundQuickLookable` in Swift
4.1 so they can be removed entirely in Swift 5, preventing them from being
included in the standard library's stable ABI. To maintain compatibility with
older playgrounds, the deprecated symbols will be present in a temporary
compatibility shim library which will be automatically imported in playground
contexts. (This will represent an intentional source break for projects,
packages, and other non-playground Swift code which use `PlaygroundQuickLook` or
`CustomPlaygroundQuickLookable` when they switch to the Swift 5.0 compiler, even
in the compatibility modes.)

Since it is still useful to allow types to provide alternate descriptions for
playgrounds, we propose to add a new protocol to the PlaygroundSupport framework
which allows types to do just that. (PlaygroundSupport is a framework delivered
by the [swift-xcode-playground-support project](https://github.com/apple/swift-xcode-playground-support)
which provides API specific to working in the playgrounds environment). The new
`CustomPlaygroundDisplayConvertible` protocol would allow instances to return an
alternate object or value (as an `Any`) which would serve as their
description. The PlaygroundLogger framework, also part of
swift-xcode-playground-support, will be updated to understand this protocol.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20180108/042639.html)

## Motivation ##

The `PlaygroundQuickLook` enum which currently exists in the standard library is
substandard:

```swift
public enum PlaygroundQuickLook {
  case text(String)
  case int(Int64)
  case uInt(UInt64)
  case float(Float32)
  case double(Float64)
  case image(Any)
  case sound(Any)
  case color(Any)
  case bezierPath(Any)
  case attributedString(Any)
  case rectangle(Float64, Float64, Float64, Float64)
  case point(Float64, Float64)
  case size(Float64, Float64)
  case bool(Bool)
  case range(Int64, Int64)
  case view(Any)
  case sprite(Any)
  case url(String)
  case _raw([UInt8], String)
}
```

The names of these enum cases do not necessarily match current Swift naming
conventions (e.g. `uInt`), and many cases are typed as `Any` to avoid dependency
inversions between the standard library and higher-level frameworks like
Foundation and AppKit or UIKit. It also contains cases which the
PlaygroundLogger framework does not understand (e.g. `sound`), and this listing
of cases introduces revlock between PlaygroundLogger and the standard library
that makes it challenging to introduce support for new types of quick looks.

Values of this enum are provided to the PlaygroundLogger framework by types via
conformances to the `CustomPlaygroundQuickLookable` protocol:

```swift
public protocol CustomPlaygroundQuickLookable {
  var customPlaygroundQuickLook: PlaygroundQuickLook { get }
}
```

This protocol itself is not problematic, but if `PlaygroundQuickLook` is being
removed, then it needs to be removed as well. Additionally, there is a companion
underscored protocol which should be removed as well:

```swift
public protocol _DefaultCustomPlaygroundQuickLookable {
  var _defaultCustomPlaygroundQuickLook: PlaygroundQuickLook { get }
}
```

## Proposed solution ##

To solve this issue, we propose the following changes:

  - Introduce a new `CustomPlaygroundDisplayConvertible` protocol in
    PlaygroundSupport in Swift 4.1 to allow types to provide an alternate
    description for playground logging
  - Deprecate `PlaygroundQuickLook` and `CustomPlaygroundQuickLookable` in Swift
    4.1, suggesting users use `CustomPlaygroundDisplayConvertible` instead
  - Remove `PlaygroundQuickLook` and `CustomPlaygroundQuickLookable` from the
    standard library in Swift 5.0
  - Provide an automatically-imported shim library for the playgrounds context
    to provide the deprecated instances of `PlaygroundQuickLook` and
    `CustomPlaygroundQuickLookable` for pre-Swift 5 playgrounds

## Detailed design ##

To provide a more flexible API, we propose deprecating and ultimately removing
the `PlaygroundQuickLook` enum and `CustomPlaygroundQuickLookable` protocol in
favor of a simpler design. Instead, we propose introducing a protocol which just
provides the ability to return an `Any` that serves as a stand-in for the
instance being logged:

```swift
/// A type that supplies a custom description for playground logging.
///
/// All types have a default description for playgrounds. This protocol
/// allows types to provide custom descriptions which are then logged in
/// place of the original instance.
///
/// Playground logging can generate, at a minimum, a structured description
/// of any type. Playground logging is also capable of generating a richer,
/// more specialized description of core types -- for instance, the contents
/// of a `String` are logged, as are the components of an `NSColor` or
/// `UIColor`.
///
/// The current playground logging implementation logs specialized
/// descriptions of at least the following types:
///
/// - `String` and `NSString`
/// - `Int` and `UInt` (including the sized variants)
/// - `Float` and `Double`
/// - `Bool`
/// - `Date` and `NSDate`
/// - `NSAttributedString`
/// - `NSNumber`
/// - `NSRange`
/// - `URL` and `NSURL`
/// - `CGPoint`, `CGSize`, and `CGRect`
/// - `NSColor`, `UIColor`, `CGColor`, and `CIColor`
/// - `NSImage`, `UIImage`, `CGImage`, and `CIImage`
/// - `NSBezierPath` and `UIBezierPath`
/// - `NSView` and `UIView`
///
/// Playground logging may also be able to support specialized descriptions
/// of other types.
///
/// Implementors of `CustomPlaygroundDisplayConvertible` may return a value of
/// one of the above types to also receive a specialized log description.
/// Implementors may also return any other type, and playground logging will
/// generated structured logging for the returned value.
public protocol CustomPlaygroundDisplayConvertible {
  /// Returns the custom playground description for this instance.
  ///
  /// If this type has value semantics, the instance returned should be
  /// unaffected by subsequent mutations if possible.
  var playgroundDescription: Any { get }
}
```

Additionally, instead of placing this protocol in the standard library, we
propose placing this protocol in the PlaygroundSupport framework, as it is only
of interest in the playgrounds environment. Should demand warrant it, a future
proposal could suggest lowering this protocol into the standard library.

If this proposal is accepted, then code like the following:

```swift
extension MyStruct: CustomPlaygroundQuickLookable {
  var customPlaygroundQuickLook: PlaygroundQuickLook {
    return .text("A description of this MyStruct instance")
  }
}
```

would be replaced with something like the following:

```swift
extension MyStruct: CustomPlaygroundDisplayConvertible {
  var playgroundDescription: Any {
    return "A description of this MyStruct instance"
  }
}
```

This proposal also allows types which wish to be represented structurally
(like an array or dictionary) to return a type which is logged structurally
instead of requiring an implementation of the `CustomReflectable` protocol:

```swift
extension MyStruct: CustomPlaygroundDisplayConvertible {
  var playgroundDescription: Any {
    return [1, 2, 3]
  }
}
```

This is an enhancement over the existing `CustomPlaygroundQuickLookable`
protocol, which only supported returning opaque, quick lookable values for
playground logging.

Implementations of `CustomPlaygroundDisplayConvertible` may potentially chain
from one to another. For instance, with:

```swift
extension MyStruct: CustomPlaygroundDisplayConvertible {
  var playgroundDescription: Any {
    return "MyStruct description for playgrounds"
  }
}

extension MyOtherStruct: CustomPlaygroundDisplayConvertible {
  var playgroundDescription: Any {
    return MyStruct()
  }
}
```

Playground logging for `MyOtherStruct` would generate the string "MyStruct
description for playgrounds" rather than the structural view of `MyStruct`. It
is legal, however, for playground logging implementations to cap chaining to a
reasonable limit to guard against infinite recursion.

## Source compatibility ##

This proposal is explicitly suggesting that we make a source-breaking change in
Swift 5 to remove `PlaygroundQuickLook`, `CustomPlaygroundQuickLookable`, and
`_DefaultCustomPlaygroundQuickLookable`. Looking at a GitHub search, there are
fewer than 900 references to `CustomPlaygroundQuickLookable` in Swift source
code; from a cursory glance, many of these are duplicates, from forks of the
Swift repo itself (i.e. the definition of `CustomPlaygroundQuickLookable` in
the standard library), or are clearly implemented using pre-Swift 3 names of the
enum cases in `PlaygroundQuickLook`. (As a point of comparison, there are over
185,000 references to `CustomStringConvertible` in Swift code on GitHub, and
over 145,000 references to `CustomDebugStringConvertible`, so
`CustomPlaygroundQuickLookable` is clearly used many orders of magnitude less
than those protocols.) Furthermore, it does not appear that any projects
currently in the source compatibility suite use these types.

However, to mitigate the impact of this change, we propose to provide a limited
source compatibility shim for the playgrounds context. This will be delivered as
part of the swift-xcode-playground-support project as a library containing the
deprecated `PlaygroundQuickLook` and `CustomPlaygroundQuickLookable` protocols.
This library would be imported automatically in playgrounds. This source
compatibility shim would not be available outside of playgrounds, so any
projects, packages, or other Swift code would be intentionally broken by this
change when upgrading to the Swift 5.0 compiler, even when compiling in a
compatibility mode.

Due to the limited usage of these protocols, and the potential challenge in
migration, this proposal does not include any proposed migrator changes to
support the replacement of `CustomPlaygroundQuickLookable` with
`CustomPlaygroundDisplayConvertible`. Instead, we intend for Swift 4.1 to be a
deprecation period for these APIs, allowing any code bases which implement
`CustomPlaygroundQuickLookable` to manually switch to the new protocol. While
this migration may not be trivial programatically, it should -- in most cases --
be fairly trivial for someone to hand-migrate to
`CustomPlaygroundDisplayConvertible`. During the deprecation period, the
PlaygroundLogger framework will continue to honor implementations of
`CustomPlaygroundQuickLookable`, though it will prefer implementations of
`CustomPlaygroundDisplayConvertible` if both are present on a given type.

## Effect on ABI stability ##

This proposal affects ABI stability as it removes an enum and a pair of
protocols from the standard library. Since this proposal proposes adding
`CustomPlaygroundDisplayConvertible` to PlaygroundSupport instead of the
standard library, there is no impact of ABI stability from the new protocol, as
PlaygroundSupport does not need to maintain a stable ABI, as its clients --
playgrounds -- are always recompiled from source.

Since playgrounds are always compiled from source, the temporary shim library
does not represent a new ABI guarantee, and it may be removed if the compiler
drops support for the Swift 3 and 4 compatibility modes in a future Swift
release.

Removing `PlaygroundQuickLook` from the standard library also potentially allows
us to remove a handful of runtime entry points which were included to support
the `PlaygroundQuickLook(reflecting:)` API.

## Effect on API resilience ##

This proposal does not impact API resilience.

## Alternatives considered ##

### Do nothing ###

One valid alternative to this proposal is to do nothing: we could continue to
live with the existing enum and protocol. As noted above, these are fairly poor,
and do not serve the needs of playgrounds particularly well. Since this is our
last chance to remove them prior to ABI stability, we believe that doing nothing
is not an acceptable alternative.

### Provide type-specific protocols ###

Another alternative we considered was to provide type-specific protocols for
providing playground descriptions. We would introduce new protocols like
`CustomNSColorConvertible`, `CustomNSAttributedStringConvertible`, etc. which
would allow types to provide descriptions as each of the opaquely-loggable
types supported by PlaygroundLogger.

This alternative was rejected as it would balloon the API surface for
playgrounds, and it also would not provide a good way to select a preferred
description. (That is, what would PlaygroundLogger select as the
description of an instance if it implemented both `CustomNSColorConvertible`
*and* `CustomNSAttributedStringConvertible`?)

### Implement `CustomPlaygroundDisplayConvertible` in the standard library ###

As an alternative to implementing `CustomPlaygroundDisplayConvertible` in
PlaygroundSupport, we could implement it in the standard library. This would
make it available in all contexts (i.e. in projects and packages, not just in
playgrounds), but this protocol is not particularly useful outside of the
playground context, so this proposal elects not to place
`CustomPlaygroundDisplayConvertible` in the standard library.

Additionally, it should be a source-compatible change to move this protocol to
the standard library in a future Swift version should that be desirable. Since
playgrounds are always compiled from source, the fact that this would be an ABI
change for PlaygroundSupport does not matter, and a compatibility typealias
could be provided in PlaygroundSupport to maintain compatibility with code which
explicitly qualified the name of the `CustomPlaygroundDisplayConvertible`
protocol.

### Have `CustomPlaygroundDisplayConvertible` return something other than `Any` ###

One minor alternative considered was to have
`CustomPlaygroundDisplayConvertible` return a value with a more specific type
than `Any`. For example:

```swift
protocol CustomPlaygroundDisplayConvertible {
  var playgroundDescription: CustomPlaygroundDisplayConvertible { get }
}
```

or:

```swift
protocol PlaygroundDescription {}

protocol CustomPlaygroundDisplayConvertible {
  var playgroundDescription: PlaygroundDescription { get }
}
```

In both cases, core types which the playground logger supports would conform to
the appropriate protocol such that they could be returned from implementations
of `playgroundDescription`.

The benefit to this approach is that it is more self-documenting than the
approach proposed in this document, as a user can look up all of the types which
conform to a particular protocol to know what the playground logger understands.
However, this approach has a number of pitfalls, largely because it's
intentional that the proposal uses `Any` instead of a more-constrained protocol.
It should be possible to return anything as the stand-in for an instance,
including values without opaque playground quick look views, so that it's easier
to construct an alternate structured view of a type (without having to override
the more complex `CustomReflectable` protocol). Furthermore, by making the API
in the library use a general type like `Any`, this proposal prevents revlock
from occurring between IDEs and the libraries, as the IDE's playground logger
can implement support for opaque logging of new types without requiring library
changes. (And IDEs can opt to support a subset of types if they prefer, whereas
if the libraries promised support an IDE would effectively be compelled to
provide it.)

### Have `CustomPlaygroundDisplayConvertible` return an `Any?` instead of an `Any` ###

One alternative considered was to have `CustomPlaygroundDisplayConvertible`
return an `Any?` instead of an `Any`. This would permit individual instances to
opt-out of a custom playground description by returning nil instead of a
concrete value or object.

Although that capability is no longer present, in most cases implementors of
`CustomPlaygroundDisplayConvertible` may return a custom description which
closely mirrors their default description. One big exception to this are classes
which are considered core types, such as `NSView` and `UIView`, as one level of
subclass may wish to customize its description while deeper level may wish to
use the default description (which is currently a rendered image of the view).
This proposal does not permit that; the second-level subclass must return a
custom description one way or another, and due to the chaining nature of
`CustomPlaygroundDisplayConvertible` implementations, it cannot return `self`
and have that reliably indicate to the playground logger implementation that
that means "don't use a custom description".

This issue seems to be limited enough that it should not tarnish the API design
as a whole. Returning `Any` and not `Any?` is easier to understand, so this
proposal opts to do that. Should this be a larger issue than anticipated, a
future proposal could introduce a struct like `DefaultPlaygroundDescription<T>`
which the playground logger would understand to mean "don't check for a
`CustomPlaygroundDisplayConvertible` conformance on the wrapped value".

### Alternate Names for `CustomPlaygroundDisplayConvertible` ###

Finally, as this introduces a new protocol, there are other possible names:

- `CustomPlaygroundRepresentable`
- `CustomPlaygroundConvertible`
- `CustomPlaygroundPreviewConvertible`
- `CustomPlaygroundQuickLookConvertible`
- `CustomPlaygroundValuePresentationConvertible`
- `CustomPlaygroundPresentationConvertible`

`CustomPlaygroundRepresentable` was rejected as it does not match the naming
convention established by
`CustomStringConvertible`/`CustomDebugStringConvertible`.
`CustomPlaygroundConvertible` was rejected as not being specific enough -- types
conforming to this protocol are not themselves convertible to playgrounds, but
are instead custom convertible for playground display.
`CustomPlaygroundPreviewConvertible` is very similar to
`CustomPlaygroundDisplayConvertible`, but implies more about the presentation
than is appropriate as a playground environment is free to display it any way it
wants, not just as a "preview". `CustomPlaygroundQuickLookConvertible` was
rejected as it potentially invokes the to-be-removed `PlaygroundQuickLook` enum.
`CustomPlaygroundValuePresentationConvertible` and
`CustomPlaygroundPresentationConvertible` were rejected as too long of names for
the protocol.
