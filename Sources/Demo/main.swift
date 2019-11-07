import Prototype_RangeSet

//===----------------------------------------------------------------------===//
// Examples from proposal
//===----------------------------------------------------------------------===//

var numbers = Array(1...15)

// Find the indices of all the even numbers
let indicesOfEvens = numbers.indices(where: { $0.isMultiple(of: 2) })

// Perform an operation with just the even numbers
let sumOfEvens = numbers[indicesOfEvens].reduce(0, +)
print(sumOfEvens)
// sumOfEvens == 56

// You can gather the even numbers at the beginning
let rangeOfEvens = numbers.gather(indicesOfEvens, at: numbers.startIndex)
print(numbers[rangeOfEvens])
// numbers[rangeOfEvens] == [2, 4, 6, 8, 10, 12, 14]
print(numbers)
// numbers == [2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15]

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

// Iterate over a RangeSet by providing the initial collection
for i in streets.indices[indicesEndingInSon] {
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

// Gather all elements in range set to new index
let indicesOfShortStreets = streets.indices(where: { $0.count <= 7 })
let rangeOfShortStreets = streets.gather(indicesOfShortStreets, at: 3)

print(streets[..<rangeOfShortStreets.lowerBound])
print(streets[rangeOfShortStreets])
print(streets[rangeOfShortStreets.upperBound...])
