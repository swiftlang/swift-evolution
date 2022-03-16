# Enable multi-statement closure parameter/result type inference

* Proposal: [SE-0326](0326-extending-multi-statement-closure-inference.md)
* Author: [Pavel Yaskevich](https://github.com/xedin)
* Review Manager: [Ben Cohen](https://github.com/airspeedswift)
* Status: **Implemented (Swift 5.7)**
* Implementation: [apple/swift#38577](https://github.com/apple/swift/pull/38577), [apple/swift#40397](https://github.com/apple/swift/pull/40397), [apple/swift#41730](https://github.com/apple/swift/pull/41730)
* Decision Notes: [Rationale](https://forums.swift.org/t/accepted-se-0326-multi-statement-closure-parameter-result-type-inference/53502)

## Introduction

I propose to improve inference behavior of multi-statement closures by enabling parameter and result type inference from the closure body. This will make type inference less surprising for developers, and remove the existing behavior cliff where adding one more expression or statement to a closure could result in a compilation failure.

Swift-evolution thread: [[Pitch] Enable multi-statement closure parameter/result type inference](https://forums.swift.org/t/pitch-enable-multi-statement-closure-parameter-result-type-inference/52619)


## Motivation

Multi-statement closures, unlike their single-statement counterparts, currently cannot propagate information, e.g. parameter and result types from their body, back to the enclosing context, because they are type-checked separately from the expression containing the closure. Information in such closures flows strictly in one direction - from the enclosing context into the body, and statement by statement from the top to the bottom of the closure. 

Currently adding a new expression or statement to a single-statement closure could lead to surprising results. 

Let’s consider the following example:

```swift
func map<T>(fn: (Int) -> T) -> T {
  return fn(42)
}

func doSomething<U: BinaryInteger>(_: U) -> Void { /* processing */ }

let _ = map {
  doSomething($0)
}
```

Because single-statement closures are type-checked together with enclosing context, it’s possible to infer a type for generic parameter `T` based on the result type of a call to `doSomething`. The behavior is completely different if `doSomething` is not the only call in the body of the `map` closure:

```swift
let _ = map {
  logger.info("About to call 'doSomething(\$0)'")
  doSomething($0)
}
```

This closure is considered to a multi-statement closure, and currently the type inference behavior is different from the previous example. The body of a multi-statement closure is type-checked *after the* call to `map` has been fully resolved, which means that a type for generic parameter `T` could either a). not be determined at all (because it depends on the body of the closure); or b). be inferred to `Void` which is a type all single-expression closures could default to.

Neither a). nor b). could be considered an expected outcome in this case from the developer’s perspective because by looking at the code it’s unclear why a). the result type of the closure couldn’t be determined because `doSomething($0)` is a valid call and b). Where did `Void` come from and/or why default type has been applied. Another angle here is compiler diagnostics - because the body of the `map` closure is type-checked separately, it’s impossible to pinpoint the precise source of an error which leads to either mis-diagnosing the issue, e.g. `‘Void’ does not conform to ‘BinaryInteger’`, or a fallback diagnostic asking to specify type of the closure explicitly.

## Proposed solution

I propose to allow multi-statement closures to propagate information inferred from the body back to the expression it’s contained in. Such would unify semantics with their single-statement counterparts, remove the distinction from the language, remove artificial restrictions from parameter and result type inference, and help developers to write better and more expressive code. 

## Detailed design

Multi-statement closure inference would have the following semantics:

* Parameter and result type inference:
    * Contextual type of the closure is the primary source of type information for its parameters and return type.
    * If there is no contextual information, the first reference to an anonymous parameter defines its type for the duration of the context. If subsequent statements produce a different type, such situation is considered an ambiguity, and reported as an error;
    * Just like anonymous parameters, the first `return` statement defines the result type of the closure (inference is done only if there is no contextual information), if type-checker encounters `return` statements that produce different types such situation is considered an error.
    * `inout` inference from the body of a closure and back-propagation to the context is not supported - `inout` must be explicit on the parameter declaration or in the contextual type. This is a status quo behavior without source compatibility implications, and the least surprising for the developers albeit inconsistent with parameter type inference in single-statement closures. Please refer to the Future Directions section for the possibility of unifying this behavior.
    * `Void` is a default result type for a closure without any explicit `return` statements.
        * Single-expression closures are allowed to default to `Void` if enclosing context requires it e.g. `let _: (Int) → Void = { $0 }` unless `return` is explicit `let _: (Int) -> Void = { return $0 }` results in an error.
