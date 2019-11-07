import XCTest
import Prototype_RangeSet
import TestHelpers

let letterString = "ABCdefGHIjklMNOpqrStUvWxyz"
let lowercaseLetters = letterString.filter { $0.isLowercase }
let uppercaseLetters = letterString.filter { $0.isUppercase }

extension Collection {
    func every(_ n: Int) -> [Element] {
        sequence(first: startIndex) { i in
            self.index(i, offsetBy: n, limitedBy: self.endIndex)
        }.map { self[$0] }
    }
}

final class CollectionExtensionsTests: XCTestCase {
    func testIndicesWhere() {
        let a = [1, 2, 3, 4, 3, 3, 4, 5, 3, 4, 3, 3, 3]
        let indices = a.indices(of: 3)
        XCTAssertEqual(indices, [2..<3, 4..<6, 8..<9, 10..<13])
        
        let allTheThrees = a[indices]
        XCTAssertEqual(allTheThrees.count, 7)
        XCTAssertTrue(allTheThrees.allSatisfy { $0 == 3 })
        XCTAssertEqual(Array(allTheThrees), Array(repeating: 3, count: 7))
        
        let lowerIndices = letterString.indices(where: { $0.isLowercase })
        let lowerOnly = letterString[lowerIndices]
        XCTAssertEqual(lowerOnly, lowercaseLetters)
        XCTAssertEqual(lowerOnly.reversed(), lowercaseLetters.reversed())
        
        let upperOnly = letterString[lowerIndices.inverted(within: letterString)]
        XCTAssertEqual(upperOnly, uppercaseLetters)
        XCTAssertEqual(upperOnly.reversed(), uppercaseLetters.reversed())
    }
    
    func testRemoveAllRangeSet() {
        var a = [1, 2, 3, 4, 3, 3, 4, 5, 3, 4, 3, 3, 3]
        let indices = a.indices(of: 3)
        a.removeAll(at: indices)
        XCTAssertEqual(a, [1, 2, 4, 4, 5, 4])

        var numbers = Array(1...20)
        numbers.removeAll(at: [2..<5, 10..<15, 18..<20])
        XCTAssertEqual(numbers, [1, 2, 6, 7, 8, 9, 10, 16, 17, 18])
        
        var str = letterString
        let lowerIndices = str.indices(where: { $0.isLowercase })
        
        let upperOnly = str.removingAll(at: lowerIndices)
        XCTAssertEqual(upperOnly, uppercaseLetters)

        str.removeAll(at: lowerIndices)
        XCTAssertEqual(str, uppercaseLetters)
    }
    
    func testGatherRangeSet() {
        // Move before
        var numbers = Array(1...20)
        let range1 = numbers.gather([10..<15, 18..<20], at: 4)
        XCTAssertEqual(range1, 4..<11)
        XCTAssertEqual(numbers, [
            1, 2, 3, 4,
            11, 12, 13, 14, 15,
            19, 20,
            5, 6, 7, 8, 9, 10, 16, 17, 18])
        
        // Move to start
        numbers = Array(1...20)
        let range2 = numbers.gather([10..<15, 18..<20], at: 0)
        XCTAssertEqual(range2, 0..<7)
        XCTAssertEqual(numbers, [
            11, 12, 13, 14, 15,
            19, 20,
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 17, 18])
        
        // Move to end
        numbers = Array(1...20)
        let range3 = numbers.gather([10..<15, 18..<20], at: 20)
        XCTAssertEqual(range3, 13..<20)
        XCTAssertEqual(numbers, [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 17, 18,
            11, 12, 13, 14, 15,
            19, 20,
        ])
        
        // Move to middle of selected elements
        numbers = Array(1...20)
        let range4 = numbers.gather([10..<15, 18..<20], at: 14)
        XCTAssertEqual(range4, 10..<17)
        XCTAssertEqual(numbers, [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
            11, 12, 13, 14, 15,
            19, 20,
            16, 17, 18])

        // Move none
        numbers = Array(1...20)
        let range5 = numbers.gather([], at: 10)
        XCTAssertEqual(range5, 10..<10)
        XCTAssertEqual(numbers, Array(1...20))
    }
    
