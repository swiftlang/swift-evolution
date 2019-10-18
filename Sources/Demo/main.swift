import Prototype_RangeSet

//===----------------------------------------------------------------------===//
// Examples from proposal
//===----------------------------------------------------------------------===//

var numbers = Array(1...15)

// Find the indices of all the multiples of three
let indicesOfThree = numbers.indices(where: { $0.isMultiple(of: 3) })

// Perform an operation with just those multiples
let sumOfThrees = numbers[indicesOfThree].reduce(0, +)
print(sumOfThrees)
// sumOfThrees == 45

// Move the multiples of 3 to the beginning
let rangeOfThree = numbers.move(from: indicesOfThree, insertingAt: 0)
print(numbers[rangeOfThree])
print(numbers)
// numbers[rangeOfThree] == [3, 6, 9, 12, 15]
// numbers == [3, 6, 9, 12, 15, 18, 1, 2, 4, 5, 7, 8, 10, 11, 13, 14]

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



//===----------------------------------------------------------------------===//
// More examples
//===----------------------------------------------------------------------===//

var streets = [
    "Albemarle",
    "Brandywine",
    "Chesapeake",
    "Davenport",
    "Ellicott",
    "Fessenden",
    "Garrison",
    "Harrison",
    "Ingomar",
    "Jenifer",
    "Kenawha",
    "Legation",
    "Morrison",
    "Northampton",
    "Oliver",
    "Patterson",
    "Quesada",
    "Rittenhouse",
    "Stuyvesant",
    "Tennyson",
]

func resetStreets() { streets.sort() }

//===----------------------------------------------------------------------===//
// High-level API
//===----------------------------------------------------------------------===//

// Find all elements matching a predicate
let indicesEndingInSon = streets.indices(where: { $0.suffix(3) == "son" })
print(indicesEndingInSon)

// Iterate over RangeSet of strideable value
for i in indicesEndingInSon.elements {
    print(streets[i])
}

// Access the elements described by the range set
let streetsEndingInSon = streets[indicesEndingInSon]
print(streetsEndingInSon)
print(Array(streetsEndingInSon))

let streetsNotEndingInSon = streets[indicesEndingInSon.inverted(within: streets)]
print(Array(streetsNotEndingInSon))

// Remove all elements in range set
var streetsWithoutSon = streets
streetsWithoutSon.removeAll(at: indicesEndingInSon)
print(streetsWithoutSon)

// Move/gather all elements in range set to new index
let indicesOfShortStreets = streets.indices(where: { $0.count <= 7 })
let rangeOfShortStreets = streets.move(from: indicesOfShortStreets, insertingAt: 3)

print(streets[..<rangeOfShortStreets.lowerBound])
print(streets[rangeOfShortStreets])
print(streets[rangeOfShortStreets.upperBound...])

//===----------------------------------------------------------------------===//
// Low-ish-level API
//===----------------------------------------------------------------------===//

// Existing partition by length
resetStreets()
_ = streets.partition(by: { $0.count <= 7})
print(streets)

// Stable partition by length
resetStreets()
_ = streets.stablePartition(by: { $0.count <= 7})
print(streets)

// Rotation
resetStreets()
let jeniferIndex = streets.firstIndex(of: "Jenifer")!
streets.rotate(shiftingToStart: jeniferIndex)
print(streets)

