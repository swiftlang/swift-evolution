# Key Path Member Lookup

* Proposal: [SE-0252](0252-keypath-dynamic-member-lookup.md)
* Authors: [Doug Gregor](https://github.com/DougGregor), [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Ted Kremenek](https://github.com/tkremenek)
* Status: **Implemented (Swift 5.1)**
* Implementation: [PR #23436](https://github.com/apple/swift/pull/23436)

## Introduction

This proposal attempts to enable stronger-typed version of the dynamic member lookup by extending functionality of an existing `@dynamicMemberLookup` attribute with key path based variants.

[Swift Evolution Pitch](https://forums.swift.org/t/pitch-key-path-member-lookup/21579)

## Motivation

Dynamic member lookup allows a type to opt in to extending member lookup ("dot" syntax) for arbitrary member names, turning them into a string that can then be resolved at runtime. Dynamic member lookup allows interoperability with dynamic languages where the members of a particular instance can only be determined at runtime... but no earlier. Dynamic member lookups, therefore, tend to work with type-erased wrappers around foreign language objects (e.g., `PyVal` for an arbitrary Python object), which don't provide much static type information.

On the other hand, key paths provide a dynamic representation of a property that can be used to read or write the referenced property. Key paths maintain static type information about the type of the property being accessed, making them a good candidate for abstractly describing a reference to data that is modeled via Swift types. However, key paths can be cumbersome to create and apply. Consider a type `Lens<T>` that abstractly refers to some value of type `T`, through which one can read (and possibly write) the value of that `T`:

```swift
struct Lens<T> {
  let getter: () -> T
  let setter: (T) -> Void

  var value: T {
    get {
      return getter()
    }
    nonmutating set {
      setter(newValue)
    }
  }
}
```

Given some `Lens`, we would like to produce a new `Lens` referring to a property of the value produced by the lens. Key paths allow us to write such a projection function directly:

```swift
extension Lens {
  func project<U>(_ keyPath: WritableKeyPath<T, U>) -> Lens<U> {
    return Lens<U>(
        getter: { self.value[keyPath: keyPath] },
        setter: { self.value[keyPath: keyPath] = $0 })
  }
}
```

As an example, consider a `Lens<Rectangle>`:

```swift
struct Point {
  var x, y: Double
}

struct Rectangle {
  var topLeft, bottomRight: Point
}

func projections(lens: Lens<Rectangle>) {
  let topLeft = lens.project(\.topLeft)   // inferred type is Lens<Point>
  let top = lens.project(\.topLeft.y)     // inferred type is Lens<Double>
}
```

Forming the projection is a bit unwieldy: it's a call to `project` in which we need to use `\.` to then describe the key path. Why not support the most direct syntax to form a lens referring to some part of the stored value, e.g., `lens.topLeft` or `lens.topLeft.y`, respectively?

## Proposed solution

Augment existing `@dynamicMemberLookup` attribute to support key path based dynamic member lookup by rewriting "dot" and "subscript" syntax into a call to a special subscript whose argument is a key path describing the member. Here, we reimplement `Lens` in terms of new `@dynamicMemberLookup` capabilities:


```swift
@dynamicMemberLookup
struct Lens<T> {
  let getter: () -> T
  let setter: (T) -> Void

  var value: T {
    get {
      return getter()
    }
    nonmutating set {
      setter(newValue)
    }
  }

  subscript<U>(dynamicMember keyPath: WritableKeyPath<T, U>) -> Lens<U> {
    return Lens<U>(
        getter: { self.value[keyPath: keyPath] },
        setter: { self.value[keyPath: keyPath] = $0 })
  }
}
```

Given a `Lens<Rectangle>` named `lens`, the expression `lens.topLeft` will be evaluated as `lens[dynamicMember: \.topLeft]`, allowing normal member accesses on a `Lens` to produce a new `Lens`.

The formation of the key path follows a "single step" approach where each key path component is split into a separate `[dynamicMember: KeyPath<T, U>]` invocation. For example, the expression `lens.topLeft.y` will be evaluated as `lens[dynamicMember: \.topLeft][dynamicMember: \.y]`, producing a `Lens<Double>`.

## Detailed design

Proposed solution builds on existing functionality of the `@dynamicMemberLookup` attribute. It adopts restrictions associated with existing string-based design as well as a couple of new ones:

* Key path member lookup only applies when the `@dynamicMemberLookup` type does not contain a member with the given name. This privileges the members of the `@dynamicMemberLookup` type (e.g., `Lens<Rectangle>`), hiding those of whatever type is that the root of the keypath (e.g., `Rectangle`).
* `@dynamicMemberLookup` can only be written directly on the definition of a type, not an an extension of that type.
* A `@dynamicMemberLookup` type must define a subscript with a single, non-variadic parameter whose argument label is `dynamicMember` and that accepts one of the key path types (e.g., `KeyPath`, `WritableKeyPath`).
* In case both string-based and keypath-based overloads match, keypath takes priority as one carrying more typing information.

## Source compatibility

This is an additive proposal, which makes ill-formed syntax well-formed but otherwise does not affect existing code. First, only types that opt in to `@dynamicMemberLookup` will be affected. Second, even for types that adopt `@dynamicMemberLookup`, the change is source-compatible because the transformation to use `subscript(dynamicMember:)` is only applied when there is no member of the given name.

## Effect on ABI stability

This feature is implementable entirely in the type checker, as (effectively) a syntactic transformation on member access expressions. It, therefore, has no impact on the ABI.

## Effect on API resilience

Adding `@dynamicMemberLookup` is a resilient change to a type, as is the addition of the subscript.

## Alternatives considered

The main alternative would be to not do this at all.

Another alternative would be to use a different attribute to separate this feature from `@dynamicMemberLookup`, e.g. `@keyPathMemberLookup` since string based design doesn't, at the moment, provide any static checking for member access. We recognize this as a valid concern, but at the same time consider both to be fundamentally the same feature with different amount of static checking. Using the same attribute allows us to adhere to "fewer conceptular features" concept, as well as, enables powerful combinations where string based dynamic lookup could be used as a fallback when key path dynamic lookup fails.
