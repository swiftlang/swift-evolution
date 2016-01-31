# Runtime-safe array subscripting

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/master/proposals/NNNN-name.md)
* Author(s): [Rudolf Adamkovič](https://github.com/salutis)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Add an alternative way to subscript arrays where out-of-bounds runtime errors are converted to `nil`.

Swift-evolution thread: [Optional safe subscripting for arrays](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160111/006826.html)

## Proposed solution

Allow to safely index into arrays returning `Element?`:

```swift
// Sample data
var array = [0, 1, 2]
	
// Setting values
array[ifExists: 0] // same as array[0]
array[ifExists: 3] // out of bounds, evaluates to nil

// Getting values
array[ifExists: 0] = 42 // same as array[0] = 42
array[ifExists: 3] = 42 // out of bounds, no operation
```

## Detailed design

Include an alternative `subscript` with the `ifExists` label:

```swift
subscript(ifExists index: Index) -> Element? {
    get {
        return self.indices ~= index ? self[index] : nil 
    }
    set {
        if self.indices ~= index {
            self[index] = newValue
        }
    }
}
```

## Impact on existing code

No existing code is affected.

## Alternatives considered

* Extend the `CollectionType` or `Indexable` protocol instead the `Array`
