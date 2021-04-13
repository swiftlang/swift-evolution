# `#if` for postfix member expressions

* Proposal: [SE-0308](0308-postfix-if-config-expressions.md)
* Authors: [Rintaro Ishizaki](https://github.com/rintaro)
* Review Manager: [Saleem Abdulrasool](https://github.com/compnerd)
* Implementation: https://github.com/apple/swift/pull/35097
* Status: **Active Review (April 5, 2021...April 16, 2021)**

## Introduction

Swift has conditional compilation block `#if ... #endif` which allows code to be conditionally compiled depending on the value of one or more compilation conditions. Currently, unlike `#if` in C family languages, the body of each clause must surround complete statements. However, in some cases, especially in result builder contexts, demand for applying `#if` to partial expressions has emerged. This proposal expands `#if ... #endif` to be able to surround postfix member expressions.

## Motivation

For example, when you have some SwiftUI code like this:

```swift
VStack {
  Text("something")
#if os(iOS)
    .iOSSpecificModifier()
#endif
    .commonModifier()
}
```

This doesn’t parse today, so you end up having to do something like:

```swift
VStack {
  let basicView = Text("something")
#if os(iOS)
  basicView
    .iOSSpecificModifier()
    .commonModifier()
#else
  basicView
    .commonModifier()
#endif
}
```

which is ugly and has duplicated `.commonModifier()`. If you want to eliminate the duplication:

```swift
VStack {
  let basicView = Text("something")
#if os(iOS)
  let tmpView = basicView.iOSSpecificModifier()
#else
  let tmpView = basicView
#endif
  tmpView.commonModifier()
}
```

...which is even uglier.

## Proposed solution

This proposal expands `#if` functionality to postfix member expressions. For example, in the following example:

```swift
baseExpr
#if CONDITION
  .someOptionalMember?
  .someMethod()
#else
  .otherMember
#endif
```

If `CONDITION` evaluates to `true`, the expression is parsed as

```swift
baseExpr
  .someOptionalMember?
  .someMethod()
```

Otherwise, it’s parsed as

```
baseExpr
  .otherMember
```

## Detailed design

### Grammar changes

This proposal adds `postfix-ifconfig-expression` to `postfix-expression`. `postfix-ifconfig-expression`
is a postfix-expression followed by a `#if ... #endif` clause.

```diff
+ postfix-expression → postfix-ifconfig-expression
+ postfix-ifconfig-expression → postfix-expression conditional-compilation-block
```

 `postfix-ifconfig-expression` is parsed only if the body of the `#if` clause starts with a period (`.`) followed by a identifier, a keyword or an integer-literal. For example:

```swift
// OK
baseExpr
#if CONDITION_1
  .someMethod()
#else
  .otherMethod()
#endif
```

 But the following is not a `postfix-ifconfig-expression` because it does not start with `.`. In such cases, `#if ... #endif` is not considered a part of the expression, but is parsed as a normal compiler control statement.

```swift
// ERROR
baseExpr      // warning: expression of type 'BaseExpr' is unused.
#if CONDITION
  { $0 + 1  } // error: closure expression is unused
#endif

baseExpr      // warning: expression of type 'BaseExpr' is unused.
#if CONDITION
  + otherExpr // error: unary operator cannot be separated from its operand
#endif
```

Also, the body must not contain any other characters after the expression.

```swift
// ERROR
baseExpr
#if CONDITION_1
  .someMethod()

print("debug") // error: unexpected tokens in '#if' expression body
#endif
```

### Expression kind inside `#if`/`#elseif`/`#else` body

There are several kinds of postfix expressions in Swift grammar.

* initializer expression
* postfix self expression
* explicit member expression
* function call expression
* subscript expression
* forced value expression
* optional chaining expression
* postfix operator expression

The body of a postfix `#if` expression must start with an explicit member expression, initializer expression, or postfix self expression (that is, the suffixes that begin with `.`).  Once started this way, you can continue the expression with any other postfix expression suffixes.  For example:

```swift
// OK
baseExpr
#if CONDITION_1
  .someMember?.otherMethod()![idx]++
#else
  .otherMethod(arg) {
    //...
  }
#endif
```

However, you cannot continue the expression within the `#if` with non-postfix suffixes.  For example, you cannot continue it with a binary operator, because a binary expression is not a postfix expression:

```swift
// ERROR
baseExpr
#if CONDITION_1
  .someMethod() + 12 // error: unexpected tokens in '#if' expression body
#endif
```

Starting with other postfix expression suffixes besides those beginning with `.` is not allowed because this would be ambiguous with starting a new statement.  These suffixes are generally required to start on the same line as the base expression.

### `#elseif`/`#else` body

While the body of the `#if` clause must begin with `.`, the body of any `#elseif` or `#else` clauses can be empty.

```swift
// OK
baseExpr
#if CONDITION_1
  .someMethod()
#elseif CONDITION_2
  // OK. Do nothing.
#endif
```

If the clause is not empty, then it has the same requirements as the `#if` clause: it must begin with a postfix expression suffix starting with `.`, it may not continue into a non-postfix expression, and it must not contain an unrelated statement.

```swift
// ERROR
baseExpr
#if CONDITION_1
  .someMethod()
#else
return 1 // error: unexpected tokens in '#if' expression body
#endif
```

### Consecutive postfix `#if` expressions

`#if ... #endif` blocks for postfix expression can be followed by an additional postfix expression including another `#if ... #endif`:

```swift
// OK
baseExpr
#if CONDITION_1
  .someMethod()
#endif
#if CONDITION_2
  .otherMethod()
#endif
  .finalizeMethod()
```

### Nested `#if` blocks

Nested `#if` blocks are supported as long as the first body starts with an explicit member-like expression. Each inner `#if` must follow the rule for `postfix-ifconfig-expression` too.

```swift
// OK
baseExpr
#if CONDITION_1
  #if CONDITION_2
    .someMethod()
  #endif
  #if CONDITION_3
    .otherMethod()
  #endif
#else
  .someMethod()
  #if CONDITION_4
    .otherMethod()
  #endif
#endif
```

### Postfix `#if` expression inside another expression

Postfix `#if` expressions can be nested inside another expression or statement.

```swift
// OK
someFunc(
  baseExpr
    .someMethod()
#if CONDITION_1
    .otherMethod()
#endif
)
```

This is parsed as `someFunc(baseExpr.someMethod().otherMethod())` or `someFunc(baseExpr.someMethod())` depending on the condition.

## Source compatibility

This proposal does not have any source breaking changes.

```swift
baseExpr
#if CONDITION_1
  .someMethod()
#endif
```

This is currently parsed as

```swift
baseExpr
#if CONDITION_1.someMethod()
#endif
```

And it is error because `CONDITION_1.someMethod()` is not a valid compilation condition. This proposal changes the parser behavior so `.someMethod()` is *not* parsed as a part of the condition. As a bonus, this new behavior applies to non-postfix `#if` expressions too. Consequently,

```swift
enum MyEnum { case foo, bar, baz }

func test() -> MyEnum {
#if CONDITION_1
  .foo
#elseif CONDITION_2
  .bar
#else
  .baz
#endif
}
```

Now becomes valid swift code. This change doesn’t break anything because explicit member expressions have always been invalid at the compilation condition position.

## Effect on ABI stability

This change is frontend-only and would not impact ABI.

## Effect on API resilience

This is not an API-level change and would not impact resilience.

## Alternatives considered

### Lexer based `#if` preprocessing

Like C-family languages, we could pre-process conditional compilation directives purely in Lexer level as discussed in https://forums.swift.org/t/allow-conditional-inclusion-of-elements-in-array-dictionary-literals/16171/29. Although it is certainly a design we should explore some day, in this proposal, we would like to focus on expanding `#if` to postfix expressions.

