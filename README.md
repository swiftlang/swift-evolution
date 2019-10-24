# RangeSet

A `RangeSet` is a set of ranges. 
You can form a range set over any `Comparable` type. 
This library includes the `RangeSet` type and a variety of related collection operations.

```swift
var numbers = Array(1...15)

// Find the indices of all the multiples of three
let indicesOfThree = numbers.indices(where: { $0.isMultiple(of: 3) })

// Perform an operation with just those multiples
let sumOfThrees = numbers[indicesOfThree].reduce(0, +)
// sumOfThrees == 45

// You can gather the multiples of 3 at the beginning
let rangeOfThree = numbers.gather(indicesOfThree, justBefore: 0)
// numbers[rangeOfThree] == [3, 6, 9, 12, 15]
// numbers == [3, 6, 9, 12, 15, 1, 2, 4, 5, 7, 8, 10, 11, 13, 14]

// Reset `numbers`
numbers = Array(1...15)

// You can also build range sets by hand using array literals...
let myRangeSet: RangeSet = [0..<5, 10..<15]
print(Array(numbers[myRangeSet]))
// Prints [1, 2, 3, 4, 5, 11, 12, 13, 14, 15]

// ...or by using set operations
let evenThrees = indicesOfThree.intersection(
    numbers.indices(where: { $0.isMultiple(of: 2) }))
print(Array(numbers[evenThrees]))
// Prints [6, 12]
```

## Usage

You can add this library as a dependency to any Swift package. 
Add this line to the `dependencies` parameter in your Package.swift file:

```swift
.package(
    url: "https://github.com/natecook1000/swift-evolution",
    .branch("rangeset_and_friends")),
```

Add `"Prototype_RangeSet"` as a dependency for your targets that will use the library, 
and then use `import Prototype_RangeSet` to make the library available in any Swift file.

Alternatively, you can download the package from 
[https://github.com/natecook1000/swift-evolution/tree/rangeset_and_friends]() 
and experiment with the included `demo` target.