* The body of a closure is type-checked just like before, information flows one way, from the first statement to the last, without any backward propagation of information between statements.
    * This is important because in this model closure inference is consistent with other types of declarations: functions, subscripts, getters etc., and first type inferred from a declaration becomes its de facto type;
    * Type-checking of a closure that contains a single expression remains unchanged in this proposal.

Let’s go back to our example from `Motivation` section. 

```swift
func map<T: BinaryInteger>(fn: (Int) -> T) -> T {
  return fn(42)
}

func doSomething<U: BinaryInteger>(_: U) -> Void { /* processing */ }

let _ = map {
  logger.info("About to call 'doSomething(\$0)'")
  doSomething($0)
}
```

According to new unified semantics, it is possible to correctly type-check the closure argument to `map` and infer:

* Anonymous parameter `$0` to be `Int` type based on the expected argument type for the call to `doSomething`;
* Result type of the closure to be `Void` because there are no explicit `return` statements in the body.

Let’s consider another example which would be supported under new semantic rules:

```swift
struct Box {
  let weight: UInt
}

func heavier_than(boxies: [Box], min: UInt) -> [UInt] {
  let result = boxies.map {
    if $0.weight > min {
       return $0.weight
    }

    return 0
  }

  return result
}
```

Currently, because multi-statement closures are type-checked separately from the expression, it’s impossible to determine the result type of the closure. Things are made even worse because diagnostics can’t provide any useful guidance either and would only suggest to specify type of the closure explicitly. 

Under the new semantic rules, `result` would be type-checked to have a type of `[UInt]` because the first return statement `return $0.weight` is inferred as `UInt` and that type information is first propagated to the integer literal `0`  in the next return statement (because information flows from the first statement to the last), and back to the expression afterwards.

This could be extrapolated to a more complex expression, for example:

```swift
struct Box {
  let weight: UInt
}

func precisely_between(boxies: [Box], min: UInt, max: UInt) -> [UInt] {
  let result = boxies.map {
    if $0.weight > min {
       return $0.weight
    }

    return 0
  }**.filter {
    $0 < max
  }**

  return result
}
```

Use of multi-statement closures (or simply closures) becomes less cumbersome by removing the need to constantly specify explicit closure types which sometimes could be pretty large e.g. when there are multiple parameters or a complex tuple result type.

## Type-Checker Performance Impact

There were attempts to improve this behavior over the years, the latest one being https://github.com/apple/swift/pull/32223 by Doug Gregor. All of them ran into technical difficulties related to internal limitations of the type-checker, because multi-statement closures, just like function/subscript/setter bodies, tend be composed of a substantial number of statements and cannot be efficiently type-checked the same way as single-expression closures are, which leads to “expression too complex” errors. These issues are resolved by new implementation that takes a more incremental approach.

## Source compatibility

All of the aspects of a single-statement closure type-checking are preserved as-is by this proposal, so there is no source compatibility impact for them. 

There is at least one situation where type-checker behavior differs between single- and multi-statement closures because multi-statement do not support parameter type inference from the body. Some of the expressions that used to fail type-check (due to ambiguity) with single-statement closure argument, but type-checked with multi-statement, would now become ambiguous regardless of type of the closure used.

Let’s consider a call to an overloaded function `test` that expects a closure argument:

```swift
func test<PtrTy, R>(_: (UnsafePointer<PtrTy>) -> R) -> R { ... }
func test<ResultTy>(_: (UnsafeRawBufferPointer) -> ResultTy) -> ResultTy { ... }

let _: Int = test { ptr in
  return Int(ptr[0]) << 2
}
```

