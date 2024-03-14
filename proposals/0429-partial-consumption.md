# Partial consumption of noncopyable values

* Proposal: [SE-0429](0429-partial-consumption.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Nate Chandler](https://github.com/nate-chandler)
* Review Manager: [Xiaodi Wu](https://github.com/xwu)
* Implementation: On `main` gated behind `-enable-experimental-feature MoveOnlyPartialConsumption`
* Status: **Active Review (March 13...26, 2024)**
* Review: ([pitch #1](https://forums.swift.org/t/request-for-feedback-partial-consumption-of-fields-of-noncopyable-types/65884)) ([pitch #2](https://forums.swift.org/t/pitch-piecewise-consumption-of-noncopyable-values/70045)) ([review](https://forums.swift.org/t/se-0429-partial-consumption-of-noncopyable-values/70675))
<!-- * Upcoming Feature Flag: `MoveOnlyPartialConsumption` -->

## Introduction

We propose allowing noncopyable fields in deinit-less aggregates to be consumed individually,
so long as they are defined in the current module or frozen.
Additionally, we propose allowing fields of such an aggregate with a deinit to be consumed individually _within that deinit_.
This permits common patterns to be used with many noncopyable values.

## Motivation

In Swift today, it can be challenging to manipulate noncopyable fields of an aggregate.

For example, consider a `Pair` of noncopyable values:

```swift
struct Unique : ~Copyable {...}
struct Pair : ~Copyable {
  let first: Unique
  let second: Unique
}
```

It is currently not straightforward to write a function that forms a new `Pair` with the values reversed.
For example, the following code is not currently allowed:

```swift
extension Pair {
  consuming func swap() -> Pair {
    return Pair(
      first: second, // error: cannot partially consume 'self'
      second: first // error: cannot partially consume 'self'
    )
  }
}
```

There are various workarounds for this, but they are not ideal.

## Proposed solution

We allow noncopyable aggregates without deinits to be consumed field-by-field, if they are defined in the current module or frozen.
That makes `swap` above legal as written.

This initial proposal is deliberately minimal:
- We do not allow partial consumption of [noncopyable aggregates that have deinits](#future-direction-discard).
- We do not support [reinitializing](#future-direction-partial-reinitialization) fields after they are consumed.

[Imported aggregates](#imported-aggregates) can never be partially consumed, unless they are frozen.

## Detailed design

We relax the requirement that a noncopyable aggregate be consumed at most once on each path.
Instead we require only that each of its noncopyable fields be consumed at most once on each path.
Imported aggregates (i.e. those defined in another module and marked either `public` or `package`), however, cannot be partially consumed unless they are marked `@frozen`.

Extending the `Pair` example above, the following becomes legal:

```swift
func takeUnique(_ elt: consuming Unique) {}
extension Pair {
  consuming func passUniques(_ forward: Bool) {
    if forward {
      takeUnique(first)
      takeUnique(second)
    } else {
      takeUnique(second)
      takeUnique(first)
    }
  }
}
```

The struct `Pair` has two noncopyable fields, `first` and `second`.
And there are two paths through the function: the paths taken when `forward` is `true` and when it is `false`.
On both paths, `first` and `second` are both consumed exactly once.

It's not necessary to consume every field on every path, however.
For example, the following is allowed as well:

```swift
extension Pair {
  consuming func passUnique(_ front: Bool) {
    if front {
      takeUnique(first)
    } else {
      takeUnique(second)
    }
  }
}
```

Here, only `first` is consumed on the path taken when `front` is `true` and only `second` on that taken when `front` is `false`.

### Field lifetime extension<a name="lifetime-extension"/>

When a field is _not_ consumed on some path, its destruction is deferred as long as possible.
Here, that looks like this:

```swift
extension Pair {
  consuming func passUnique(_ front: Bool) {
    if front {
      takeUnique(first)
      // second is destroyed
    } else {
      takeUnique(second)
      // first is destroyed
    }
  }
}
```

Neither `first` nor `second` can be destroyed _after_ the `if`/`else` blocks because that would require a copy.

### Explicit field consumption

Fields can also be consumed explicitly via the `consume` keyword.
This enables overriding the [extension of a field's lifetime](#lifetime-extension).

Continuing the example, if it were necessary that `first` always be destroyed before `second`, the following could be written:

```swift
extension Pair {
  consuming func passUnique(_ front: Bool) {
    if front {
      takeUnique(first)
      // second is destroyed
    } else {
      _ = consume first
      takeUnique(second)
    }
  }
}
```

### Imported aggregates<a name="imported-aggregates"/>

Partial consumption of a non-copyable type is always allowed when the type is defined in the module where it is consumed.
If the type is defined in another module, partial consumption is only permitted if the type is marked `@frozen`.

The reason for this limitation is that as the module defining a type changes,
the type itself may change, adding or removing fields, changing fields to computed properties, and so on.
A partial consumption of the type's fields that makes sense as the type is defined by one version of the module
may not make sense as the type is defined in another version.
That consideration does not apply to frozen types, however,
because by marking them `@frozen`, the module's author promises not to change their layouts.

These rules are unavoidable for libraries built with library evolution
and are applied universally to avoid having language rules differ based on the build mode.

### Copyable fields

It is currently legal to have multiple consuming uses of a copyable field of a noncopyable aggregate.
For example:

```swift
func takeString(_ name: consuming String) {}
struct Named : ~Copyable {
  let unique: Unique
  let name: String
  consuming func use() {
    takeString(name)
    takeString(name)
    takeString(name)
    takeString(name)
    // unique is consumed
  }
}
```

This remains true when a value is partially consumed:

```swift
extension Named {
  consuming func unpack() {
    takeString(name)
    takeString(name)
    takeUnique(unique)
    takeString(name)
    takeString(name)
  }
}
```

### Partial consumption within deinits

There are two related reasons to limit partial consumption to fields of types without deinits:
First, the deinit of such types can't be run if it is partially consumed.
Second, no proposed mechanism to indicate that the deinit should not be run has been accepted.

Neither applies when partially consuming a value within its own deinit.
We propose allowing a value to be partially consumed there.

```swift
struct Pair2 : ~Copyable {
  let first: Unique
  let second: Unique

  deinit {
    takeUnique(first) // partially consumes self
    takeUnique(second) // partially consumes self
  }
}
```

This enables noncopyable structs to dispose of any resources they own on destruction.

## Source compatibility

No effect.
The proposal makes more code legal.

## ABI compatibility

No effect.

## Implications on adoption

This proposal makes more code legal.
And the code it makes legal is code written in a style familiar to Swift developers used to working with copyable values.
It alleviates some pain points associated with writing noncopyable code, easing further adoption.

## Future directions

### Discard<a name="future-direction-discard"/>

This document proposes limiting partial consumption to aggregates without deinit.
In the future, another proposal could lift that restriction.
The trouble with lifting it is that the deinit can no longer be run, which may be surprising.
That trouble could be mitigated by requiring the value be `discard`'d prior to partial consumption,
indicating that the deinit should not be run.

```swift
struct Box : ~Copyable {
  var unique: Unique
  deinit {...}

  consuming func unpack() -> Unique {
    discard self
    return unique
  }
}
```

### Partial reinitialization<a name="future-direction-partial-reinitialization"/>

This document only proposes allowing the fields of an aggregate to be consumed individually.
It does not allow for those fields to be _reinitialized_ in order to return the aggregate to a legal state.
In the future, though, another proposal could lift that restriction.

That would enable further code patterns--already legal with copyable values--to be written in noncopyable contexts
For example:

```swift
struct Unique : ~Copyable {}
struct Pair : ~Copyable {
  var first: Unique
  var second: Unique
}

extension Pair {
  mutating func swap() {
    let tmp = first
    first = second
    second = tmp
  }
}
```

### Partial consumption of copyable fields

This document only proposes allowing the noncopyable fields of a noncopyable aggregate to be consumed individually.
In the future, the ability to explicitly consume (via the `consume` keyword) the copyable fields of a copyable aggregate could be added.

```swift
class C {}
func takeC(_ c: consuming C)
struct PairPlusC : ~Copyable {
  let first: Unique
  let second: Unique
  let c: C
}

func disaggregate(_ p: consuming PairPlusC) {
  takeUnique(p.first)
  takeC(consume p.c) // p.c's lifetime ends
  takeUnique(p.second)
}
```

That would provide the ability to specify the point at which the lifetime of a copyable field should end.

### Partial consumption of copyable aggregates

This document only proposes allowing noncopyable aggregates to be partially consumed.
There is a natural extension of this to copyable aggregates:

```swift
class C {}
struct CopyablePairOfCs {
  let c1: C
  let c2: C
}
func tearDownInOrder(_ p: consuming CopyablePairOfCs) {
  takeC(consume p.c2)
  takeC(consume p.c1)
}
```

## Alternatives considered

### Explicit destructuring

Instead of consuming the fields of a struct piecewise, an alternative would be to simultaneously bind every field to a variable:

```swift
let (a, b) = destructure s
```

Something like this might be desirable eventually, but it would be best introduced as part of support for pattern matching for structs.
Even with such a feature, the behavior proposed here would remain desirable:
fields of a copyable aggregate can be consumed field-by-field,
so consuming fields of a noncopyable aggregate should be supported as much as possible too.

## Acknowledgments

Thanks to Andrew Trick for extensive design conversations and implementation review.
