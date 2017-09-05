# Declare variables in 'case' labels with multiple patterns 

* Proposal: [SE-0043](0043-declare-variables-in-case-labels-with-multiple-patterns.md)
* Author: [Andrew Bennett](https://github.com/therealbnut)
* Review Manager: [Chris Lattner](https://github.com/lattner)
* Status: **Implemented (Swift 3)**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160321/013250.html)
* Implementation: [apple/swift#1383](https://github.com/apple/swift/pull/1383)

## Introduction

In Swift 2, it is possible to match multiple patterns in cases. However cases cannot contain multiple patterns if the case declares variables.

The following code currently produces an error:

```swift
enum MyEnum {
    case Case1(Int,Float)
    case Case2(Float,Int)
}
switch value {
case let .Case1(x, 2), let .Case2(2, x):
    print(x)
case .Case1, .Case2:
    break
}
```

The error is:

    `case` labels with multiple patterns cannot declare variables. 


This proposal aims to remove this error when each pattern declares the same variables with the same types.

Swift-evolution thread: [here](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160118/007431.html)

## Motivation

This change reduces repetitive code, and therefore reduces mistakes.
It's consistent with multi-pattern matching when variables aren't defined.

## Proposed solution

Allow case labels with multiple patterns to declare patterns by matching variable names in each pattern.

Using the following enum:

```swift
enum MyEnum {
    case Case1(Int,Float)
    case Case2(Float,Int)
}
```

These cases should be possible:

```swift
case let .Case1(x, _), let .Case2(_, x):
case let .Case1(y, x), let .Case2(x, y):
case let .Case1(x), let .Case2(x):
case .Case1(let x, _), .Case2(_, let x):
```

Likewise for other uses of patterns:

```swift
let value = MyEnum.Case1(1, 2)
if case let .Case1(x, _), let .Case2(_, x) = value {
  ...
}
```

## Detailed design

Allow case labels with multiple patterns if the case labels match the following constraints:

 * All patterns declare exactly the same variables.
 * The same variable has the same type in each pattern.

Therefore each pattern is able to produce the same variables for the case label.

In the case of `if case let` usage the syntax is the same, the only issue is whether this can be combined with other variables, and whether it is unambiguous.

The pattern grammar gets the following change:

```diff
+ enum-case-pattern-list → enum-case-pattern |
+                          enum-case-pattern , enum-case-pattern-list
+ pattern  → enum-case-pattern-list
- pattern  → enum-case-pattern
```

## Impact on existing code

This should have no impact on existing code, although it should offer many opportunities for existing code to be simplified.

## Alternatives considered

### Using a closure or inline function

Code repetition can be reduced with one pattern per 'case' and handling the result with an inline function.

```swift
func handleCases(value: MyEnum, apply: Int -> Int) -> Int {
    func handleX(x: Int) -> Int {
        return apply(x) + 1
    }
    let out: Int
    switch value {
    case .Case1(let x, 2):
        out = handleX(x)
    case .Case2(2, let x):
        out = handleX(x)
    case .Case1, .Case2:
        out = -1
    }
    return out
}
```

This syntax is much more verbose, makes control flow more confusing, and has the limitations of what the inline function may capture.

In the above example `apply` cannot be `@noescape` because handleX captures it.

Also in the above example if `out` is captured and assigned by `handleX` then it must be `var`, not `let`. This can produce shorter syntax, but is not as safe; `out` may accidentally be assigned more than once, additionally `out` also needs to be initialized (which may not be possible or desirable).

### Extending the fallthrough syntax

A similar reduction in code repetition can be achieved if fallthrough allowed variables to be mapped onto the next case, for example:

```swift
switch test {
    case .Case1(let x, 2): 
        fallthrough .Case2(_, x)
    case .Case2(3, .let x):
        print("x: \(x)")
}
```

This is not as intuitive, is a hack, and fallthrough should probably be discouraged. It is much more flexible, a programmer could adjust the value of x before fallthrough. Flexibility increases the chances of programmer error, perhaps not as much as code-repetition though.

### Chainable pattern matching

In my opinion `if case let` syntax is a little clumsy. It's good that it's consistent with a switch statement, but it's not easy to chain. I think a different syntax may be nicer, if a few things existed:

 * A case-compare syntax that returns an optional tuple:

```swift
let x = MyEnum.Case1(1,2)
let y: (Int,Int)? = (x case? MyEnum.Case1)
assert(y == Optional.Some(1,2))
```

 * multiple field getters (similar to swizzling in GLSL). It returns multiple named fields/properties of a type as a tuple:

```swift
let x = (a: 1, b: 2, c: 3)
let y = x.(a,c,b,b)
assert(y == (1,3,2,2))
```

You could compose them like this:

```swift
enum MyNewEnum {
    case MyCase1(Int,Float), MyCase2(Float,Int)
}
let x = MyNewEnum.Case1(1,2,3)
let y: (Int,Float)? = (x case? MyNewEnum.Case1) ?? (x case! MyNewEnum.Case2).(1,0)
```

This is not a true alternative, it does not work in switch statements, but I think it still has value.

## Future Considerations

It would be nice to use the `if case let` syntax to define variables of optional type.

Something like this:

     case let .Case1(x,_) = MyEnum.Case1(1,2)

Which would be the equivalent of this:

     let x: Int?
     if case let .Case1(t) = MyEnum.Case1(1,2) { x = t.0 } else { x = nil }

It would support multiple patterns like so:

     case let .Case1(x,_), .Case2(_,x) = MyEnum.Case1(1,2)

This is not necessary if [chainable pattern matching](#chainable-pattern-matching) was possible, but I've made sure this proposal is compatible.
