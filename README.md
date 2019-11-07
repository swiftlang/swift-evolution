# RangeSet

A `RangeSet` is a set of ranges. 
You can form a range set over any `Comparable` type. 
This library includes the `RangeSet` type and a variety of related collection operations.

```swift
var numbers = Array(1...15)

// Find the indices of all the even numbers
let indicesOfEvens = numbers.indices(where: { $0.isMultiple(of: 2) })

// Perform an operation with just the even numbers
let sumOfEvens = numbers[indicesOfEvens].reduce(0, +)
// sumOfEvens == 56

// You can gather the even numbers at the beginning
let rangeOfEvens = numbers.gather(indicesOfEvens, justBefore: numbers.startIndex)
// numbers[rangeOfEvens] == [2, 4, 6, 8, 10, 12]
// numbers == [2, 4, 6, 8, 10, 12, 1, 3, 5, 7, 9, 11, 13, 15]

// Reset `numbers`
numbers = Array(1...15)

// You can also build range sets by hand using array literals...
let notTheMiddle: RangeSet = [0..<5, 10..<15]
print(Array(numbers[notTheMiddle]))
// Prints [1, 2, 3, 4, 5, 11, 12, 13, 14, 15]

// ...or by using set operations
let smallEvens = indicesOfEvens.intersection(
    numbers.indices(where: { $0 < 10 }))
print(Array(numbers[smallEvens]))
// Prints [2, 4, 6, 8]
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

