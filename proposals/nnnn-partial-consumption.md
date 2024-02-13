# Partial consumption of noncopyable values

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Michael Gottesman](https://github.com/gottesmm), [Nate Chandler](https://github.com/nate-chandler)
* Review Manager: TBD
* Status: **Awaiting review**
* Upcoming Feature Flag: `MoveOnlyPartialConsumption`

## Introduction

We propose allowing noncopyable fields in deinit-less, non-resilient aggregates to be consumed individually.
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
      first: first, // error: cannot partially consume 'self'
      second: second // error: cannot partially consume 'self'
    )
  }
}
```

There are various workarounds for this, but they are not ideal.

## Proposed solution

We allow non-resilient, noncopyable aggregates without deinits to be consumed field-by-field.
That makes `swap` above legal as written.

This initial proposal is deliberately minimal:
- We do not allow partial consumption of [noncopyable aggregates that have deinits](#future-direction-discard).
- We do not support [reinitializing](#future-direction-partial-reinitialization) fields after they are consumed.

[Resilient aggregates](#resilient-aggregates) can never be partially consumed.

## Detailed design

We relax the requirement that a noncopyable aggregate be consumed at most once on each path.
Instead we require only that each of its noncopyable fields be consumed at most once on each path.
Resilient aggregates, however, cannot be partially consumed when used outside their defining resilience domain.

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

### Field lifetime extension

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

### Interaction with resilient types<a name="resilient-aggregates"/>

`public` (and `@usableFromInline`) types defined in a library built with library evolution are "resilient".
Although a resilient struct may--at the time the library is compiled--actually just combine fields together

```swift
public struct Resilient : ~Copyable {
  public var unique: Unique
}
```

client code cannot rely on that: the struct may evolve.
For example, the stored property might become computed in a later release of the library:

```swift
public struct Resilient : ~Copyable {
  public var unique: Unique {
    get {...}
    set {...}
  }
}
```

Partial consumption relies on viewing a struct as just a combination of values, though.
This view is what permits the refinement of the check that the whole noncopyable aggregate is consumed on each path
to checking that each noncopyable field of the aggregate is consumed exactly once.

Because, as this example illustrates, the layout of a resilient struct may change,
partial consumption isn't permitted for a noncopyable resilient value used outside the resilience domain which defines the type.

### Copyable fields

It is currently legal to repeatedly consume a copyable field of a noncopyable aggregate.
For example:

```swift
func takeString(_ name: consuming String) {}
struct Named : ~Copyable {
  let unique: Unique
  let name: String
  consuming func use() {
    takeString(name)
    takeString(name)
    // self is consumed
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
  }
}
```

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
It does not allow for those fields to be _reinitialized_ in order to return then aggregate to a legal state.
In the future, though, another proposal could lift that restriction.

That would enable further code patterns legal with copyable values to be written in noncopyable contexts
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


## Alternatives considered

### Explicit destructuring

Instead of consuming the fields of a struct piecewise, an alternative would be to simultaneously bind every field to a variable:

```
let (a, b) = destructure s
```

Something like this might be desirable eventually, but it would be best introduced as part of support for pattern matching for structs.
Even with such a feature, the behavior proposed here would remain desirable:
fields of a copyable aggregate can be consumed field-by-field,
so consuming fields of a noncopyable aggregate should be supported as much as possible too.

## Acknowledgments

Thanks to Andrew Trick for extensive design conversations and implementation review.
