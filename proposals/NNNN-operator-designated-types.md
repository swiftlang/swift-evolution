# Extending operator declarations with designated types

* Proposal: [SE-NNNN](NNNN-operator-designated-types.md)
* Authors: [Mark Lacey](https://github.com/rudkx)
* Review Manager: TBD
* Status: **Implemented under staging options**

*During the review process, add the following fields as needed:*

* Implementation: This is currently in-tree, disabled by default, and enabled by staging options (`-enable-operator-designated-types`, `-solver-enable-operator-designated-types`).
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

Swift's expression type checker is known to have cases where it is extremely slow in type checking expressions.

Some of these slow typechecking cases involve expressions that make use of operators (whereas others involve collections or chained single-expression closures).

This proposal addresses speeding up type checking for cases that are slow primarily due to the number of combinations of overloads of operators that are examined in the course of typechecking.

Swift-evolution thread: [Pitch: Making expression type checking of operator expressions fast](https://forums.swift.org/t/pitch-making-expression-type-checking-of-operator-expressions-fast/18037)

## Motivation

Users sometimes write reasonable looking expressions that result in either the compiler taking a very long time to typecheck the expression or results in the diagnostic `the compiler is unable to type-check this expression in reasonable time` without any further hints as to how to fix the problem.

There are various reasons users hit this error:

- Expressions involving many operators and (usually) several literals, that should successfully typecheck.
- Expressions that should not successfully typecheck (but fail to emit a good diagnostic prior to the type checker giving up).
- Expressions involving collection literals sometimes fail even if they have only a handful of elements (e.g. < 20).
- Chains of single-expression closures, which in addition to exacerbating the issues with operators and literals, also create new problems due to a lack of explicit types for their parameters.

This proposal aims to address only the first of these issues.

## Proposed solution

We introduce syntax to define *designated types* in operator declarations. These types will be used as the first place to look up operator overloads for a given operator. If the expression successfully typechecks with an overload found via those types, we stop looking at the remaining overloads for the operator.

The intent is to use this within `Policy.swift` in the standard library in order to provide a hint to the type checker as to which overload should be preferred for typechecking an operator. You can see the current usage of this syntax [here](https://github.com/apple/swift/blob/191a71e10dab37aa12b53f04b9496642dd3604b1/stdlib/public/core/Policy.swift#L382-L485).

Users can also add their own designated types to operators that they declare, but they will not have a way to add their own types as designated types to operators already defined in `Policy.swift`.

In effect this ties a particular operator to the semantics of one (or occasionally multiple) particular named entity(ies), usually a protocol, but sometimes a concrete type. For example, if you're implementing `<<`, making `BinaryInteger` the designated type for that operator says that the expectation is that you will be implementing this for a type conforming to `BinaryInteger` and behaving in the way `BinaryInteger` would expect it to.

The goal is to use this hint to replace the currently undocumented (and difficult to reason about) hacks in the type checker that are in place today and which are required in order to typecheck even relatively simple expressions.

## Detailed design

Operator declaration syntax is extended to allow for one or more designated types to be specified. For infix operators, these types are listed after the (optional) precedence group. For prefix and postfix operators, these types come immediately after a `:` following the operator name. Some examples:

- `infix operator   * : MultiplicationPrecedence, Numeric`
- `infix operator   / : MultiplicationPrecedence, BinaryInteger, FloatingPoint`
- `prefix operator ~ : BinaryInteger`

Specifying one or more types results in the expression type checker looking at declarations defined in those types before other declarations of the operator, and stopping as soon as it finds that one of the declarations in one of the types can be used to successfully type check the expression. If it fails to typecheck successfully with one of those declarations, it continues attempting all the other overloads for that operator.

In cases where there are multiple designated types for a given operator, the specific order in which the overloads in those types are examined is left unspecified, but should produce results that are compatible with the existing type checker's notion of the "best" solution if attempting all of the overloads could result in multiple solutions.

## Experimental results

The implementation for this is already in-tree, and is enabled as such:

- `-Xfrontend -enable-operator-designated-types`: enables parsing the extended operator declarations
- `-Xfrontend -solver-enable-operator-designated-types`: enables having the constraint solver make use of the declarations

The current implementation has been tested across 25 test cases that were known to be slow and/or result in the type checker giving up after expending substantial effort attempting to type check the expression.

In addition to enabling this new *designated type* functionality, this testing disables the `shrink` portion of the expression type checker (via `-Xfrontend -solver-disable-shrink`).  This portion of the expression type checker is known to help ocassionally but often results in substantially increasing the expression type checking time since it frequently doesn't provide any benefit but does a lot of work. We also disable a number of other problematic hacks (via `-Xfrontend -disable-constraint-solver-performance-hacks`).

In 14 cases, the expressions in question now typecheck in less than 30ms (often as little as 5ms). In the 11 remaining cases, the expression is either one that would fail to typecheck if we were able to typecheck it quickly, or involves other things that are known to be problematic, like closures. 


Some illustrative examples:

```swift
// Was "too complex", now 13ms:
let i: Int? = 1
let j: Int?
let k: Int? = 2

let _ = [i, j, k].reduce(0 as Int?) {
  $0 != nil && $1 != nil ? $0! + $1! : ($0 != nil ? $0! : ($1 != nil ? $1! : nil))
}


// Was "too complex", now 5ms:
func test(a: [String], b: String, c: String) -> [String] {
  return a.map { $0 + ": " + b + "(" + c + $0 + ")" }
}

// Was "too complex", now 25ms:
func test(strings: [String]) {
  for string in strings {
    let _ = string.split(omittingEmptySubsequences: false) { $0 == "C" || $0 == "D" || $0 == "H" || $0 == "S"}
  }
}

// Was "too complex", now 5ms:
func test(n: Int) -> Int {
  return n == 0 ? 0 : (0..<n).reduce(0) {
    ($0 > 0 && $1 % 2 == 0) ? ((($0 + $1) - ($0 + $1)) / ($1 - $0)) + (($0 + $1) / ($1 - $0)) : $0
  }
}

// Was "too complex", now 2ms:
let a = 1
_ = -a + -a - -a + -a - -a

```

A number (25+) of other test cases were previously compiling quickly were also tested using this functionality and with the existing hacks disabled, and those cases are as fast or faster than previously.

## Source compatibility

Because of the fact that we fall back to behavior that is very similar to the current behavior of the type checker (exhaustively testing combinations of operators in the cases), this change is very compatible with the current behavior. 

One failure was seen in the source compatibility suite when running with this new behavior enabled by default in all language modes. The failure was in `BlueSocket`, and that same failure also manifests if you build the affected code with `-swift-version 4`. Specifically, for `let mask = 1 << (2 as Int32)`, we now infer `mask` as `Int` rather than `Int32`.

It's possible to construct cases where behavior will change based on first attempting the overloads defined in the designated type and then checking no other alternatives if that overload succeeds. It's difficult to quantify how often existing code might hit this, but the same code would also potentially break due to implementation changes in the type checker. This proposal makes breaks like this less likely in the future by codifying another piece of behavior in the type checker.

One example of where we can expect to see breaks from this change is where users implement operators that are declared in the standard library for types that would also typecheck successfully with the standard library implementation. For example a user has a type that is `Equatable` and has defined `==` where one or both operands are the user's type, but where the implementation behaves differently than calling the `==` defined on `Equatable`.

We can see this in the [`Anchorage`](https://github.com/RaizLabs/Anchorage) project on GitHub.

```swift
@discardableResult public func == (
  lhs: NSLayoutDimension,
  rhs: NSLayoutDimension
) -> NSLayoutConstraint {
    return finalize(constraint: lhs.constraint(equalTo: rhs))
}
```

Here, `NSLayoutDimension` is `Equatable`, and as a result code like:

  ```swift
     let equal = view1.widthAnchor == view2.widthAnchor
  ```

which currently calls the `Anchorage` implementation of `==` would instead call the `==` on `Equatable`, resulting in `equal` being inferred to be a `Bool`, and subsequent code that references `equal` failing.

Note that adding the type declaration `: NSLayoutConstraint` after `equal` will fix the code since it will result in solutions that attempt the `==` from `Equatable` to fail (since it returns a `Bool`).

We could potentially generate fixes like these by performing the type check a second time with the designated types feature disabled and if type checking succeeds insert fixes for expressions which successfully typechecked both ways but where the inferred type has changed.

In many cases operators are used in contexts where a particular type is already expected or where they are combined with other operators which further constrain the combinations that typecheck successfully, so in practice this may not turn out to be a significant source of breakage.

## Effect on ABI stability

None.

## Effect on API resilience

None.

## Alternatives considered

There have been various attempts at fixing this problem strictly through changing implementation details of the expression type checker. To date none of those attempts has been completely successful at making relatively straightforward expressions typecheck in a reasonable period of time in all cases.
 
There have been various iterations of this proposal that suggested alternatives such as treating operators like member lookup, with something similar to these designated types used in places where literals appear in an expression. This current iteration of the proposal seems simpler, easier to teach, and also creates a strong tie between the operator declaration and the semantic meaning of the operator by saying, e.g. that `<<` is intended to be defined by types that implement `BinaryInteger` and that `<` is intended to be defined by types that implement `Comparable`.
