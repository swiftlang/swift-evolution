import XCTest
import Prototype_RangeSet
import TestHelpers

final class PartitionTests: XCTestCase {
    func testStablePartition() {
        for length in 0..<13 {
            let initial = Array(0..<length)
            
            for modulus in 1...5 {
                let f: (Int) -> Bool = { $0.isMultiple(of: modulus) }
                let notf = { !f($0) }
                
                var array = COWLoggingArray(initial)
                let cc = COWLoggingArray_CopyCount
                
                var p = array.stablePartition(by: f)
                XCTAssertEqual(array[..<p], initial.filter(notf))
                XCTAssertEqual(array[p...], initial.filter(f))
                XCTAssertEqual(cc, COWLoggingArray_CopyCount)

                var (result, q) = initial.stablyPartitioned(by: f)
                XCTAssertEqual(array[..<p], result[..<q])
                XCTAssertEqual(array[p...], result[q...])

                array = COWLoggingArray(initial)
                p = array.stablePartition(by: notf)
                XCTAssertEqual(array[..<p], initial.filter(f))
                XCTAssertEqual(array[p...], initial.filter(notf))

                (result, q) = initial.stablyPartitioned(by: notf)
                XCTAssertEqual(array[..<p], result[..<q])
                XCTAssertEqual(array[p...], result[q...])
            }

            for low in initial.startIndex...initial.endIndex {
                let prefix = initial[..<low]
                for high in low...length {
                    let suffix = initial[high...]
                    let subrange = initial[low..<high]
                    
                    for modulus in 1...5 {
                        let f: (Int) -> Bool = { $0.isMultiple(of: modulus) }
                        let notf = { !f($0) }
                        
                        var array = initial
                        var p = array[low..<high].stablePartition(by: f)
                        XCTAssertEqual(array[..<low], prefix)
                        XCTAssertEqual(array[high...], suffix)
                        XCTAssertEqual(array[low..<p], subrange.filter(notf))
                        XCTAssertEqual(array[p..<high], subrange.filter(f))
                        
                        array = initial
                        p = array[low..<high].stablePartition(by: notf)
                        XCTAssertEqual(array[..<low], prefix)
                        XCTAssertEqual(array[high...], suffix)
                        XCTAssertEqual(array[low..<p], subrange.filter(f))
                        XCTAssertEqual(array[p..<high], subrange.filter(notf))
                    }
                }
            }
        }
    }

    func testHalfStablePartition() {
        for length in 0..<13 {
            let initial = Array(0..<length)
            
            for modulus in 1...5 {
                let f: (Int) -> Bool = { $0.isMultiple(of: modulus) }
                let notf = { !f($0) }
                
                var array = COWLoggingArray(initial)
                let cc = COWLoggingArray_CopyCount
                
                var p = array.halfStablePartition(by: f)
                XCTAssertEqual(array[..<p], initial.filter(notf))
                XCTAssertEqual(array[p...].sorted(), initial.filter(f))
                XCTAssertEqual(cc, COWLoggingArray_CopyCount)

                array = COWLoggingArray(initial)
                p = array.halfStablePartition(by: notf)
                XCTAssertEqual(array[..<p], initial.filter(f))
                XCTAssertEqual(array[p...].sorted(), initial.filter(notf))
            }
        }
    }
    
    func testPartition() {
        for length in 0..<15 {
            let initial = Array(0..<length)
            
            for i in initial.indices {
                var array = COWLoggingArray(initial)
                let cc = COWLoggingArray_CopyCount
                let newStart = array.rotate(shiftingToStart: i)
                XCTAssertEqual(cc, COWLoggingArray_CopyCount)
                XCTAssertEqual(array[newStart...] + array[..<newStart], initial)
            }
        }
    }
}
