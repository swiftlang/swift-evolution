# Rename `T.Type`

* Proposal: [SE-0126](0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)
* Authors: [Adrian Zubarev](https://github.com/DevAndArtist), [Anton Zhilin](https://github.com/Anton3)
* Status: **Revision**
* Review manager: [Chris Lattner](http://github.com/lattner)
* Revision: 2
* Previous Revisions: [1](https://github.com/apple/swift-evolution/blob/83707b0879c83dcde778f8163f5768212736fdc2/proposals/0126-refactor-metatypes-repurpose-t-dot-self-and-mirror.md)

## Introduction

This proposal renames the current metatype `T.Type` notation and the global function from **SE-0096** to match the changes.

Swift-evolution threads: 

* [\[Pitch\] Rename `T.Type`]()
* [\[Review\] SE-0126: Refactor Metatypes, repurpose T[dot]self and Mirror]()
* [\[Proposal\] Refactor Metatypes, repurpose T[dot]self and Mirror](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160718/024772.html) 
* [\[Discussion\] Seal `T.Type` into `Type<T>`](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160704/023818.html)

## Motivation

In Swift metatypes have the following notation: **`T.Type`**

As already showed in **SE-0096** and **SE-0090** the Swift community strongly is in favor of (re)moving magical intstance or type properties.

* **SE-0096** moves `instanceOfT.dynamicType` to `type<T>(of: T) -> T.Type`.

* **SE-0090** aims to remove `.self` completely.

We propose to rename `T.Type` to a generic-like notation `Metatype<T>`. To be able to achieve this notation we have to resolve a few issues first.

### Known issues of metatypes:

Assume this function that checks if an `Int` type conforms to a specific protocol. This check uses current model of metatypes combined in a generic context:

```swift
func intConforms<T>(to _: T.Type) -> Bool {
   return Int.self is T.Type
}

intConforms(to: CustomStringConvertible.self) //=> false

Int.self is CustomStringConvertible.Type      //=> true
```

> [1] When `T` is a protocol `P`, `T.Type` is the metatype of the protocol type itself, `P.Protocol`. `Int.self` is not `P.self`.
>
> [2] There isn't a way to generically expression `P.Type` **yet**.
>
> [3] The syntax would have to be changed in the compiler to get something that behaves like `.Type` today.
>
> Written by Joe Groff: [\[1\]](https://twitter.com/jckarter/status/754420461404958721) [\[2\]](https://twitter.com/jckarter/status/754420624261472256)  [\[3\]](https://twitter.com/jckarter/status/754425573762478080)

A possible workaround might look like the example below, but does not allow to decompose `P.Type`:

```swift
func intConforms<T>(to _: T.Type) -> Bool {
  return Int.self is T
}

intConforms(to: CustomStringConvertible.Type.self) //=> true
```

We can extend this issue and find the second problem by checking against the metatype of `Any`:

```swift
func intConforms<T>(to _: T.Type) -> Bool {
	return Int.self is T
}

intConforms(to: Any.Type.self) //=> true

intConforms(to: Any.self)      //=> true

Int.self is Any.Type           //=> Always true
```

When using `Any` the compiler does not require `.Type` at all and returns `true` for both variations.

The third issue will show itself whenever we would try to check protocol relationship with another protocol. Currently there is no way (that we know of) to solve this problem:

```swift
protocol P {}
protocol R : P {}

func rIsSubtype<T>(of _: T.Type) -> Bool {
	return R.self is T
}

rIsSubtype(of: P.Type.self) //=> false

R.self is Any.Type //=> Always true
R.self is P.Type   //=> true
R.self is R.Type   //=> true
```

We also believe that this issue is the reason why the current global functions `sizeof`, `strideof` and `alignof` make use of generic `<T>(_: T.Type)` declaration notation instead of `(_: Any.Type)`.

## Proposed solution

* Rename any occurrence of `T.Type` and `T.Protocol` to `Metatype<T>`.
* Revise metatypes internally. 
* When `T` is a protocol, `T.self` should always return an instance of `Metatype<T>` (old `T.Type`) and never a `T.Protocol`. Furthermore, metatypes should reflect the same type relationship behavior like the actual types themselves. 
* To match the correct meaning and usage of the noun 'Metatype' from this proposal, we also propose to rename the global function from **SE-0096**:

	* before: `public func type<T>(of instance: T) -> T.Type`
	* after: `public func metatype<T>(of instance: T) -> Metatype<T>`

### Examples:

```swift
protocol P {}
protocol R : P {}
class A : P {}
class B : A, R {}

func `is`<T>(metatype: Metatype<Any>, also _: Metatype<T> ) -> Bool {
	return metatype is Metatype<T>
}

`is`(metatype: R.self, also: Any.self) //=> true | Currently: false
`is`(metatype: R.self, also: P.self)   //=> true | Currently: false
`is`(metatype: R.self, also: R.self)   //=> true

`is`(metatype: B.self, also: Any.self) //=> true | Currently: false
`is`(metatype: B.self, also: P.self)   //=> true | Currently: false
`is`(metatype: B.self, also: R.self)   //=> true | Currently: false
`is`(metatype: B.self, also: A.self)   //=> true
`is`(metatype: B.self, also: B.self)   //=> true

func cast<T>(metatype: Metatype<Any>, to _: Metatype<T>) -> Metatype<T>? {
	return metatype as? Metatype<T>
}

cast(metatype: R.self, to: Any.self)     //=> an Optional<Metatype<Any>> | Currently: nil
cast(metatype: R.self, to: P.self)       //=> an Optional<Metatype<P>>   | Currently: nil
cast(metatype: R.self, to: R.self)       //=> an Optional<Metatype<R>>   | Currently: an Optional<R.Protocol>

let anyR: Any.Type = R.self
let r = cast(metatype: anyR, to: R.self) //=> an Optional<Metatype<R>>   | Currently: an Optional<R.Protocol>

cast(metatype: B.self, to: Any.self)     //=> an Optional<Metatype<Any>> | Currently: nil
cast(metatype: B.self, to: P.self)       //=> an Optional<Metatype<P>>   | Currently: nil
cast(metatype: B.self, to: R.self)       //=> an Optional<Metatype<R>>   | Currently: nil
cast(metatype: B.self, to: A.self)       //=> an Optional<Metatype<A>>
cast(metatype: B.self, to: B.self)       //=> an Optional<Metatype<B>>

let pB: P.Type = B.self
let b = cast(metatype: pB, to: B.self)   //=> an Optional<Metatype<B>>
```

## Impact on existing code

This is a source-breaking change that can be automated by a migrator. Any occurrence of `T.Type` or `T.Protocol` will be simply renamed to `Metatype<T>`.

## Alternatives considered

* Alternatively it's reasonable to consider to rename `T.self` to `T.metatype`.
* It was considered to reserve `Type<T>` for different usage in the future.
