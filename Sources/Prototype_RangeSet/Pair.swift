/// A collection of two elements, to avoid heap allocation when calling
/// `replaceSubrange` with just two elements.
internal struct Pair<Element>: RandomAccessCollection {
    var pair: (first: Element, second: Element)
    
    init(_ first: Element, _ second: Element) {
        self.pair = (first, second)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { 2 }
    
    subscript(position: Int) -> Element {
        get {
            switch position {
            case 0: return pair.first
            case 1: return pair.second
            default: fatalError("Index '\(position)' is out of range")
            }
        }
    }
}
