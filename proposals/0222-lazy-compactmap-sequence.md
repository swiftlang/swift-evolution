# Lazy CompactMap Sequence

* Proposal: [SE-0222](0222-lazy-compactmap-sequence.md)
* Authors: [TellowKrinkle](https://github.com/TellowKrinkle), [Johannes Weiß](https://github.com/weissi)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Rejected**
* Implementation: [apple/swift#14841](https://github.com/apple/swift/pull/14841)
* Decision Notes: [Rationale](https://forums.swift.org/t/se-0222-lazy-compactmap-sequence/14850/16)

## Introduction

Chaining multiple `.map()`s and `.filter()`s on a lazy collection leads
to suboptimal codegen, as well as large, painful type names.
To improve this, we propose adding a `LazyCompactMap{Sequence, Collection}`
type along with some overloads on the other lazy collection types' `.map(_:)`
and `.filter(_:)` functions which return this type to get better codegen
and shorter type names.

Swift-evolution thread: [Discussion thread topic for the proposal](https://forums.swift.org/t/introduce-lazy-version-of-compactmap/9835/1)

## Motivation

The current lazy system is very good for easily defining transforms on collections, but certain constructs can lead to less-than-optimal codegen.

For example, the code collection.map(map1).filter(filter1).map(map2).filter(filter2) will lead to code like this in the formIndex(after:) method:

```swift
do {
    do {
        collection.formIndex(after: &i)
    } while !filter1(map1(collection[i]))
} while !filter2(map2(map1(collection[i])))
```
while it could be represented with this more efficient single loop:
```swift
do {
    collection.formIndex(after: &i)
} while !filter1(map1(collection[i])) && !filter2(map2(map1(collection[i])))
```
Currently, you can get a single loop by instead using this compactMap:
```swift
collection.compactMap {
    let a = map1($0)
    guard filter1(a) else { return nil }
    let b = map2(a)
    guard filter2(b) else { return nil }
    return b
}
```
but this removes the nice composability of the chained map/filter combination.

The standard library recently got an override on LazyMapCollection and LazyFilterCollection
which combines multiple filters and maps in a row, however it does not work with alternating maps and filters.

## Proposed solution

Define a `LazyCompactMapCollection` collection (and sequence) which represents a compactMap.
Then, add overrides on `LazyMapCollection.filter`, `LazyFilterCollection.map`,
`Lazy*Collection.compactMap`, and `LazyCompactMapCollection.{filter, map}`
to return a `LazyCompactMapCollection` that combines all the maps and filters.

As an added bonus, you’ll never see a giant chain of
`LazyMapCollection<LazyFilterCollection<...>, ...>` again

## Detailed design

A new `LazyCompactMapCollection` and equivalent Sequence should be defined like so:
```swift
public struct LazyCompactMapCollection<Base: Collection, Element> {
	internal var _base: Base
	internal let _transform: (Base.Element) -> Element?

	internal init(_base: Base, transform: @escaping (Base.Element) -> Element?) {
		self._base = _base
		self._transform = transform
	}
}
```
with a very similar set of overrides to the current `LazyFilterCollection`

Then, the following extensions should be added (with equivalent ones for Lazy Sequences):
```swift
extension LazyMapCollection {
	public func compactMap<U>(_ transform: @escaping (Element) -> U?) -> LazyCompactMapCollection<Base, U> {
		let mytransform = self._transform
		return LazyCompactMapCollection<Base, U>(
			_base: self._base,
			transform: { transform(mytransform($0)) }
		)
	}

	public func filter(_ isIncluded: @escaping (Element) -> Bool) -> LazyCompactMapCollection<Base, Element> {
		let mytransform = self._transform
		return LazyCompactMapCollection<Base, Element>(
			_base: self._base,
			transform: {
				let transformed = mytransform($0)
				return isIncluded(transformed) ? transformed : nil
			}
		)
	}
}

extension LazyFilterCollection {
	public func compactMap<U>(_ transform: @escaping (Base.Element) -> U?) -> LazyCompactMapCollection<Base, U> {
		let mypredicate = self._predicate
		return LazyCompactMapCollection<Base, U>(
			_base: self._base,
			transform: { mypredicate($0) ? transform($0) : nil }
		)
	}

	public func map<U>(_ transform: @escaping (Base.Element) -> U) -> LazyCompactMapCollection<Base, U> {
		let mypredicate = self._predicate
		return LazyCompactMapCollection<Base, U>(
			_base: self._base,
			transform: { mypredicate($0) ? transform($0) : nil }
		)
	}
}

extension LazyCompactMapCollection {
	public func compactMap<U>(_ transform: @escaping (Element) -> U?) -> LazyCompactMapCollection<Base, U> {
		let mytransform = self._transform
		return LazyCompactMapCollection<Base, U>(
			_base: self._base,
			transform: {
				guard let halfTransformed = mytransform($0) else { return nil }
				return transform(halfTransformed)
			}
		)
	}

	public func map<U>(_ transform: @escaping (Element) -> U) -> LazyCompactMapCollection<Base, U> {
		let mytransform = self._transform
		return LazyCompactMapCollection<Base, U>(
			_base: self._base,
			transform: {
				guard let halfTransformed = mytransform($0) else { return nil }
				return transform(halfTransformed)
			}
		)
	}

	public func filter(_ isIncluded: @escaping (Element) -> Bool) -> LazyCompactMapCollection<Base, Element> {
		let mytransform = self._transform
		return LazyCompactMapCollection<Base, Element>(
			_base: self._base,
			transform: {
				guard let halfTransformed = mytransform($0), isIncluded(halfTransformed) else { return nil }
				return halfTransformed
			}
		)
	}
}
```

## Source compatibility

In Swift 5, while most code will work with the new extensions, code that relies on
the return type of `LazyCollection.compactMap(_:)` will break.

In addition, code like following code will break:
```swift
let array = [0, 1, 22]
let tmp = array.lazy.map(String.init).filter { $0.count == 1 }
let filtered: LazyFilterCollection<LazyMapCollection<[Int], String>> = tmp
```

However, this type of code is probably rare and similar code will already
be broken by the previously mentioned change that coalesces
`.filter(_:).filter(_:)` and `.map(_:).map(_:)`

## Effect on ABI stability

N/A

## Effect on API resilience

N/A

## Alternatives considered

The main alternative would be to not do this at all.  This alternative
isn't great, as it can be many times slower when the map/filter functions
do little work, as shown by [this test](https://gist.github.com/tellowkrinkle/818c8d9ce467f272c889bdd503784d63)

