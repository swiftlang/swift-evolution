# Adding `toggle` to `Bool`

* Proposal: [SE-0199](0199-bool-toggle.md)
* Authors: [Chris Eidhof](http://chris.eidhof.nl)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift/)
* Status: **Implemented (Swift 4.2)**
* Decision notes: [Rationale](https://forums.swift.org/t/accepted-se-199-add-toggle-to-bool/10681)
* Implementation: [apple/swift#14586](https://github.com/apple/swift/pull/14586)
* Review thread: [Swift evolution forum](https://forums.swift.org/t/se-0199-adding-toggle-method-to-bool/)


## Introduction

I propose adding a `mutating func toggle` to `Bool`. It toggles the `Bool`.

- Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20180108/042767.html)
- Swift forums thread: [pitch: adding toggle to Bool](https://forums.swift.org/t/pitch-adding-toggle-to-bool/7414)

## Motivation

For `Bool` variables, it is common to want to toggle the state of the variable. In larger (nested) structs, the duplication involved can become especially annoying:

```swift
myVar.prop1.prop2.enabled = !myVar.prop1.prop2.enabled
```

It's also easy to make a mistake in the code above if there are multiple `Bool` vars.

## Proposed solution

Add a method `toggle` on `Bool`:

```swift
extension Bool {
  /// Equivalent to `someBool = !someBool`
  ///
  /// Useful when operating on long chains:
  ///
  ///    myVar.prop1.prop2.enabled.toggle()
  mutating func toggle() {
    self = !self
  }
}
```

This allows us to write the example above without duplication:

```swift
myVar.prop1.prop2.enabled.toggle()
```

`!` and `toggle()` mirror the API design for `-` and `negate()`. (Thanks to Xiaodi Wu for pointing this out).

## Detailed design

N/A

## Source compatibility

This is strictly additive.

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Alternatives considered

Other names could be:

- `invert`
- `negate`
- `flip`

From the brief discussion on SE, it seems like `toggle` is the clear winner.

Some people also suggested adding a non-mutating variant (in other words, a method with the same semantics as the prefix `!` operator), but that's out of scope for this proposal, and in line with commonly rejected proposals.
