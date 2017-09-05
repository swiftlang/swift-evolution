# Naming Functions with Argument Labels

* Proposal: [SE-0021](0021-generalized-naming.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: [Joe Groff](https://github.com/jckarter)
* Status: **Implemented (Swift 2.2)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-January/000021.html)
* Implementation: [apple/swift@ecfde0e](https://github.com/apple/swift/commit/ecfde0e71c61184989fde0f93f8d6b7f5375b99a)

## Introduction

Swift includes support for first-class functions, such that any
function (or method) can be placed into a value of function
type. However, when specifying the name of a function, one can only provide the base name, (e.g., `insertSubview`) without the argument labels. For overloaded functions, this means that one must disambiguate based on type information, which is awkward and verbose. This proposal allows one to provide argument labels when referencing a function, eliminating the need to provide type context in most cases.

Swift-evolution thread: The first draft of this proposal was discussed [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/004555.html). It included support for naming getters/setters (separately brought up by Michael Henson
[here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151207/002168.html),
continued
[here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/002203.html)). Joe Groff [convinced](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151221/004579.html) me that lenses are a better approach for working with getters/setters, so I've dropped them from this version of the proposal.

## Motivation

It's fairly common in Swift for multiple functions or methods to have
the same "base name", but be distinguished by parameter labels. For
example, `UIView` has three methods with the same base name `insertSubview`:

```swift
extension UIView {
  func insertSubview(view: UIView, at index: Int)
  func insertSubview(view: UIView, aboveSubview siblingSubview: UIView)
  func insertSubview(view: UIView, belowSubview siblingSubview: UIView)
}
```

When calling these methods, the argument labels distinguish the
different methods, e.g.,

```swift
someView.insertSubview(view, at: 3)
someView.insertSubview(view, aboveSubview: otherView)
someView.insertSubview(view, belowSubview: otherView)
```

However, when referencing the function to create a function value, one
cannot provide the labels:

```swift
let fn = someView.insertSubview // ambiguous: could be any of the three methods
```

In some cases, it is possible to use type annotations to disambiguate:

```swift
let fn: (UIView, Int) = someView.insertSubview    // ok: uses insertSubview(_:at:)
let fn: (UIView, UIView) = someView.insertSubview // error: still ambiguous!
```

To resolve the latter case, one must fall back to creating a closure:

```swift
let fn: (UIView, UIView) = { view, otherView in
  button.insertSubview(view, aboveSubview: otherView)
}
```

which is painfully tedious. 

One additional bit of motivation: Swift should probably get some way
to ask for the Objective-C selector for a given method (rather than
writing a string literal). The argument to such an operation would
likely be a reference to a method, which would benefit from being able
to name any method, including getters and setters.

## Proposed solution

I propose to extend function naming to allow compound Swift names
(e.g., `insertSubview(_:aboveSubview:)`) anywhere a name can
occur. Specifically,

```swift
let fn = someView.insertSubview(_:at:)
let fn1 = someView.insertSubview(_:aboveSubview:)
```

The same syntax can also refer to initializers, e.g.,

```swift
let buttonFactory = UIButton.init(type:)
```

The "produce the Objective-C selector for the given method" operation
will be the subject of a separate proposal. However, here is one
possibility that illustrations how it uses the proposed syntax here:

```swift
let getter = Selector(NSDictionary.insertSubview(_:aboveSubview:)) // produces insertSubview:aboveSubview:.
```
## Detailed Design

Grammatically, the *primary-expression* grammar will change from:

    primary-expression -> identifier generic-argument-clause[opt]

to:

    primary-expression -> unqualified-name generic-argument-clause[opt]

    unqualified-name -> identifier
                      | identifier '(' ((identifier | '_') ':')+ ')'

Within the parentheses, the use of "+" is important, because it disambiguates:

```swift
f()
```

as a call to `f` rather than a reference to an `f` with no
arguments. Zero-argument function references will still require
disambiguation via contextual type information.

Note that the reference to the name must include all of the arguments
present in the declaration; arguments for defaulted or variadic
parameters cannot be skipped. For example:

```swift
func foo(x x: Int, y: Int = 7, strings: String...) { ... }

let fn1 = foo(x:y:strings:) // okay
let fn2 = foo(x:) // error: no function named 'foo(x:)'
```

## Impact on existing code

This is a purely additive feature that has no impact on existing
code.

## Alternatives considered

* Joe Groff
  [notes](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151214/003008.html)
  that *lenses* are a better solution than manually
  retrieving getter/setter functions when the intent is to actually
  operate on the properties.

* Bartlomiej Cichosz [suggests](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20151228/004739.html) a general partial application syntax using `_` as a placeholder, e.g.,

  ```swift
aGameView.insertSubview(_, aboveSubview: playingSurfaceView)
  ```

  When all arguments are `_`, this provides the ability to name any method:

  ```swift
aGameView.insertSubview(_, aboveSubview: _)
  ```

  I decided not to go with this because I don't believe we need such a
  general partial application syntax in Swift. Closures using the $
  names are nearly as concise, and eliminate any questions about how
  the `_` placeholder maps to an argument of the partially-applied
  function:

  ```swift
{ aGameView.insertSubview($0, aboveSubview: playingSurfaceView) }
  ```

* We could elide the underscores in the names, e.g.,

  ```swift
  let fn1 = someView.insertSubview(:aboveSubview:)
  ```

  However, this makes it much harder to visually distinguish methods
  with no first argument label from methods with a first argument
  label, e.g., `f(x:)` vs. `f(:x:)`. Additionally, empty argument
  labels in function names are written using the underscores
  everywhere else in the system (e.g., the Clang `swift_name`
  attribute), and we should maintain consistency.
