# Make Optional Requirements Objective-C-only

* Proposal: [SE-0070](0070-optional-requirements.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Chris Lattner](http://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-May/000124.html)
* Bug: [SR-1395](https://bugs.swift.org/browse/SR-1395)

## Introduction

Swift currently has support for "optional" requirements in Objective-C
protocols, to match with the corresponding feature of Objective-C. We
don't want to make optional requirements a feature of Swift protocols
(for reasons described below), nor can we completely eliminate the
notion of the language (for different reasons also described
below). Therefore, to prevent confusion about our direction, this
proposal requires an explicit '@objc' attribute on each `optional`
requirement to indicate that this is an Objective-C compatibility
feature.

Swift-evolution threads:

* [Is there an underlying reason why optional protocol requirements need @objc?](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160229/011854.html)
* [\[Proposal\] Make optional protocol methods first class citizens](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160328/013770.html)
* [\[Idea\] How to eliminate 'optional' protocol requirements](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160404/014471.html)
* [\[Proposal draft\] Make Optional Requirements Objective-C-only](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160418/015552.html)
* [\[Review\] SE-0070: Make Optional Requirements Objective-C only](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160425/015681.html)

## Motivation

Having `optional` only work for Objective-C requirements is very
weird: it feels like a general feature with a compiler bug that
prevents it from working generally. However, we don't want to make it
a feature of Swift protocols and we can't eliminate it (see
[alternatives considered](#alternatives-considered)), so we propose to
rename the keyword to make it clear that this feature is intended only
for compatibility with Objective-C.

## Proposed solution

Require an explicit `@objc` attribute on each `optional` requirement:

```swift
@objc protocol NSTableViewDelegate {
  @objc optional func tableView(_: NSTableView, viewFor: NSTableColumn, row: Int) -> NSView? // correct

  optional func tableView(_: NSTableView, heightOfRow: Int) -> CGFloat  // error: 'optional' requirements are an Objective-C compatibility feature; add '@objc'
}
```

## Impact on existing code

Code that declares `@objc` protocols with `optional` requirements will
need to be changed to add the `@objc` attribute. However, it is
trivial for the migrator to update the code and for the compiler to
provide Fix-Its, so the actual impact on users should be
small. Moreover, explicitly writing `@objc` on optional requirements
has always been permitted.

## Alternatives considered

It's a fairly common request to make optional requirements work in
Swift protocols (as in the aforementioned [threads](#introduction)).
However, such proposals have generally met with resistance because
optional requirements have significant overlap with other protocol
features: "default" implementations via protocol extensions and
protocol inheritance. For the former case, the author of the protocol
can provide a "default" implementation via a protocol extension that
encodes the default case (rather than putting it at the call site). In
the latter case, the protocol author can separate the optional
requirements into a different protocol that a type can adopt to
opt-in to whatever behavior they customize. While not *exactly* the
same as optional requirements, which allow one to perform
per-requirement checking to determine whether the type implemented
that requirement, the gist of the threads is that doing so is
generally considered an anti-pattern: one would be better off
factoring the protocol in a different way. Therefore, we do not
propose to make optional requirements work for Swift protocols.

The second alternative would be to eliminate optional requirements
entirely from the language. The primary challenge here is Cocoa
interoperability, because Cocoa's protocols (primarily delegates and
data sources) have a large number of optional requirements that would
have to be handled somehow in Swift. These optional requirements would
have to be mapped to some other construct in Swift, but the code
generation model must remain the same because the Cocoa frameworks
rely on the ability to ask the question "was this requirement
implemented by the type?" in Objective-C code at run time.

The most popular approach to try to map optional requirements into
existing Swift constructs is to turn an optional method requirement
into a property of optional closure type. For example, this
Objective-C protocol:

```
@protocol NSTableViewDelegate
@optional
- (nullable NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row;
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row;
@end
```

which currently imports into Swift as:

```swift
@objc protocol NSTableViewDelegate {
  optional func tableView(_: NSTableView, viewFor: NSTableColumn, row: Int) -> NSView?
  optional func tableView(_: NSTableView, heightOfRow: Int) -> CGFloat
}
```

would become, e.g.,

```swift
@objc protocol NSTableViewDelegate {
  var tableView: ((NSTableView, viewFor: NSTableColumn, row: Int) -> NSView?)? { get }
  var tableView: ((NSTableView, heightOfRow: Int) -> CGFloat)? { get }
}
```

Unfortunately, this introduces an overloaded property named
`tableView`. To really make this work, we would need to introduce the
ability for a property to have a compound name, which would also let
us take the labels out of the function type:

```swift
@objc protocol NSTableViewDelegate {
  var tableView(_:viewFor:row:): ((NSTableView, NSTableColumn, Int) -> NSView?)? { get }
  var tableView(_:heightOfRow:): ((NSTableView, Int) -> CGFloat)? { get }
}
```

By itself, that is a good feature. However, we're not done, because we
would need yet another extension to the language: one
would want to be able to provide a *method* in a class that is used to
conform to a *property* in the protocol, e.g.,

```swift
class MyDelegate : NSObject, NSTableViewDelegate {
  func tableView(_: NSTableView, viewFor: NSTableColumn, row: Int) -> NSView? { ... }
  func tableView(_: NSTableView, heightOfRow: Int) -> CGFloat { ... }
}
```

Indeed, the Objective-C implementation model effectively requires us
to satisfy these property-of-optional-closure requirements with
methods so that Objective-C clients can use `-respondsToSelector:`. In
other words, one would not be able to implement these requirements in
by copy-pasting from the protocol to the implementing class:

```swift
class MyDelegate : NSObject, NSTableViewDelegate {
  // Note: The Objective-C entry points for these would return blocks, which is incorrect
  var tableView(_:viewFor:row:): ((NSTableView, NSTableColumn, Int) -> NSView?)? { return ...   }
  var tableView(_:heightOfRow:): ((NSTableView, Int) -> CGFloat)? { return ... }
}
```

That is both a strange technical restriction that would be limited to
Objective-C protocols and a serious usability problem: the easiest way
to stub out the contents of your type when it conforms to a given
protocol is to copy the declarations from the protocol into your type,
then fill in the details. This change would break that usage scenario
badly.

There have been other ideas to eliminate optional requirements. For
example, Objective-C protocols could be annotated with attributes that
say what the default implementation for each optional requirement is
(to be used only in Swift), but such a massive auditing effort is
impractical. There is a related notion of [caller-site default
implementations](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160404/014471.html)
that was not well-received due to its complexity.

Initially, this proposal introduce a new keyword
`objcoptional`. However, that keyword was really ugly. Thank you to
Xiaodi Wu for the suggestion to require an explicit `@objc`!
