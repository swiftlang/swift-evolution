# Playground QuickLook API Revamp #

* Proposal: [SE-NNNN](NNNN-playground-quicklook-api-revamp.md)
* Authors: [Connor Wakamo](https://github.com/cwakamo)
* Review Manager: TBD
* Status: **Awaiting implementation**

<!--
*During the review process, add the following fields as needed:*

* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)
-->

## Introduction ##

The standard library currently includes API which allows a type to customize its
representation in Xcode playgrounds and Swift Playgrounds. This API takes the
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

Since it is still useful to allow types to provide alternate representations for
playgrounds, we propose to add a new protocol to the PlaygroundSupport framework
which allows types to do just that. (PlaygroundSupport is a framework delivered
by the [swift-xcode-playground-support project](https://github.com/apple/swift-xcode-playground-support)
which provides API specific to working in the playgrounds environment). The new
`CustomPlaygroundRepresentable` protocol would allow instances to return an
alternate object or value (as an `Any`) which would serve as their
representation. The PlaygroundLogger framework, also part of
swift-xcode-playground-support, will be updated to understand this protocol.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/)

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

  - Introduce a new `CustomPlaygroundRepresentable` protocol in
    PlaygroundSupport in Swift 4.1 to allow types to provide an alternate
    representation for playground logging
  - Deprecate `PlaygroundQuickLook` and `CustomPlaygroundQuickLookable` in Swift
    4.1, suggesting users use `CustomPlaygroundRepresentable` instead
  - Remove `PlaygroundQuickLook` and `CustomPlaygroundQuickLookable` from the
    standard library in Swift 5.0
  - Provide an automatically-imported shim library for the playgrounds context
    to provide the deprecated instances of `PlaygroundQuickLook` and
    `CustomPlaygroundQuickLookable` for pre-Swift 5 playgrounds

## Detailed design ##

To provide a more flexible API, we propose deprecating and ultimately removing
the `PlaygroundQuickLook` enum and `CustomPlaygroundQuickLookable` protocol in
favor of a simpler design. Instead, we propose introducing a protocol which just
provides the ability to return an `Any` (or `nil`) that serves as a stand-in for
the instance being logged:

```swift
/// A type that supplies a custom representation for playground logging.
///
/// All types have a default representation for playgrounds. This protocol
/// allows types to provide custom representations which are then logged in
/// place of the original instance. Alternatively, implementors may choose to
/// return `nil` in instances where the default representation is preferable.
///
/// Playground logging can generate, at a minimum, a structured representation
/// of any type. Playground logging is also capable of generating a richer,
/// more specialized representation of core types -- for instance, the contents
/// of a `String` are logged, as are the components of an `NSColor` or
/// `UIColor`.
///
/// The current playground logging implementation logs specialized
/// representations of at least the following types:
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
/// Playground logging may also be able to support specialized representations
/// of other types.
///
/// Implementors of `CustomPlaygroundRepresentable` may return a value of one of
/// the above types to also receive a specialized log representation.
/// Implementors may also return any other type, and playground logging will
/// generated structured logging for the returned value.
public protocol CustomPlaygroundRepresentable {
  /// Returns the custom playground representation for this instance, or nil if
  /// the default representation should be used.
  ///
  /// If this type has value semantics, the instance returned should be
  /// unaffected by subsequent mutations if possible.
  var playgroundRepresentation: Any? { get }
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
extension MyStruct: CustomPlaygroundRepresentable {
  var playgroundRepresentation: Any? {
    return "A description of this MyStruct instance"
  }
}
```

This proposal also allows types which wish to be represented structurally
(like an array or dictionary) to return a type which is logged structurally
instead of requiring an implementation of the `CustomReflectable` protocol:

```swift
extension MyStruct: CustomPlaygroundRepresentable {
  var playgroundRepresentation: Any? {
    return [1, 2, 3]
  }
}
```

This is an enhancement over the existing `CustomPlaygroundQuickLookable`
protocol, which only supported returning opaque, quick lookable values for
playground logging. (By returning an `Any?`, it also allows instances to opt-in
to their standard playground representation if that is preferable some cases.)

Implementations of `CustomPlaygroundRepresentable` may potentially chain from
one to another. For instance, with:

```swift
extension MyStruct: CustomPlaygroundRepresentable {
  var playgroundRepresentation: Any? {
    return "MyStruct representation"
  }
}

extension MyOtherStruct: CustomPlaygroundRepresentable {
  var playgroundRepresentation: Any? {
    return MyStruct()
  }
}
```

Playground logging for `MyOtherStruct` would generate the string "MyStruct
representation" rather than the structural view of `MyStruct`. It is legal,
however, for playground logging implementations to cap chaining to a reasonable
limit to guard against infinite recursion.

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
`CustomPlaygroundRepresentable`. Instead, we intend for Swift 4.1 to be a
deprecation period for these APIs, allowing any code bases which implement
`CustomPlaygroundQuickLookable` to manually switch to the new protocol. While
this migration may not be trivial programatically, it should -- in most cases --
be fairly trivial for someone to hand-migrate to
`CustomPlaygroundRepresentable`. During the deprecation period, the
PlaygroundLogger framework will continue to honor implementations of
`CustomPlaygroundQuickLookable`, though it will prefer implementations of
`CustomPlaygroundRepresentable` if both are present on a given type.

## Effect on ABI stability ##

This proposal affects ABI stability as it removes an enum and a pair of
protocols from the standard library. Since this proposal proposes adding
`CustomPlaygroundRepresentable` to PlaygroundSupport instead of the standard
library, there is no impact of ABI stability from the new protocol, as
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
providing playground representations. We would introduce new protocols like
`CustomNSColorConvertible`, `CustomNSAttributedStringConvertible`, etc. which
would allow types to provide representations as each of the opaquely-loggable
types supported by PlaygroundLogger.

This alternative was rejected as it would balloon the API surface for
playgrounds, and it also would not provide a good way to select a preferred
representation. (That is, what would PlaygroundLogger select as the
representation of an instance if it implemented both `CustomNSColorConvertible`
*and* `CustomNSAttributedStringConvertible`?)

### Implement `CustomPlaygroundRepresentable` in the standard library ###

As an alternative to implementing `CustomPlaygroundRepresentable` in
PlaygroundSupport, we could implement it in the standard library. This would
make it available in all contexts (i.e. in projects and packages, not just in
playgrounds), but this protocol is not particularly useful outside of the
playground context, so this proposal elects not to place
`CustomPlaygroundRepresentable` in the standard library.

Additionally, it should be a source-compatible change to move this protocol to
the standard library in a future Swift version should that be desirable. Since
playgrounds are always compiled from source, the fact that this would be an ABI
change for PlaygroundSupport does not matter, and a compatibility typealias
could be provided in PlaygroundSupport to maintain compatibility with code which
explicitly qualified the name of the `CustomPlaygroundRepresentable` protocol.

### Have `CustomPlaygroundRepresentable` return something other than `Any?` ###

One minor alternative considered was to have `CustomPlaygroundRepresentable`
return a value with a more specific type than `Any?`. For example:

```swift
protocol CustomPlaygroundRepresentable {
  var playgroundRepresentation: CustomPlaygroundRepresentable? { get }
}
```

or:

```swift
protocol PlaygroundRepresentation {}

protocol CustomPlaygroundRepresentable {
  var playgroundRepresentation: PlaygroundRepresentation? { get }
}
```

In both cases, core types which the playground logger supports would conform to
the appropriate protocol such that they could be returned from implementations
of `playgroundRepresentation`.

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
