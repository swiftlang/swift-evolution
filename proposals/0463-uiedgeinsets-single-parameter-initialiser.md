# UIEdgeInsets Single Parameter Initializer

- Proposal: [SE-0463](0463-uiedgeinsets-single-parameter-initialiser.md)
- Authors: [Gokul Nair](https://github.com/gokulnair2001)
- Review Manager: TBD
- Status: **Awaiting implementation**
- Implementation: [swiftlang/swift#NNNNN]()
- Upcoming Feature Flag: `UIEdgeInsetsSingleInit`
- Previous Proposal: N/A
- Review: ([pitch](https://forums.swift.org/t/pitch-uiedgeinsets-single-parameter-initialiser/78089))

## Introduction

This proposal introduces a new initializer for `UIEdgeInsets` that allows developers to specify a single value, which is then applied uniformly to all four edges: `top`, `left`, `bottom`, and `right`. This makes creating symmetrical insets more convenient and improves code readability.

## Motivation

Currently, developers need to explicitly define all four values when creating `UIEdgeInsets`, even when they want the same value applied to all sides. The existing approaches are:

```swift
let insets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
```

This is verbose and repetitive. A common expectation would be to have a simpler way to define equal insets across all edges, similar to `NSDirectionalEdgeInsets.init(top:leading:bottom:trailing:)`. By introducing an initializer that accepts a single parameter, we can make code more concise:

```swift
let insets = UIEdgeInsets(12)
```

This improves readability and reduces boilerplate code.

## Proposed solution

We propose adding a new initializer to `UIEdgeInsets`:

```swift
extension UIEdgeInsets {
    init(_ value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
}
```

This allows developers to define symmetrical insets with a single parameter, making the API more ergonomic and consistent with existing Swift design patterns.

## Detailed design

The new initializer will be implemented as follows:

```swift
public extension UIEdgeInsets {
    /// Creates an instance with the same inset value applied to all edges.
    /// - Parameter value: The inset value for top, left, bottom, and right.
    init(_ value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
}
```

### Example Usage

```swift
let padding = UIEdgeInsets(12)
print(padding) // UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
```

## Source compatibility

This proposal is purely additive and does not break existing source compatibility. Existing initializers remain unchanged, and developers can continue to use `UIEdgeInsets(top:left:bottom:right:)` if desired.

## ABI compatibility

The change is purely additive and does not modify existing ABI behavior. It extends the `UIEdgeInsets` API without affecting compiled binaries. Since `UIEdgeInsets` is a widely used type in UIKit, care will be taken to ensure no impact on ABI stability.

## Implications on adoption

The new initializer can be adopted incrementally. Codebases that currently use `UIEdgeInsets(top:left:bottom:right:)` can continue using it without modification, while new code can take advantage of the simplified initializer.

## Future directions

A similar initializer could be introduced for `NSDirectionalEdgeInsets` to maintain API consistency across UIKit.

```swift
extension NSDirectionalEdgeInsets {
    init(_ value: CGFloat) {
        self.init(top: value, leading: value, bottom: value, trailing: value)
    }
}
```

This would provide a consistent experience when working with both `UIEdgeInsets` and `NSDirectionalEdgeInsets`.

## Alternatives considered

### Keeping the existing API

One alternative is to keep the existing explicit initializer without any modifications. However, this results in unnecessary verbosity for a common use case.

### Using a static factory method

Instead of a new initializer, we could introduce a static factory method:

```swift
extension UIEdgeInsets {
    static func uniform(_ value: CGFloat) -> UIEdgeInsets {
        return UIEdgeInsets(top: value, left: value, bottom: value, right: value)
    }
}
```

Usage:

```swift
let insets = UIEdgeInsets.uniform(12)
```

While this approach provides the same functionality, the standard Swift API design favors initializers for such use cases.

## Acknowledgments

Thanks to the Swift community for discussions on API improvements that enhance usability and clarity in UIKit development.