    func testShiftRange() {
        let a = ["A", "B", "C", "D", "E", "F"]
        for lowerBound in a.indices {
            for upperBound in lowerBound..<a.endIndex {
                for destination in a.indices {
                    var b = a
                    let source = lowerBound..<upperBound
                    let result = b.shift(from: source, to: destination)
                    XCTAssertEqual(b[result], a[source])

                    // Compare result with RangeSet-based move
                    var c = a
                    _ = c.gather(RangeSet(source), at: destination)
                    XCTAssertEqual(b, c)
                    
                    // Manual comparison
                    if destination < source.lowerBound {
                        let c = [
                            a[..<destination],
                            a[source],
                            a[destination..<source.lowerBound],
                            a[source.upperBound...],
                        ].joined()
                        XCTAssertEqual(b, c)
                    }
                    else if destination >= source.upperBound {
                        let c = [
                            a[..<source.lowerBound],
                            a[source.upperBound..<destination],
                            a[source],
                            a[destination...],
                        ].joined()
                        XCTAssertEqual(b, c)
                    }
                    else {
                        XCTAssertEqual(b, a)
                    }
                }
            }
        }

        // closed range
        var b = a
        XCTAssertEqual(b.shift(from: 2...3, to: 1), 1..<3)
        XCTAssertEqual(b, ["A", "C", "D", "B", "E", "F"])
    }
    
    func testShiftIndividual() {
        let a = ["A", "B", "C", "D", "E", "F"]
        for source in a.indices {
            for dest in a.startIndex...a.endIndex {
                var b = a
                var c = a
                let rs = RangeSet(source, within: a)
                let resultingIndex = b.shift(from: source, to: dest)
                c.gather(rs, at: dest)
                XCTAssertEqual(a[source], b[resultingIndex])
                XCTAssertEqual(b, c)
            }
        }
    }
    
    func testGatherPredicate() {
        for length in 0..<11 {
            let initial = Array(0..<length)
            
            for destination in 0..<length {
                for modulus in 1...5 {
                    let f: (Int) -> Bool = { $0.isMultiple(of: modulus) }
                    let notf = { !f($0) }
                    
                    var array = initial
                    var range = array.gather(at: destination, where: f)
                    XCTAssertEqual(array[range], initial.filter(f))
                    XCTAssertEqual(
                        array[..<range.lowerBound] + array[range.upperBound...],
                        initial.filter(notf))

                    array = initial
                    range = array.gather(at: destination, where: notf)
                    XCTAssertEqual(array[range], initial.filter(notf))
                    XCTAssertEqual(
                        array[..<range.lowerBound] + array[range.upperBound...],
                        initial.filter(f))
                }
            }
        }
    }
    
    func testDiscontiguousSliceSlicing() {
        let initial = 1...100
        
        // Build an array of ranges that include alternating groups of 5 elements
        // e.g. 1...5, 11...15, etc
        let rangeStarts = initial.indices.every(10)
        let rangeEnds = rangeStarts.compactMap {
            initial.index($0, offsetBy: 5, limitedBy: initial.endIndex)
        }
        let ranges = zip(rangeStarts, rangeEnds).map(Range.init)
        
        // Create a collection of the elements represented by `ranges` without
        // using `RangeSet`
        let chosenElements = ranges.map { initial[$0] }.joined()
        
        let set = RangeSet(ranges)
        let discontiguousSlice = initial[set]
        XCTAssertEqual(discontiguousSlice, chosenElements)
        
        for (chosenIdx, disIdx) in zip(chosenElements.indices, discontiguousSlice.indices) {
            XCTAssertEqual(chosenElements[chosenIdx...], discontiguousSlice[disIdx...])
            XCTAssertEqual(chosenElements[..<chosenIdx], discontiguousSlice[..<disIdx])
            for (chosenUpper, disUpper) in
                zip(chosenElements.indices[chosenIdx...], discontiguousSlice.indices[disIdx...])
            {
                XCTAssertEqual(
                    chosenElements[chosenIdx..<chosenUpper],
                    discontiguousSlice[disIdx..<disUpper])
            }
        }
    }
    
    func testNoCopyOnWrite() {
        var numbers = COWLoggingArray(1...20)
        let copyCount = COWLoggingArray_CopyCount
        
        _ = numbers.gather([10..<15, 18..<20], at: 4)
        XCTAssertEqual(copyCount, COWLoggingArray_CopyCount)

        numbers.removeAll(at: [2..<5, 10..<15, 18..<20])
        XCTAssertEqual(copyCount, COWLoggingArray_CopyCount)
    }
}
