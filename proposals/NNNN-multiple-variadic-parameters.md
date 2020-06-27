# Allow Multiple Variadic Parameters in Functions, Subscripts, and Initializers

* Proposal: [SE-NNNN](NNNN-multiple-variadic-parameters.md)
* Author: [Owen Voorhees](https://github.com/owenv)
* Review Manager:
* Status:
* Implementation: [apple/swift#29735](https://github.com/apple/swift/pull/29735)

## Introduction

Currently, variadic parameters in Swift are subject to two main restrictions:

- Only one variadic parameter is allowed per parameter list
- If present, the parameter which follows a variadic parameter must be labeled

This proposal seeks to remove the first restriction while leaving the second in place, allowing a function, subscript, or initializer to have multiple variadic parameters so long as every parameter which follows a variadic one has a label.

Swift-evolution thread: [Lifting the 1 variadic param per function restriction](https://forums.swift.org/t/lifting-the-1-variadic-param-per-function-restriction/33787?u=owenv)

## Motivation

Variadic parameters allow programmers to write clear, succinct APIs which operate on a variable, but compile-time fixed number of inputs. One prominent example is the standard library's `print` function. However, restricting each function to a single variadic parameter can sometimes be limiting. For example, consider the following example from the `swift-driver` project:

```swift
func assertArgs(
      _ args: String...,
      parseTo driverKind: DriverKind,
      leaving remainingArgs: ArraySlice<String>,
      file: StaticString = #file, line: UInt = #line
    ) throws { /* Implementation Omitted */ }

try assertArgs("swift", "-foo", "-bar", parseTo: .interactive, leaving: ["-foo", "-bar"])
```

Currently, the `leaving:` parameter cannot be variadic because of the preceding unnamed variadic parameter. This results in an odd inconsistency, where the first list of arguments does not require brackets, but the second does. By allowing multiple variadic parameters, it could be rewritten like so:

```swift
func assertArgs(
      _ args: String...,
      parseTo driverKind: DriverKind,
      leaving remainingArgs: String...,
      file: StaticString = #file, line: UInt = #line
    ) throws { /* Implementation Omitted */ }

try assertArgs("swift", "-foo", "-bar", parseTo: .interactive, leaving: "-foo", "-bar")
```

This results in a cleaner, more consistent interface.

Multiple variadic parameters can also be used to streamline lightweight DSL-like functions. For example, one could write a simple autolayout wrapper like the following:

```swift
extension UIView {
  func addSubviews(_ views: UIView..., constraints: NSLayoutConstraint...) {
    views.forEach {
      addSubview($0)
      $0.translatesAutoresizingMaskIntoConstraints = false
    }
    constraints.forEach { $0.isActive = true }
  }
}

myView.addSubviews(v1, v2, constraints: v1.widthAnchor.constraint(equalTo: v2.widthAnchor),
                                        v1.heightAnchor.constraint(equalToConstant: 40),
                                        /* More Constraints... */)
```

## Proposed solution

Lift the arbitrary restriction on variadic parameter count and allow a function/subscript/initializer to have any number of them. Leave in place the restriction which requires any parameter following a variadic one to have a label.

## Detailed design

A variadic parameter can already appear anywhere in a parameter list, so the behavior of multiple variadic parameters in functions and initializers is fully specified by the existing language rules.

```swift
// Note the label on the second parameter is required because it follows a variadic parameter.
func twoVarargs(_ a: Int..., b: Int...) { }
twoVarargs(1, 2, 3, b: 4, 5, 6)

// Variadic parameters can be omitted because they default to [].
twoVarargs(1, 2, 3)
twoVarargs(b: 4, 5, 6) 
twoVarargs()

// The third parameter does not require a label because the second isn't variadic.
func splitVarargs(a: Int..., b: Int, _ c: Int...) { } 
splitVarargs(a: 1, 2, 3, b: 4, 5, 6, 7)
// a is [1, 2, 3], b is 4, c is [5, 6, 7].
splitVarargs(b: 4)
// a is [], b is 4, c is [].

// Note the third parameter doesn't need a label even though the second has a default expression. This
// is consistent with the current behavior, which allows a variadic parameter followed by a labeled,
// defaulted parameter, followed by an unlabeled required parameter.
func varargsSplitByDefaultedParam(_ a: Int..., b: Int = 42, _ c: Int...) { } 
varargsSplitByDefaultedParam(1, 2, 3, b: 4, 5, 6, 7)
// a is [1, 2, 3], b is 4, c is [5, 6, 7].
varargsSplitByDefaultedParam(b: 4, 5, 6, 7)
// a is [], b is 4, c is [5, 6, 7].
varargsSplitByDefaultedParam(1, 2, 3)
// a is [1, 2, 3], b is 42, c is [].
// Note: it is impossible to call varargsSplitByDefaultedParam providing a value for the third parameter
// without also providing a value for the second.
```

This proposal also allows subscripts to have more than one variadic parameter. Like in functions and initializers, a subscript parameter which follows a variadic parameter must have an external label. However, the syntax differs slightly because of the existing labeling rules for subscript parameters:

```swift
struct HasSubscript {
    // Not allowed because the second parameter does not have an external label.
    subscript(a: Int..., b: Int...) -> [Int] { a + b }

    // Allowed
    subscript(a: Int..., b b: Int...) -> [Int] { a + b }
}
```

Note that due to a long-standing bug, the following subscript declarations are accepted by the current compiler:

```swift
struct HasBadSubscripts {
    // Shouldn't be allowed because the second parameter follows a variadic one and has no
    // label. Is accepted by the current compiler but can't be called.
    subscript(a: Int..., b: String) -> Int { 0 }

    // Shouldn't be allowed because the second parameter follows a variadic one and has no
    // label. Is accepted by the current compiler and can be called, but the second
    // parameter cannot be manually specified.
    subscript(a: Int..., b: String = "hello, world!") -> Bool { false }
}
```

This proposal makes both declarations a compile time error. This is a source compatibility break, but a very small one which only affects declarations with no practical use. This bug also affects closure parameter lists:

```swift
// Currently allowed, but impossible to call.
let closure = {(a: Int..., b: Int) in}
```

Under this proposal, the above code also becomes a compile-time error. Note that because closures do not allow external parameter labels, they cannot support multiple variadic parameters.

## Source compatibility

As noted above, this proposal is source-breaking for any program which has a subscript declaration or closure having an unlabeled parameter following a variadic parameter. With the exception of very specific subscript declarations making use of default parameters, this only affects parameter lists which are syntactically impossible to fulfill. As a result, the break should have no impact on the vast majority of existing codebases. It does not cause any failures in the source compatibility suite.

If this source-breaking change is considered unacceptable, there are two alternatives. One would be to make the error a warning instead for subscripts and closures. The other would be to preserve the buggy behavior and emit no diagnostics. In both cases, multiple variadic parameters would continue to be supported by subscripts, but users would retain the ability to write parameter lists which can't be fulfilled in some contexts.

## Effect on ABI stability

This proposal does not require any changes to the ABI. The current ABI representation of variadic parameters already supports more than one per function/subscript/initializer.

## Effect on API resilience

An ABI-public function may not add, remove, or reorder parameters, whether or not they have default arguments or are variadic. This rule is unchanged and applies to all variadic parameters.

## Alternatives considered

Two alternative labeling rules were considered. 

1. If a parameter list has more than one variadic parameter, every variadic parameter must have a label.
2. If a parameter list has more than one variadic parameter, every variadic parameter except for the first must have a label.

Both alternatives are more restrictive in terms of the declarations they allow. This increases complexity and makes the parameter labeling rules harder to reason about. However, they might make it more difficult to write confusing APIs which mix variadic, defaulted, and required parameters. Overall, it seems better to trust programmers with greater flexibility, while also minimizing the number of rules they need to learn.
