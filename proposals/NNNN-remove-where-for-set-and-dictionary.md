# Add `remove(where:)` Method for `Set` and `Dictionary`

* **Proposal**: [SE-NNNN](0456-remove-where-for-set-and-dictionary.md)
* **Authors**: [Krisna Pranav](https://github.com/krishpranav)
* **Status**: **Awaiting review**
* **Implementation**: [apple/swift#PR](https://github.com/swiftlang/swift/pull/78600)
* **Review**: ([Pitch](https://forums.swift.org/t/pitch-add-remove-where-method-for-set-and-dictionary/77165))

## Introduction

This proposal introduces a new method, `remove(where:)`, for the `Set` and `Dictionary` data structures in Swift. The method provides a streamlined way to remove elements that satisfy a given condition, improving code readability, performance, and developer experience.

Swift-evolution thread: [Pitch: Add `remove(where:)` Method](https://forums.swift.org/t/pitch-add-remove-where-method-for-set-and-dictionary/77165)

## Motivation

Currently, developers need to write verbose and repetitive code to remove elements from `Set` or `Dictionary` based on a specific condition. For example, removing elements from a `Set` often requires iterating over its contents, and doing so for `Dictionary` involves even more boilerplate.

### Example: Current Approach

```swift
var numbers: Set = [1, 2, 3, 4, 5]

// Removing the first even number manually
var removedElement: Int?
for element in numbers {
    if element % 2 == 0 {
        removedElement = element
        numbers.remove(element)
        break
    }
}

print(numbers)  // Output: [1, 3, 4, 5]
```

The above approach is not only verbose but also lacks the elegance expected in modern Swift APIs. Similarly, working with dictionaries involves additional complexity due to key-value pairs.

### Key Benefits
- **Improved Readability:** Simplifies the code for conditional removals.
- **Consistency:** Aligns with existing collection methods like `filter` and `first(where:)`.
- **Efficiency:** Reduces boilerplate, making Swift code cleaner and more expressive.

## Proposed Solution

Introduce a new `remove(where:)` method for `Set` and `Dictionary`. The method will:
- Accept a closure as a condition to match elements for removal.
- Remove and return the first matching element (or key-value pair) from the collection.
- Return `nil` if no match is found.

### Example: Proposed API Usage

#### `Set` Example

```swift
var numbers: Set = [1, 2, 3, 4, 5]

// Remove the first even number
if let removedElement = numbers.remove(where: { $0 % 2 == 0 }) {
    print("Removed element: \(removedElement)")  // Output: Removed element: 2
}

print(numbers)  // Output: [1, 3, 4, 5]
```

#### `Dictionary` Example

```swift
var dictionary: [Int: String] = [1: "One", 2: "Two", 3: "Three"]

// Remove the key-value pair where the key is greater than 1
if let removedPair = dictionary.remove(where: { $0.key > 1 }) {
    print("Removed pair: \(removedPair)")  // Output: Removed pair: (key: 2, value: "Two")
}

print(dictionary)  // Output: [1: "One", 3: "Three"]
```

## Detailed Design

### Method Signature

#### For `Set`:
```swift
extension Set {
    mutating func remove(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        for element in self where try predicate(element) {
            self.remove(element)
            return element
        }
        return nil
    }
}
```

#### For `Dictionary`:
```swift
extension Dictionary {
    mutating func remove(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        for (key, value) in self where try predicate((key, value)) {
            self.removeValue(forKey: key)
            return (key, value)
        }
        return nil
    }
}
```

### Testing

The implementation will include comprehensive unit tests in the existing `Set` and `Dictionary` test files to ensure correctness and performance. Example tests include:

#### `Set` Tests
```swift
var set: Set = [1, 2, 3, 4, 5]
XCTAssertEqual(set.remove(where: { $0 % 2 == 0 }), 2)
XCTAssertEqual(set, [1, 3, 4, 5])
```

#### `Dictionary` Tests
```swift
var dictionary = [1: "One", 2: "Two", 3: "Three"]
XCTAssertEqual(dictionary.remove(where: { $0.key > 1 }), (2, "Two"))
XCTAssertEqual(dictionary, [1: "One", 3: "Three"])
```

## Security

This feature introduces no security implications as it operates strictly within the bounds of Swift’s existing type system and memory safety guarantees.

## Impact on Existing Code

This change is entirely additive and does not impact any existing APIs. All current codebases will continue to function without modification.

## Alternatives Considered

1. **Extend `filter` or `first(where:)`:** This approach was deemed unsuitable as it diverges from the typical mutating behavior expected in collection operations.
2. **Manual Implementation:** While feasible, it adds unnecessary boilerplate and complexity to client code.

## Future Directions

- Extend this functionality to other Swift collection types as appropriate.
- Explore optimizations for large collections to improve performance further.

---

Thank you for considering this proposal! This addition aims to enhance Swift’s usability and developer experience, making conditional removals intuitive, concise, and consistent with the language’s design philosophy.

