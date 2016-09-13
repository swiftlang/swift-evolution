# Flattening the function type of unapplied method references

* Proposal: [SE-0042](0042-flatten-method-types.md)
* Author: [Joe Groff](https://github.com/jckarter)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Accepted**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013251.html)
* Bug: [SR-1051](https://bugs.swift.org/browse/SR-1051)

## Introduction

An **unapplied method reference**, such as `Type.instanceMethod` in the
following example, currently produces a curried function value of type
`(Self) -> (Args...) -> Ret`:

```swift
struct Type {
  var x: Int
  func instanceMethod(y y: Int) -> Int {
    return x + y
  }
}

let f = Type.instanceMethod // f : (Type) -> (y: Int) -> Int
f(Type(x: 1))(y: 2)         // ==> 3
```

In order to make unapplied method references more
useful and consistent with idiomatic Swift, and to make them workable for
`mutating` methods, we should change them to produce a function with a
flat function type, `(Self, Args...) -> Ret`:

```swift
let f = Type.instanceMethod // f: (Type, y: Int) -> Int
f(Type(x: 1), y: 2)         // ==> 3
```

Swift-evolution thread: [Flattening the function type of unapplied instance methods](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/010843.html)

## Motivation

Currying hasn't proven itself to be used much in idiomatic Swift. Standard
library collection transforms such as `reduce` and `sort` prefer "flat"
function arguments, and Cocoa APIs that use blocks are imported into Swift
with flat function types as well. By producing curried types, unapplied method
references simply aren't very useful as-is compared to free functions or
closure literals. For instance, though you can pass the global `+` operator
readily to `reduce` to sum a sequence of numbers:

```swift
func sumOfInts(ints: [Int]) -> Int {
  return ints.reduce(0, combine: +)
}
```

you can't do the same with a binary method, such as `Set.union`:

```swift
func unionOfSets<T>(sets: [Set<T>]) -> Set<T> {
  // Error: `combine` expects (Set<T>, Set<T>) -> Set<T>, but
  // `Set.union` has type (Set<T>) -> (Set<T>) -> Set<T>
  return sets.reduce([], combine: Set.union)
}
```

Even unary methods are referenced as type `(Self) -> () -> Ret`, meaning
they can't be readily used with transforms like `map`:

```swift
func sortedArrays<T: Comparable>(arrays: [[T]]) -> [T] {
  // Error: `map` expects [T] -> [T], but
  // `Array.sort` has type ([T]) -> () -> [T]
  return arrays.map(Array.sort)
}
```

This currying is also incompatible with `mutating` methods due to the
semantics of `inout` parameters. In a chained call such as `f(&x)(y)`,
the mutation window for `x` only lasts as long as the first call. The second
application of `y` is no longer allowed to mutate `x`. We currently
miscompile unapplied references to `mutating` methods, capturing a dangling
pointer when the reference is partially applied and leading to undefined
behavior when the full application occurs.

## Proposed solution

We should change the type of an unapplied method reference to produce a
flattened function value, instead of a curried one. This will make unapplied
methods more readily useful with real Swift libraries, and make them
supportable for `mutating` methods.

## Detailed design

When an instance method is found by name lookup into a type reference or
metatype value, a function value is produced that takes the `self` instance
followed by the method arguments of the referenced method. If the method is
`mutating`, then the first parameter of the resulting function value is
`inout`. For example:

```swift
struct Type {
  func instanceMethod(x: Int) -> Float {}
  mutating func mutatingMethod(x: String) -> Double {}
}

Type.instanceMethod // : (Type, Int) -> Float
Type.mutatingMethod // : (inout Type, String) -> Double
```

This proposal does **not** propose changing the behavior of method
partial applications `instance.instanceMethod`. It should remain possible
to partially bind a nonmutating method to its `self` parameter in this
fashion.

## Impact on existing code

This will break existing code that uses unapplied method references for
their curried signatures today. A blunt migration would be to replace
existing type references with nested closure literals, substituting:

```swift
let x = y.map(flip(Type.method))
```

with:

```swift
let x = y.map(flip({ instance in { arg in instance.method(arg) } }))
```

However, unapplied method references are currently rare in practice, due
to the limited usefulness of their curried signature today.

## Alternatives considered

If we do nothing else, we should close the undefined behavior hole by
banning unapplied references to mutating methods:

```swift
struct Type {
  mutating func mutatingMethod() {}
}
let f: Type.mutatingMethod // This should become an error
```

However, as discussed above, there are good systemic reasons to change the
behavior of all unapplied method references; not only would this fix the
undefined behavior hole, but also makes them a more generally useful feature.
