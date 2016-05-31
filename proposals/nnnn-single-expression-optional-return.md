# `return` consistency for single-expressions

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/nnnn-single-expression-optional-return.md)
* Author(s): [Adrian Zubarev](https://github.com/DevAndArtist)
* Status: **[Awaiting review](#rationale)**
* Review manager: TBD

## Introduction

Any single-expression closure can omit the `return` statement and have an inferred return type. This proposal aims to make this feature consistent everywhere in the language.

Original swift-evolution thread: [\[Pitch\] Make `return` optional in computed properties for a single case](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160523/019260.html)

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

// Guard-statement:
func test(boolean: Bool) -> String {
	guard boolean else { return "false" }
	return "true"
}
```

## Proposed solution

Make `return` optional and infer return type for single-expressions everywhere in the language:

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

// Guard-statement:
func test(boolean: Bool) -> String {
	guard boolean else { "false" }
	return "true"
}
```

## Impact on existing code

None, this change will only relax some existing rules.

## Alternatives considered

Leave this as is and live with such inconsistency.

-------------------------------------------------------------------------------

# Rationale

On [Date], the core team decided to **(TBD)** this proposal.
When the core team makes a decision regarding this proposal,
their rationale for the decision will be written here.
