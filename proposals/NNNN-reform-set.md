# Reform SetAlgebra

* Proposal: [SE-NNNN](NNNN-reform-set-algebra.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift#NNNNN](https://github.com/apple/swift/pull/NNNNN)

## Introduction

This proposal makes two changes to the `SetAlgebra` protocol, as well as corresponding changes to conforming types in the Standard Library (and Foundation):

- amend `insert` to return the index to the current element in the set, not the element itself; and
- split `SetAlgebra` into two protocols, for intensional and extensional sets.

These are **source breaking** changes. The primary motivation for breaking source now is ensuring that the ABI and API allow for future types and language features – specifically move-only types.

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/t/pitch-reform-setalgebra/17184)

## Motivation

### Preparation for move-only types

As described in [SE-0232](https://github.com/apple/swift-evolution/blob/master/proposals/0232-remove-customization-points.md), requirements on a protocol where an element is returned, but not removed, from a collection will be a problem for collections that want to be able to hold move-only types (because returning the element means it would have to be moved out of the collection, so it can't remain in the collection).
 There is one such method on the `SetAlgebra` protocol, `insert`:

```swift
/// Inserts the given element in the set if it is not already present.
///
/// If an element equal to `newMember` is already contained in the set, this
/// method has no effect.
///
/// - Returns: `(true, newMember)` if `newMember` was not contained in the
///   set. If an element equal to `newMember` was already contained in the
///   set, the method returns `(false, oldMember)`, where `oldMember` is the
///   element that was equal to `newMember`. In some cases, `oldMember` may
///   be distinguishable from `newMember` by identity comparison or some
///   other means.
@discardableResult
mutating func insert(_ newMember: Element) -> (inserted: Bool, memberAfterInsert: Element)
```

The operation returns the new value if an equal value wasn't already present; and _discards_ the new value and instead returns the existing old value if one was.

This will be a problem for a set of move-only types. If the inserted type is move-only, it could not possibly be both inserted into the set _and_ returned.

Contrast this with `Dictionary`'s `updateValue(_:forKey:)`, which replaces the existing value if there is one and returns that – something that would work fine for move-only types:

```swift
/// Updates the value stored in the dictionary for the given key, or adds a
/// new key-value pair if the key does not exist.
///
/// - Returns: The value that was replaced, or `nil` if a new key-value pair
///   was added.
@discardableResult
public mutating func updateValue(_ value: Value, forKey key: Key) -> Value?
```

`Set.insert` returns the new value for good reason. Imagine a use case where you want to intern strings – that is, make sure all occurrences of a string use the same buffer, to save memory and speed up equality comparison:

```swift
// start with some constant strings
var internedStrings: Set<String> = ["foo","bar"]

func intern(_ s: String) -> String {
  let (_,interned) = internedStrings.insert(s)
  return interned
}

// create a new string dynamically,
// with its own buffer
let s = String("oof".reversed())
// get back a constant string, freeing memory
// and enabling fast-path bitwise comparison
let i = intern(s)
```

The usual solution to avoid the move-only type problem is to return an index instead:

```swift
/// - Returns: `(true, newMember)` if `newMember` was not contained in the
///   set. If an element equal to `newMember` was already contained in the
///   set, the method returns `(false, oldMember)`, where `oldMember` is the
///   element that was equal to `newMember`. In some cases, `oldMember` may
///   be distinguishable from `newMember` by identity comparison or some
///   other means.
@discardableResult
mutating func insert(_ newMember: Element) -> (inserted: Bool, location: Index)
```

Move-only types can still be accessed via a borrow using the `subscript` operator. And the above interning code could be rewritten:

```swift
func intern(_ s: String) -> String {
  let (_,idx) = internedStrings.insert(s)
  // strings are copyable so this is still ok
  return internedStrings[idx]
}
```

This would be an appropriate solution, but for two problems:

1. It is source-breaking.
2. `SetAlgebra` doesn't conform to `Collection`

Which leads to...

### Countable vs Uncountable Sets

`SetAlgebra` deliberately does not conform to `Collection`. This is to allow for conformance by types that can provide all the functions of a set (union, intersection,constant-time contains) but that don't provide the ability to iterate over their elements.

`CharacterSet` is an example. You can check if a `CharacterSet` contains an entry, but it doesn't allow you to enumerate its contents because sometimes it defines membership by rules instead of by a list of elements. While it's technically possible to enumerate all the members of `CharacterSet.alphanumerics`, it doesn't make much sense to, so this feature isn't made available.

Unfortunately while this approach is ok for `CharacterSet`, this noble goal breaks down with other use cases, because some requirements still force the ability to enumerate.

For example, suppose you wanted to create a `PredicateSet`, a set that defined membership via a closure:

```swift
struct PredicateSet<Element> {
  let _predicate: (Element)->Bool

  init(_ predicate: @escaping (Element)->Bool) {
    _predicate = predicate
  }

  func contains(_ member: Element) -> Bool {
    return _predicate(member)
  }
}

let evenNumbers = PredicateSet { $0%2 == 0 }
evenNumbers.contains(42) // true
evenNumbers.contains(13) // false
```

You can conform this type to many of the requirements of `SetAlgebra`:

```swift
extension PredicateSet {
  // empty set contains nothing
  init() { self = PredicateSet { _ in false } }
  
  // union means both predicates return true
  func union(_ other: PredicateSet) -> PredicateSet {
    return PredicateSet {
      self._predicate($0) || other._predicate($0)
    }
  }
  
  // In-place operations can just be implemented
  // with self-assignment
}
```

But some of them are impossible to implement.

Some requirements effectively require the ability to enumerate the elements. `isEmpty` requires you to know `contains` will always return false. This is impossible for an opaque closure. `Equatable` conformance has the same problem.

`init<S : Sequence>(_ sequence: S) where S.Element == Element` requires the ability to initialize from a sequence. At a minimum, this would require that `Element` be `Equatable` (and even then, testing would take `O(n)` — `Comparable` or `Hashable` is probably the minimum). In most cases, this is taken care of by the confoming type (e.g. `Set` requires `Element: Hashable`). But a predicate set _might not_ need this requirement – the predicate the user supplied could use some other means. Ideally, `SetAlgebra` wouldn't impose any requirement on `Element`, but also wouldn't require an unconstrained `init` from a sequence. `ExpressibleByArrayLiteral` has the same problem.

`isSubset(of:)`, `isSuperset(of:)` and `isDisjoint(with:)` are kind of a combination of both problems.

## Proposed solution

Split `SetAlgebra` into two protocols:
- `IntensionalSet` will capture the minimal requirements of any type that 
can perform:
  - `contains` in O(log N) (see below)
  - `union`, `intersection`, and `symmetricDifference`
  - the in-place variants of these operations
  - no conformances
- `ExtensionalSet` will capture the rest:
  - and add `Collection` conformance
  - it will also add an `index(of: Element)` customization point
- `insert` will only be present on `ExtensionalSet`, and will return an `Index`
not an `Element`

`SetAlgebra` does not currently require a complexity guarantee for `contains`, but the lack of one is problematic for many generic algorithms built on top of it if they are to give their own guarantees.

## Detailed design

TBD

## Source compatibility

This is a source-breaking change.

The main driver is to ensure that `SetAlgeba` is ready for move-only types, which requires fixing `insert`. This will unavoidably break conformances. Once that possibility is admitted, it is not significantly worse to introduce a second break for implementors.

Some problems can be mitigated by keeping `SetAlgebra` as a typealias for `ExtensionalSet`. This will cover any extensions on `SetAlgebra`.

Callers of `insert` that make use of the `Element` return type will have to update their code to add the `subscript` call.

There are no instances of either of these in the compatability suite currently.

## Effect on ABI stability

This is an ABI-breaking change. The motivation is to get the ABI right for sets of move-only types, which cannot implement `insert` currently.

## Effect on API resilience

None.

## Alternatives considered

It is reasonable to argue that the generic `SetAlgebra` is not pulling its weight – that it isn't common to want to write generic algorithms using `SetAlgebra`. The lack of use in the compatability suite supports this.

Given this, it would be reasonable to leave it in its current state. But this still leaves the problem that conformance is impossible for move-only types, and we want `Set` to be able to contain move-only types.

Another alternative is to leave `SetAlgebra` as-is, and only conform `Set` to it when it contains copyable types. This could become a pain point if Swift increases it's set-like types to include ordered and sorted sets. Leaving the current protocol as-is would rule out move-only versions conforming to it forever following ABI stability.

### Naming

Instead of `IntensionalSet`/`ExtensionalSet`, we could go with `SetAlgebra` and `CountableSetAlgebra`. The main problem here is this exacerbates the source compatibility issues.

`UncountableSet` isn't a good alternative for `IntensionalSet` because it implies it is disjoint from `CountableSet`, rather than being a superset of countable sets.
