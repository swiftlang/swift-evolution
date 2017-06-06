# `return` consistency for single-expressions

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/nnnn-single-expression-optional-return.md)
* Author: [Adrian Zubarev](https://github.com/DevAndArtist)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

Any single-expression closure can omit the `return` statement. This proposal aims to make this feature more consistent in some other corners of the language.

Original swift-evolution thread: 
* [\[Pitch\] \[Stage-2\] `return` consistency for single-expressions](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170213/032153.html)
* [\[Pitch\] (Bofore Swift 3) Make `return` optional in computed properties for a single case](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/019260.html)

## Motivation

Closures can omit the `return` and have an inferred return type:

```swift
let _ = { 42 } // Type: () -> Int

let _ = [1,2,3].map { $0 * 5 } // T == Int
```

There are also value returning code blocks in the language that feel the same but are inconsistent to the mentioned feature:

```swift
// Read-write computed property:
var integer: Int { 
	get { return 2016 } 
	set { /* do some work */ } 
} 

// Read-only computed property:
var string: String { return "hello swift" } 

// Function:
func pi() -> Double {
	return 3.141
}

// Read-Write subscript:
subscript(index: Int) -> Int {
    get { return index % 2 }
    set { /* do some work */ }
}

// Read-only subscript:
subscript(index: Int) -> Int { return index * 2 }
```

## Proposed solution

Make `return` optional for the following top level code blocks that only contain a single expression:

* *variable-declaration*
* *getter-setter-block*
* *getter-clause*
* *function-body*
* *subscript-declaration*

That will allow us to rewrite the above example to:

```swift
// Read-Write computed property:
var integer: Int { 
	get { 2016 } 
	...
} 

// Read-only computed property:
var string: String { "hello swift" } 

// Function:
func pi() -> Double { 3.141 }

// Read-Write subscript:
subscript(index: Int) -> Int {
    get { index % 2 }
    ...
}

// Read-only subscript:
subscript(index: Int) -> Int { index * 2 }
```

**Possible real world example:**

```swift
// Today
public struct Character {
	
	public let source: Module.Source
	private let _pointer: UnsafePointer<Swift.Character>
	
	public var value: Swift.Character {
		return self._pointer.pointee
	}
	...
}

// Rewritten:
public struct Character {
	...
	public var value: Swift.Character { self._pointer.pointee }
	...
}
```


## Impact on existing code

None, this change will only relax some existing rules.

## Alternatives considered

Leave this as is and live with such inconsistency.
