# Disallow redundant `Any<...>` constructs

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author: [Adrian Zubarev](https://github.com/DevAndArtist)
* Status: [Awaiting review](#rationale)
* Review manager: TBD

## Introduction

This is a follow up proposal to [SE-0095](https://github.com/apple/swift-evolution/blob/master/proposals/0095-any-as-existential.md), if it will be accepted for Swift 3. The current concept of `Any<...>` introduced in SE-0095 will allow creation of redundant types like `Any<A> == A`. I propose to disallow such redundancy in Swift 3 to prevent breaking changes in a future version of Swift.

Swift-evolution thread: [\[Proposal\] Disallow redundant `Any<...>` constructs]()

## Motivation

If SE-0095 will be accepted there will be future proposals to enhance its capabilities. Two of these will be **Any-type requirement** (where *type* could be `class`, `struct` or `enum`) and **Class requirement**. Without any restrictions these will introduce more redundancy. 

As said before it is possible to create redundant types like `Any<A> == A` or endless shadowed redundant nesting:

```swift
typealias A_1 = Any<A>
typealias A_2 = Any<A_1>
typealias A_3 = Any<A_2>
/* and so on */
```

This proposal should ban redundancy right from the beginning. If there might be any desire to relax a few things, it won't introduce any breaking changes for `Any<...>` existential.

## Proposed solution

1. If empty `Any<>` won't be disallowed in SE-0095, we should disallow nesting empty `Any<>` inside of `Any<...>`.

2. Disallow nesting `Any` (type refers to current `typealias Any = protocol<>`) inside of `Any<...>`.

3. Disallow `Any<...>` containing a single `Type` like `Any<Type>`.

	The first three rules will ban constructs like `Any<Any<>, Type>` or `Any<Any, Type>` and force the developer to use `Type` instead.

4. Disallow nesting a single `Any<...>` inside another `Any<...>`.
	* e.g. `Any<Any<FirstType, SecondType>>`

5. Disallow same type usage like `Any<A, A>` or `Any<A, B, A>` and force the developer to use `A` or `Any<A, B>` if `A` and `B` are distinct.

6. Disallow forming redundant types when the provided constraints are not independent.
	
	```swift
	// Right now `type` can only be `protocol` but in the future Any<...> 
	// could also allow `class`, `struct` and `enum`.
	// In this example `B` and `C` are distinct.
	type A: B, C {} 
	
	// all following types are equivalent to `A`
	Any<A, Any<B, C>>
	Any<Any<A, B>, C>
	Any<Any<A, C>, B>
	Any<A, B, C>
	Any<A, B>
	Any<A, C>
	```
	
	* If all contraints form a known `Type` provide a `Fix-it` error depending on the current context. If there is more than one `Type`, provide all alternatives to the developer.

	* Using `Any<...>` in a generic context might not produce a `Fix-it` error:

		```swift
		protocol A {}
		protocol B {}
		protocol C: A, B {}
		
		// there is no need for `Fix-it` in such a context
		func foo<T: Any<A, B>>(value: T) {}
		```

## Impact on existing code

These changes will break existing code. Projects abusing `Any<...>` to create redundant types should be reconsidered of usings the equivalent `Type` the compiler would infer. One would be forced to use `A` instead of `Any<A>` for example. A `Fix-it` error message can help the developer to migrate his project.

## Alternatives considered

* Leave redundancy as-is for Swift 3 and live with it.
* Deprecate redundancy in a future version of Swift, which will introduce breaking changes.

# Rationale

On [Date], the core team decided to (TBD) this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
