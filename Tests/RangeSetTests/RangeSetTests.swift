import XCTest
import Prototype_RangeSet
import TestHelpers

let source: RangeSet = [1..<5, 8..<10, 20..<22, 27..<29]

func buildRandomRangeSet(iterations: Int = 100) -> RangeSet<Int> {
    var set = RangeSet<Int>()
    for _ in 0..<100 {
        var (a, b) = (Int.random(in: -100...100), Int.random(in: -100...100))
        if (a > b) { swap(&a, &b) }
        if Double.random(in: 0..<1) > 0.3 {
            set.insert(a..<b)
        } else {
            set.remove(a..<b)
        }
    }
    return set
}

final class RangeSetTests: XCTestCase {
    func testCollectionConformance() {
        let elements = source.elements
        XCTAssertEqual(elements.count, 10)
        XCTAssertEqual(elements, [1, 2, 3, 4, 8, 9, 20, 21, 27, 28])
        XCTAssertEqual(elements.reversed(), [28, 27, 21, 20, 9, 8, 4, 3, 2, 1])
        XCTAssertEqual(source.elements(within: 0..<100), elements)

        let count = elements.distance(from: elements.startIndex, to: elements.endIndex)
        XCTAssertEqual(count, 10)
        let i = elements.firstIndex(of: 4)!
        let j = elements.firstIndex(of: 20)!
        let d = elements.distance(from: i, to: j)
        let i1 = elements.index(j, offsetBy: -d)
        let j1 = elements.index(i, offsetBy: d)
        XCTAssertEqual(i, i1)
        XCTAssertEqual(j, j1)
        
        let reversedSet = Array(elements.reversed())
        let reversedArray = Array(Array(elements).reversed())
        XCTAssertEqual(reversedSet, reversedArray)
    }

    func testInsertions() {
        do {
            // Overlap from middle to middle
            var s = source
            s.insert(3..<21)
            XCTAssertEqual(s.ranges, [1..<22, 27..<29])
        }

        do {
            // insert in middle
            var s = source
            s.insert(13..<15)
            XCTAssertEqual(s.ranges, [1..<5, 8..<10, 13..<15, 20..<22, 27..<29])
        }

        do {
            // extend a range
            var s = source
            s.insert(22..<25)
            XCTAssertEqual(s.ranges, [1..<5, 8..<10, 20..<25, 27..<29])
        }

        do {
            // extend at beginning of range
            var s = source
            s.insert(17..<20)
            XCTAssertEqual(s.ranges, [1..<5, 8..<10, 17..<22, 27..<29])
        }

        do {
            // insert at the beginning
            var s = source
            s.insert(-10 ..< -5)
            XCTAssertEqual(s.ranges, [-10 ..< -5, 1..<5, 8..<10, 20..<22, 27..<29])
        }

        do {
            // insert at the end
            var s = source
            s.insert(35 ..< 40)
            XCTAssertEqual(s.ranges, [1..<5, 8..<10, 20..<22, 27..<29, 35..<40])
        }

        do {
            // Overlap multiple ranges
            var s = source
            s.insert(0..<21)
            XCTAssertEqual(s.ranges, [0..<22, 27..<29])
        }

        do {
            // Insert at end of range
            var s = source
            s.insert(22)
            XCTAssertEqual(s.ranges, [1..<5, 8..<10, 20..<23, 27..<29])
        }

        do {
            // Insert between ranges
            var s = source
            s.insert(14)
            XCTAssertEqual(s.ranges, [1..<5, 8..<10, 14..<15, 20..<22, 27..<29])
        }
    }
    
    func testRemovals() {
        do {
            var s = source
            s.remove(4..<28)
            XCTAssertEqual(s.ranges, [1..<4, 28..<29])
            s.remove(3)
            XCTAssertEqual(s.ranges, [1..<3, 28..<29])
        }
    }

    func testInvariant() {
        for _ in 0..<1000 {
            let set = buildRandomRangeSet()
            
            // No empty ranges allowed
            XCTAssertTrue(set.ranges.allSatisfy { !$0.isEmpty })
                
            // No overlapping / out-of-order ranges allowed
            let adjacentRanges = zip(set.ranges, set.ranges.dropFirst())
            XCTAssertTrue(adjacentRanges.allSatisfy { $0.upperBound < $1.lowerBound })
        }
    }
    
    func testIntersection() {
        func intersectionViaSet(_ s1: RangeSet<Int>, _ s2: RangeSet<Int>) -> RangeSet<Int> {
            let set1 = Set(s1.elements)
            let set2 = Set(s2.elements)
            return RangeSet(set1.intersection(set2))
        }
        
        do {
            // Simple test
            let set1: RangeSet = [0..<5, 9..<14]
            let set2: RangeSet = [1..<3, 4..<6, 8..<12]
            let intersection: RangeSet = [1..<3, 4..<5, 9..<12]
            XCTAssertEqual(set1.intersection(set2), intersection)
            XCTAssertEqual(set2.intersection(set1), intersection)
        }
        
        do {
            // Test with upper bound / lower bound equality
            let set1: RangeSet = [10..<20, 30..<40]
            let set2: RangeSet = [15..<30, 40..<50]
            let intersection: RangeSet = [15..<20]
            XCTAssertEqual(set1.intersection(set2), intersection)
            XCTAssertEqual(set2.intersection(set1), intersection)
        }
        
        for _ in 0..<100 {
            let set1 = buildRandomRangeSet()
            let set2 = buildRandomRangeSet()

            let rangeSetIntersection = set1.intersection(set2)
            let stdlibSetIntersection = intersectionViaSet(set1, set2)
            XCTAssertEqual(rangeSetIntersection, stdlibSetIntersection)
        }
    }
    
    func testSymmetricDifference() {
        func symmetricDifferenceViaSet(_ s1: RangeSet<Int>, _ s2: RangeSet<Int>) -> RangeSet<Int> {
            let set1 = Set(s1.elements)
            let set2 = Set(s2.elements)
            return RangeSet(set1.symmetricDifference(set2))
        }
        
        do {
            // Simple test
            let set1: RangeSet = [0..<5, 9..<14]
            let set2: RangeSet = [1..<3, 4..<6, 8..<12]
            let difference: RangeSet = [0..<1, 3..<4, 5..<6, 8..<9, 12..<14]
            XCTAssertEqual(set1.symmetricDifference(set2), difference)
            XCTAssertEqual(set2.symmetricDifference(set1), difference)
        }
        
        do {
            // Test with upper bound / lower bound equality
            let set1: RangeSet = [10..<20, 30..<40]
            let set2: RangeSet = [15..<30, 40..<50]
            let difference: RangeSet = [10..<15, 20..<50]
            XCTAssertEqual(set1.symmetricDifference(set2), difference)
            XCTAssertEqual(set2.symmetricDifference(set1), difference)
        }
        
        for _ in 0..<100 {
            let set1 = buildRandomRangeSet()
            let set2 = buildRandomRangeSet()

            let rangeSetDifference = set1.symmetricDifference(set2)
            let stdlibSetDifference = symmetricDifferenceViaSet(set1, set2)
            XCTAssertEqual(rangeSetDifference, stdlibSetDifference)
        }
    }
}
