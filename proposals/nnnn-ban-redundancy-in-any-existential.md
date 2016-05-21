# Disallow redundant `any<...>` constructs

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author: [Adrian Zubarev](https://github.com/DevAndArtist)
* Status: [Awaiting review](#rationale)
* Review manager: TBD

## Introduction

This is a follow up proposal to [SE-0095](https://github.com/apple/swift-evolution/blob/master/proposals/0095-any-as-existential.md), if it will be accepted for Swift 3. The current concept of `any<...>` introduced in SE-0095 will allow creation of redundant types like `any<A> == A`. I propose to disallow such redundancy in Swift 3 to prevent breaking changes in a future version of Swift.

Swift-evolution thread: [\[Proposal\] Disallow redundant `any<...>` constructs](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160516/018280.html)

## Motivation

If SE-0095 will be accepted there will be future proposals to enhance its capabilities. Two of these will be **Any-type requirement** (where *type* could be `class`, `struct` or `enum`) and **Class requirement**. Without any restrictions these will introduce more redundancy. 

As said before it is possible to create redundant types like `any<A> == A` or endless shadowed redundant nesting:

```swift
typealias A_1 = any<A>
typealias A_2 = any<A_1>
typealias A_3 = any<A_2>
/* and so on */
```

This proposal should ban redundancy right from the beginning. If there might be any desire to relax a few things, it won't introduce any breaking changes for `any<...>` existential.

## Proposed solution

1. If empty `any<>` won't be disallowed in SE-0095, we should disallow nesting empty `any<>` inside of `any<...>`.

2. Disallow nesting `Any` (type refers to current `typealias Any = protocol<>`) inside of `any<...>`.

3. Disallow `any<...>` containing a single `Type` like `any<Type>`, except for **Any-type requirement** like for example `any<class>`.

	The first three rules will ban constructs like `any<any<>, Type>` or `any<Any, Type>` and force the developer to use `Type` instead.

4. Disallow nesting a single `any<...>` inside another `any<...>`.
	* e.g. `any<any<FirstType, SecondType>>`

5. Disallow same type usage like `any<A, A>` or `any<A, B, A>` and force the developer to use `A` or `any<A, B>` if `A` and `B` are distinct.

6. Disallow forming redundant types when the provided constraints are not independent.
	
	```swift
	// Right now `type` can only be `protocol` but in the future any<...> 
	// could also allow `class`, `struct` and `enum`.
	// In this example `B` and `C` are distinct.
	type A: B, C {} 
	
	// all following types are equivalent to `A`
	any<A, any<B, C>>
	any<any<A, B>, C>
	any<any<A, C>, B>
	any<A, B, C>
	any<A, B>
	any<A, C>
	```
	
	* If all contraints form a known `Type` provide a `Fix-it` error depending on the current context. If there is more than one `Type`, provide all alternatives to the developer.

	* Using `any<...>` in a generic context might not produce a `Fix-it` error:

		```swift
		protocol A {}
		protocol B {}
		protocol C: A, B {}
		
		// there is no need for `Fix-it` in such a context
		func foo<T: any<A, B>>(value: T) {}
		```

## Impact on existing code

These changes will break existing code. Projects abusing `any<...>` to create redundant types should be reconsidered of using the equivalent `Type` the compiler would infer. One would be forced to use `A` instead of `any<A>` for example. A `Fix-it` error message can help the developer to migrate his project.

## Alternatives considered

* Leave redundancy as-is for Swift 3 and live with it.
* Deprecate redundancy in a future version of Swift, which will introduce breaking changes.

# Rationale

On [Date], the core team decided to (TBD) this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
