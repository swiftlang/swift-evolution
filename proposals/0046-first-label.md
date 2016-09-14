# Establish consistent label behavior across all parameters including first labels

* Proposal: [SE-0046](0046-first-label.md)
* Authors: [Jake Carter](https://github.com/JakeCarter), [Erica Sadun](http://github.com/erica)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution-announce/2016-March/000067.html)
* Bug: [SR-961](https://bugs.swift.org/browse/SR-961)

## Introduction
We propose to normalize the first parameter declaration in methods 
and functions. In this proposal, first parameter declarations will match
the existing behavior of the second and later parameters.
All parameters, regardless of position, will behave
uniformly. This will create a simple, consistent approach to parameter
declaration throughout the Swift programming language and bring 
method and function declarations in-sync with initializers, which
already use this standard.

*Discussion took place on the Swift Evolution mailing list in the [Make the first parameter in a function declaration follow the same rules as the others](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160307/012209.html) thread.*

## Motivation
In the current state of the art, Swift 2 methods and functions combine local and external names to
label parameters. These differentiated symbols distinguish names for internal implementation and 
external consumption. By default, 
a Swift 2 parameter declaration that appears first in the parameter list
omits its external name. Second and later parameters
duplicate local names as external labels. Under these Swift 2 rules, a declaration that looks like this:

```swift
func foo(a: T, b: U, c: V)
```
declares `foo(_:b:c:)` and not `foo(a:b:c:)`.

Historically, this label behavior was normalized in Swift 2, unifying parameter naming rules for
methods and functions, which had previously used separate defaults behaviors. 
The new unified approach approximated Objective-C naming conventions where 
first parameter labels were subsumed into the first part of a method signature.
For the most part, Swift 2 developers were encouraged to mimic this approach and build calls
that moved the label name out of the parameter list and into the function or method name.

Swift 3's newly accepted [API naming guidelines](https://swift.org/documentation/api-design-guidelines/) 
shook up this approach. They more thoroughly embraced method and function first argument labels.  The updated naming guidance is further supported by the [automated Objective-C API translation rules](0005-objective-c-name-translation.md)
recently accepted for Swift 3. Under these revised guidelines, first argument labels are encouraged for 
but are not limited to:

* methods and functions where the first parameter of a method is defaulted
* methods and functions where the first argument uses a prepositional phrase
* methods and functions that implement factory methods
* methods and functions where method arguments represent a split form of a single abstraction

First argument labels are also the standard for initializers.
 
This expanded guidance creates a greater reach of first argument label usage and
weakens justification for a first-parameter exception. 
Ensuring that parameter declarations behave uniformly supports Swift's goals
of clarity and consistency. This change produces the simplest and most predictable usage,
simplifying naming tasks, reducing confusion, and easing transition to the language.

## Detail Design

Under this proposal, first parameters names automatically create 
matching external labels, mimicking the second and later parameters. For example

```swift
func foo(x: Int, y: Int) 
```

will declare `foo(x:y:)` and not `foo(_:,y:)`. Developers will no longer need to
double the first label to expose it to consuming API calls.

The existing external label overrides will continue to
apply to first parameters. You establish
external parameter names before the local parameter name it
supports, separated by a space. For example,

```swift
func foo(xx x: Int, yy y: Int)
```

declares `foo(xx:yy:)` and 

```swift
func foo(_ x: Int, y: Int)
```

explicitly declares `foo(_:y:)`

## Impact on Existing Code

This proposal will impact existing code, requiring migration support from Xcode. We propose the following solution:

* Function declarations that do not include explicit first item external labels will explicitly remove the first argument's label (e.g. `func foo(x: Int, y: Int)` will translate to `func foo(_ x: Int, y: Int)`).
* Function call sites (e.g. `foo(2, y: 3)`) will remain unaffected.
* Selector mentions (e.g. `#selector(ViewController.foo(_:y:))`) will remain unaffected
 
We do not recommend swapping the fixit behavior. Functions are more often called and mentioned than declared. Under a swap, the callsite would update to `foo(x:2, y:3)`, selector mentions would update to `#selector(ViewController.foo(x:y:)`  and the declaration left as is, to be interpreted as an explicitly named first label.

Ideally the migrator will locate patterns where the last letters of a function name match the first parameter name, for example `tintWithColor(color: UIColor)`, and insert a `FIXME:` warning suggesting manual migration. Swift's automatic Objective-C import code might be repurposed to detect a prepositional phrase and parameter match to automate a fixit for `tint(color: UIColor)` or `tint(withColor: UIColor)` but this would involve a more complicated implementation.

#### Note

This proposal does not affect the behavior of Swift subscripts in any way.  Subscripts act
as an indexing shortcut for accessing the member elements of a type. Although subscripts
*can* use optional labels, there is no parallel between their use of labels and the function
and method parameters discussed in this proposal. You remain free to implement 
subscripts in the most appropriate way for your particular type's functionality,
with or without labels.

## Alternatives Considered

There are no alternatives considered at this time.
