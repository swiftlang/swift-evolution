import XCTest

public func XCTAssertEqual<C1, C2>(_ collection1: C1, _ collection2: C2, file: StaticString = #file, line: UInt = #line)
    where C1: Collection, C2: Collection, C1.Element == C2.Element, C1.Element: Equatable
{
    for (e1, e2) in zip(collection1, collection2) {
        XCTAssertEqual(e1, e2, file: file, line: line)
    }
    XCTAssert(collection1.count == collection2.count, "Collections have different lengths", file: file, line: line)
}
