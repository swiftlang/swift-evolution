# `if` and `switch` expressions

* Proposal: [SE-NNNN](NNNN-if-switch-expressions.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift), [Hamish Knight](https://github.com/hamishknight)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [apple/swift#612178](https://github.com/apple/swift/pull/62178), including a downloadable toolchain.

## Introduction

This proposal introduces the ability to use `if` and `switch` statements as expressions, for the purpose of:
- Returning values from functions, properties, and closures;
- Assigning values to variables; and
- Declaring variables.

## Motivation

Swift has always had a terse but readable syntax for closures, which allows the `return` to be omitted when the body is a single expression. [SE-0255: Implicit Returns from Single-Expression Functions](https://github.com/apple/swift-evolution/blob/master/proposals/0255-omit-return.md) extended this to functions and properties with a single expression as their body.

This omission of the `return` keyword is in keeping with Swift's low-ceremony approach, and is in common with many of Swift's peer "modern" languages. However, Swift differs from its peers in the lack support for `if` and `switch` expressions.

In some cases, this causes ceremony to make a return (ahem), for example:

```swift
public static func width(_ x: Unicode.Scalar) -> Int {
  switch x.value {
    case 0..<0x80: return 1
    case 0x80..<0x0800: return 2
    case 0x0800..<0x1_0000: return 3
    default: return 4
  }
}
```

In other cases, a user might be tempted to lean heavily on the harder-to-read ternary syntax:

```swift
let bullet = isRoot && (count == 0 || !willExpand) ? ""
    : count == 0    ? "- "
    : maxDepth <= 0 ? "▹ " : "▿ "
```

Opinions vary on this kind of code, from enthusiasm to horror, but it's accepted that it's reasonable to find this syntax _too_ terse.

Another option is to use Swift's definite initialization feature:

```swift
let bullet: String
if isRoot && (count == 0 || !willExpand) { bullet = "" }
else if count == 0 { bullet = "- " }
else if maxDepth <= 0 { bullet = "▹ " }
else { bullet = "▿ " }
```

Not only does this add the ceremony of explicit typing and assignment on each branch (perhaps tempting overly terse variable names), it is only practical when the type is easily known. It cannot be used with opaque types, and is very inconvenient and ugly if the type is a complex nested generic.

Programmers less familiar with Swift might not know this technique, so they may be tempted to take the approach of `var bullet = ""`.  This is more bug prone where the default value may not be desired in _any_ circumstances, but definitive initialization won't ensure that it's overridden.

Finally, a closure can be used to simulate an `if` expression:

```swift
let bullet = {
    if isRoot && (count == 0 || !willExpand) { return "" }
    else if count == 0 { return "- " }
    else if maxDepth <= 0 { return "▹ " }
    else { return "▿ " }
}()
```

This also requires `return`s, plus some closure ceremony. But here the `return`s are more than ceremony – they require extra cognitive load to understand they are returning from a closure, not the outer function.

This proposal introduces a new syntax that avoids all of these problems:

```swift
let bullet =
    if isRoot && (count == 0 || !willExpand) { "" }
    else if count == 0 { "- " }
    else if maxDepth <= 0 { "▹ " }
    else { "▿ " }
```

Similarly, the `return` ceremony could be dropped from the earlier example:

```swift
public static func width(_ x: Unicode.Scalar) -> Int {
  switch x.value {
    case 0..<0x80: 1
    case 0x80..<0x0800: 2
    case 0x0800..<0x1_0000: 3
    default: 4
  }
}
```

Both these examples come from posts by [Nate Cook](https://forums.swift.org/t/if-else-expressions/22366/48) and [Michael Ilseman](https://forums.swift.org/t/omitting-returns-in-string-case-study-of-se-0255/24283), documenting many more examples where the standard library code would be much improved by this feature.


## Detailed Design

`if` and `switch` statements will be usable as expressions, for the purpose of:

- Returning values from functions, properties, and closures (either with implicit or explicit `return`);
- Assigning values to variables; and
- Declaring variables.

There are of course many other places where an expression can appear, including as a sub-expression, or as an argument to a function. This is not being proposed at this time, and is discussed in the future directions section.

For an `if` or `switch` to be used as an expression, it would need to meet these criteria:

**Each branch of the `if`, or each `case` of the `switch`, must be a single expression.**

Each of these expressions become the value of the overall expression if the branch is chosen.

This does have the downside of requiring fallback to the existing techniques when, for example, a single expression has a log line above it. This is in keeping with the current behavior of `return` omission.

An exception to this rule is if a branch either returns, throws, or traps, in which case no value for the overall expression need be produced.

**Each of those expressions, when type checked independently, must produce the same type.**

This has two benefits: it dramatically simplifies the compiler's work in type checking the expression, and it makes it easier to reason about both individual branches and the overall expression.

It has the effect of requiring more type context in ambiguous cases. The following code would _not_ compile:

```swift
let x = if p { 0 } else { 1.0 }
```

since when type checked individually, `0` is of type `Int` and `1.0`. The fix would be to disambiguate each branch. In this case, either by rewriting `0` as `0.0`, or by providing type context e.g. `0 as Double`.

This can be resolved by providing type context to each of the branches:

```swift
  let y: Float = switch x.value {
    case 0..<0x80: 1
    case 0x80..<0x0800: 2.0
    case 0x0800..<0x1_0000: 3.0
    default: return 4.5
  }
```

This decision is in keeping with other recent proposals such as [SE-0244: Opaque Result Types](https://github.com/apple/swift-evolution/blob/main/proposals/0244-opaque-result-types.md):

```swift
// Error: Function declares an opaque return type 'some Numeric', but the
// return statements in its body do not have matching underlying types
func f() -> some Numeric {
    if Bool.random() {
        return 0
    } else  {
        return 1.0
    }
}
```

This rule will require explicit type context for declarations in order to determine the type of `nil` literals:

```swift
// invalid:
let x = if p { nil } else { 2.0 }
// valid with required type context:
let x: Double? = if p { nil } else { 2.0 }
```

Of course, when returning from a function or assigning to an existing variable, this type context is always provided.

It is also in keeping with [SE-0326: Enable multi-statement closure parameter/result type inference]( https://github.com/apple/swift-evolution/blob/main/proposals/0326-extending-multi-statement-closure-inference.md):

```swift
func test<T>(_: (Int?) -> T) {}

// invalid
test { x in
  guard let x { return nil }
  return x
}

// valid with required type context:
test { x -> Int? in
  guard let x { return nil }
  return x
}
```

It differs from the behavior of the ternary operator (`let x = p ? 0 : 1.0` compiles, with `x: Double`).

However, the impact of bidirectional inference on the performance of the type checker would likely prohibit this feature from being implemented today, even if it were considered preferable. This is especially true in cases where there are many branches. This decision could be revisited in future: switching to full bidirectional type inference may be source breaking in theory, but probably not in practice (the proposal authors can't think of any examples where it would be).

Bidirectional inference also makes it very difficult to reason about each of the branches individuall, leading to sometimes unexpected results:

```swift
let x = if p {
  [1]
} else {
  [1].lazy.map(expensiveOperation)
}
```

With full bidirectional inference, the `Array` in the `if` branch would force the `.lazy.map` in the `else` branch to be unexpectedly eager.

**In the case of `if` statements, the branches must include an `else`**

This rule is consistent with the current rules for definitive initialization and return statements with `if` e.g.

```swift
func f() -> String {
    let b = Bool.random()
    if b == true {
        return "true"
    } else if b == false { // } else { here would compile
        return "false"
    }
} // Missing return in global function expected to return 'String'
```

This could be revisited in the future across the board (to DI, return values, and `if` expressions) if logic similar to that of exhaustive switches were applied, but this would be a separate proposal.

**The expression is not part of a result builder**

`if` and `switch` statements are already expressions when used in the context of a result builder, via the `buildEither` function. This proposal does not change this feature.

## Future Directions

This 

### Full Expressions

This proposal chooses a narrow path of only enabling these expressions in the 3 cases laid out at the start. An alternative would be to make them full-blown expressions everywhere.

A feel for the kind of expressions this could produce can be found in [this commit](https://github.com/apple/swift/compare/main...hamishknight:express-yourself#diff-7db38bc4b6f7872e5a631989c2925f5fac21199e221aa9112afbbc9aae66a2de) which adds this functionality to the parser.

This includes various fairly conventional examples not proposed here, but also some pretty strange ones such as `for b in [true] where switch b { case true: true case false: false } {}`.

The strange examples can mostly be considered "weird but harmless" but there are some source breaking edge cases, in particular in result builders:

```swift
var body: some View {
    VStack {
        if showButton {
            Button("Click me!", action: clicked)
        } else {
            Text("No button")
        }
        .someStaticProperty
    }
}
```

In this case, if `if` expressions were allowed to have postfix member expressions (which they aren't today, even in result builders), it would be ambiguous whether this should be parsed as a modifier on the `if` expression, or as a new expression. This could only be an issue for result builders, but the parser does not have the ability to specialize behavior for result builders. Note, this issue can happen today (and is why `One` exists for Regex Builders) but could introduce a new ambiguity for code that works this way today.

This proposal suggests keeping the initial implementation narrow, as assignment and returns are hoped to cover at least 95% of use cases. Further cases could be added in later proposals once the community has had a chance to use this feature in practice – including source breaking versions introduced under a language variant.

### Guard

Often enthusiasm for `guard` leads to requests for `guard` to have parity with `if`. Returning a value from a `guard`'s else is very common, and could potentially be sugared as

```swift
  guard hasNativeStorage else { nil }
```

This is appealing, but is really a different proposal, of allowing omission `return` in `guard` statements.

### Multi-statement branches

The requirement that every branch be just a single expression leads to an unfortunate usability cliff:

```swift
let decoded =
  if isFastUTF8 {
    Log("Taking the fast path")
    withFastUTF8 { _decodeScalar($0, startingAt: i) }
  } else
    Log("Running error-correcting slow-path")
    foreignErrorCorrectedScalar(
      startingAt: String.Index(_encodedOffset: i))
  }
```

This is consistent with other cases, like multi-statement closures. But unlike in that case, where all that is needed is a `return` from the closure, this requires the user refactor the code back to the old mechanisms.

The trouble is, there is no great solution here. The approach taken by some other languages such as rust is to allow a bare expression at the end of the scope to be the expression value for that scope. There are stylistic preferences for and against this. More importantly, this would be a fairly radical new direction for Swift, and if proposed should probably be considered for all such cases (like function and closure return values too).

### Either

As mentioned above, in result builders an `if` can be used to construct an `Either` type, which means the expressions in the branches could be of different types.

This could be done with `if` expressions outside result builders too, and would be a powerful new feature for Swift. However, it is large in scope (including the introduction of a language-integrated `Either` type) and should be considered in a separate proposal, probably after the community has adjusted to the more vanilla version proposed here.

## Alternatives Considered

### Sticking with the Status Quo

The list of [commonly rejected proposals](https://github.com/apple/swift-evolution/blob/main/commonly_proposed.md) includes the subject of this proposal:

> **if/else and switch as expressions**: These are conceptually interesting things to support, but many of the problems solved by making these into expressions are already solved in Swift in other ways. Making them expressions introduces significant tradeoffs, and on balance, we haven't found a design that is clearly better than what we have so far.

The motivation section above outlines why the alternatives that exist today fall short. One of the reasons this proposal is narrow in scope is to bring the majority of value while avoiding resolving some of these more difficult trade-offs.

The lack of this feature puts Swift's [claim](https://www.swift.org/about/) to be a modern programming language under some strain. It is one of the few modern languages (Go being the other notable exception) not to support something along these lines.

### Alternative syntax

tk

## Source compatibility

As proposed, this addition has no known source incompatabilities. Some of the future directions could result in source breaks – if proposed, the subset of functionality that causes these may need to be guarded under a language mode.

## Effect on ABI stability

This proposal has no impact on ABI stability.

## Acknowledgments

Much of this implementation layers on top of ground work done by [Pavel Yaskovich](https://github.com/xedin), particularly the work done to allow [multi-statement closure type inference](https://github.com/apple/swift-evolution/blob/main/proposals/0326-extending-multi-statement-closure-inference.md).

Both [Nate Cook](https://forums.swift.org/t/if-else-expressions/22366/48) and [Michael Ilseman](https://forums.swift.org/t/omitting-returns-in-string-case-study-of-se-0255/24283) provided analysis of use cases in the standard library and elsewhere. Many community members have made a strong case for this change, most recently [Dave Abrahams](https://forums.swift.org/t/if-else-expressions/22366).