Currently call to `test` is ambiguous because it’s possible to infer that `PtrTy` is `Int` from the body of the (single-statement closure) closure, so both overloads of `test` produce a valid solution. The situation is different if we were to introduce a new, and possibly completely unrelated, statement to this closure e.g.:

```swift
func test<PtrTy, R>(_: (UnsafePointer<PtrTy>) -> R) -> R { ... }
func test<ResultTy>(_: (UnsafeRawBufferPointer) -> ResultTy) -> ResultTy { ... }

let _: Int = test { ptr in
  print(ptr) // <-- shouldn't affect semantics of the body
  return Int(ptr[0]) << 2
}
```

This new call to `test` type-checks because the body of this multi-statement closure under current language rules doesn’t participate in the type-check, so there is no way to infer `PtrTy` from the first overload choice. Under the proposed rules type-checker would be able to determine that `PtrTy` is `Int` based on `return` statement just like it did in the previous single-statement closure example, which means that call to `test` becomes ambiguous just like it did before introduction of `print`.

There are a couple of ways to mitigate situations like this:

* Add a special ranking rule to type-checker that preserves current behavior by rejecting solutions where parameter type has unresolved (either completely or partially unresolved) parameter and/or result types and argument is a multi-statement closure in favor of an overload choice with “less generic” type e.g. one that only has an unresolved result type.
* Ask users to supply an explicit type for a parameter and/or result type that unambiguously determines the overload e.g. `UnsafePointer<Int>` or `UnsafeRawBufferPointer` in our example.
* Don’t do any parameter and/or result type inference from the body of the closure. This is exactly how current multi-statement closures are type-checked under existing rules, which is too restrictive.

## Future Directions

### `inout` inference without a contextual type

There is an inconsistency between single- and multi-statement closures - `inout` inference from the body of a multi-statement closure and its back-propagation is unsupported and requires explicit parameter annotation e.g.  `{ (x: inout Int) -> Void in ... }` . 

Currently `inout` is allowed to be inferred:

* From contextual type for anonymous and name-only parameters e.g. `[1, 2].reduce(into: 0) { $0 += $1 }`. In this case `inout` is passed down to the body from the contextual type - `(inout Result, Self.Element) → Void`, so inference only happens one way.
* For single-statement closures it’s possible to infer `inout` of the external parameter type (visible to the expression closure is associated with) based on its use in the body - assignment, operators, in argument positions with explicit `&`.

Back-propagation behavior, second bullet, is inconsistent across different kinds of closures (it works only for single-statement closures). This is confusing because there are no visual clues for the developers to reason about the behavior, and easily fixed by providing explicit closure type. 

To make incremental progress, I think it’s reasonable to split `inout` changes from this proposal, because of uncertainty of source compatibility impact (that might be too great for such change to be reasonable for the language) unification of this behavior between single- and multi-statement closures could be a future direction for Swift 6. Doing so would allow to improve closure ergonomics without source compatibility impact, and take advantage of the new implementation to improve result builder and code completion performance and reliability.

### Type inference across `return` statements in the body of a closure

It’s common to have situations where an early `guard` statement returns `nil` that doesn’t supply enough type information to be useful for inference under the proposed rules:

```swift
func test<T>(_: () -> T?) { ... }

test {
  guard let x = doSomething() else {
     return nil // there is not enough information to infer `T` from `nil`
  }
  
  ...
}
```

Only way to get this closure to type-check is to supply explicit type e.g. `() -> Int? in ...`. To improve this situation type-checker could allow type inference across `return` statements in the body of a closure. That would mean that the actual type of the result would be a join between all of the types encountered in `return` statements, which is going to be semantically unique for the language.


## Effect on ABI stability

No ABI impact since only type-checker handling of closures is going to change but outcomes should not.


## Effect on API resilience

This is not an API-level change and would not impact resilience.


## Alternatives considered

Keep current behavior.


## Acknowledgments

Holly Borla - for helping with content and wording of this proposal.
