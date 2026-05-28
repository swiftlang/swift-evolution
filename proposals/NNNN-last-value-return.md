# Last-value rule for return values and expressions

* Proposal: [SE-NNNN](NNNN-last-value-expressions.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Hamish Knight](https://github.com/hamishknight)
* Review Manager: TBD
* Status: **Awaiting Review**
* Implementation: available on `main` via `-enable-experimental-feature ImplicitLastExprResults`

## Introduction

This proposal introduces a last value rule, for the purpose of determining the return value of a function, and of the value of an `if` or `switch` expression that contains multiple statements in a single branch. It also introduces `do` expressions.

## Motivation

[SE-0380](https://github.com/apple/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md) introduced the ability to use `if` and `switch` statements as expressions. As that proposal lays out, this allows for much improved syntax for example when initializing variables:

```
let width = switch scalar.value {
    case 0..<0x80: 1
    case 0x80..<0x0800: 2
    case 0x0800..<0x1_0000: 3
    default: 4
}
```

where otherwise techniques such as an immediately-executed closure, or explicitly-typed definitive initialization would be needed.

However, the proposal left as a future direction the ability to have a branch of the `switch` contain multiple statements:

```swift
let width = switch scalar.value {
    case 0..<0x80: 1
    case 0x80..<0x0800: 2
    case 0x0800..<0x1_0000: 3
    default: 
      log("this is unexpected, investigate this")
      4  // error: Non-expression branch of 'switch' expression may only end with a 'throw'
}
```

When such branches are necessary, currently users must fall back to the old techniques.

This proposal introduces a new rule that the bare last value would be the value of a branch, which allows a `switch` to remain an expression:

```
let width = switch scalar.value {
    case 0..<0x80: 1
    case 0x80..<0x0800: 2
    case 0x0800..<0x1_0000: 3
    default: 
      log("this is unexpected, investigate this")
      4
}
```

It can similarly be used to allow multi-statement branches in `if` expressions.

Swift has always had a shorthand for closures that allowed for the omission of the `return` keyword for single-expression bodies. [SE-0255](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0255-omit-return.md) extended this rule to all functions. However, when functions required multiple expressions, the `return` must be used.

This has some negative affects on how code is written. It becomes tempting to avoid breaking expressions up into sub-expressions and variables, because this will require the addition of a `return` keyword. The addition of a log line similarly introduces a need to insert an additional `return`. Whilst these shortcomings are not not as severe as the forced refactorings from having to add a multi-statement line to a branch of a switch, they are still an ergonomic papercut.

Introducing a last expression rule would also cut down on aftifacts such as the slightly awkward `return if` that must used if you want to make use of an `if` expression to return a value:

```swift
static func randomOnHemisphere(with normal: Vec3) -> Vec3 {
  let onUnitSphere: Vec3 = .randomUnitVector
  // how does one best indent this?
  return 
    if onUnitSphere • normal > 0 {
      onUnitSphere
    } else {
      -onUnitSphere
    }
}
```

Additionally, the introduction of a last value rule allows for a style where explicit an `return` in mid-function now stands out as _unusual_, drawing the eye in a way that it does not when it's fully expected for there to be at least one `return` in _every_ function. For example, there are many examples in the Swift standard library that check for a fast path, return quickly, then follow "normal" flow:

```swift
func foreignHasNormalizationBoundary(
  before index: String.Index
) -> Bool {
  // early bail out
  if index == range.lowerBound || index == range.upperBound {
    return true
  }
  
  // "normal" path, no return
  _guts.foreignHasNormalizationBoundary(before: index)
}
```

The desire to use a keyword to draw attention to early exit is popular in the Swift community, as evidenced by enthusiasm for the `guard` keyword to check for these conditions. However, sometimes an `if` is more natural for the condition being checked than having to negate the condition. `if` plus explicit `return`, with no return needed for the "normal" path (which may be multiple statements) serves a similar function.

Finally, the introduction of this rule also makes stand-alone `do` expressions more viable. These have two use cases: 

1. To produce a value from both the success and failure paths of a `do`/`catch` block:
    ```swift
    let foo: String = do {
        try bar()
    } catch {
        "Error \(error)"
    }
    ```
2. The ability to initialize a variable when this cannot easily be done with a single expression:

    ```swift
    let icon: IconImage = do {
        let image = NSImage(
                        systemSymbolName: "something", 
                        accessibilityDescription: nil)!
        let preferredColor = NSColor(named: "AccentColor")!
        
        IconImage(
                image, 
                isSymbol: true, 
                isBackgroundSupressed: true, 
                preferredColor: preferredColor.cgColor)
    }
    ```

While the above can be composed as a single expression, declaring separate variables and then using them is much clearer.

In other cases, this cannot be done because an API is structured to require you first create a value, then mutate part of it:

```swift
let motionManager: CMMotionManager = {
    let manager = CMMotionManager()
    manager.deviceMotionUpdateInterval = 0.05
    return manager
}()
```

This immediately-executed closure pattern is commonly seen in Swift code. So much so that in some cases, users assume that even single expressions must be surrounded in a closure. `do` expressions would provide a clearer idiom for grouping these.

## Detailed Design

If a function returns a non-`Void` value, the last expression in the function will be used as an implied return value if it is of that type. For closures, the last expression will be used to infer the type of the outer closure.

`if` and `switch` expressions will no longer be limited to a single expression per branch. Instead, they can execute multiple statements, and then end with an expression, which becomes the value of that branch of the expression.

Additionally `do` statements will become expressions, with rules matching those of `if` and `switch` expressions from SE-0380: 

- They can be used to return vales from functions, to assign values to variables, and to declare variables.
- They will not be usable more generally as sub-expressions, arguments to functions etc
- Both the `do` branch, and each `catch` branch if present, must either be a single expression, or have a last expression, of the appropriate type.
- Further `if`, `switch`, and `do` expressions may be nested inside the `do` or `catch` branches, and `do` expressions can be nested inside `if` and `switch` expressions.
- The `do` and any `catch` branches must all produce the same type, when type checked independently (see SE-0380 for justification of this).
- If a block either explicitly throws, or terminates the program (e.g. with `fatalError`), it does not need to produce a value and can have multiple statements before terminating.

Implicit returns inside `guard` statements are _not_ proposed:

```
func f() -> Int {
  // error: 'guard' body must not fall through, consider using a 'return' or 'throw' to exit the scope
  guard .random() else { 0 }
  1
}
```

Guard statements can contain more than just returns – they can continue/break, abort, or throw, and so an explicit return is still required.

### Impact on existing code

This change is largely source compatible. As with SE-0380 there are edge cases where closures can lead to a source break. Within the Swift source compatability suite, there is only one instance of this, which can be reduced as:

```swift
@discardableResult
func f() -> Int { 1 }

let outer = { () -> (() -> ()) in
    // return value of inner closure is left inferred
    let inner = { () in
      // statements that prevented this closure
      // from being single-expression, inferring ()->Int
      print("do something")
      // discardable result, so no warning when
      // this closure previously was inferred as ()->()
      f()
    }
    // With -enable-experimental-feature ImplicitLastExprResults this now fails with
    // Cannot convert value of type '() -> Int' to closure result type '() -> ()'
    return inner
}
```

In keeping with Swift's compatibility guarantee, this feature should be introduced under an upcoming feature flag. However, it may be worth considering enabling it by default if breaks such as these are deemed exceptionally rare (i.e. if this example from the compatability suite remains the only known instance).

## Alternatives Considered

Many of the alternatives considered and future directions in [SE-0380](https://github.com/apple/swift-evolution/blob/main/proposals/0380-if-switch-expressions.md) remain applicable to this proposal.

The convention that the last expression in a block is the value of the outer expression, without any keyword, is well preccedented in multiple languages such as Ruby. In these communities, the rule is generally thought to be highly desirable.

Rust has a slight variant of this: a semicolon is required at the end of each line _except_ for the line representing the expression of the outer expression. This option likely works better in Rust, where semicolons are otherwise required. In Swift, they are only optional for uses such as placing multiple statements on one line, making this solution less appealing.

A previous version of this proposal introduced a `then` keyword to return a value from `if`/`switch`/`do` expressions:

```swift
let width = switch scalar.value {
    case 0..<0x80: 1
    case 0x80..<0x0800: 2
    case 0x0800..<0x1_0000: 3
    default: 
      log("this is unexpected, investigate this")
      then 4
}
```

This approach was taken by Java (with the keyword `yield`) when it introduced `switch` expressions.

This had the benefit of making the value of the overall expression more explicit, at the downside of a whole new contextual keyword. It also required a number of parsing rules to resolve ambiguities, and could lead to confusion when e.g. a newline separated `then` and a leading dot expression. It also required clarification that a `then` inside a nested `if` expression only applied to the value of the inner expression. A keywordless "last expression" rule has no possible ambiguity of interpretation.

It can be argued that the last expression without any indicator to mark the expression value explicitly in multi-statement expressions is subtle and can make code harder to read, as a user must examine branches closely to understand the exact location type of the expression value. On the other hand, this is lessened by the requirement that the `if` expression be used to either assign or return a value, and not found in arbitrary positions.

The introduction of a `then` keyword would set `if` expressions apart from functions. The presence of a `then` keyword in an `if` expression that was part of a single-expression function body would act _like_ a `return` but not exactly, causing cognitive load on the part of the reader.

Overall, the composable consistency between `if`/`switch`/`do` expressions, and function bodies, along with the "`return` means exiting _early_" benefits, weighs in favor of a last expression rule and against a `then` (or similar) keyword.

## Source compatibility

As discussed in detailed design, there are rare edge cases where this new rule may break source, but none have been found in the compatibility test suite. Where they do occur, backticks can be applied, and this fix will back deploy to earlier compiler versions.

## Effect on ABI stability

This proposal has no impact on ABI stability.

