# Opaque Parameter Declarations

* Proposal: [SE-NNNN](nnnn-opaque-parameters.md)
* Author: [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting review**

* Implementation: [apple/swift#40993](https://github.com/apple/swift/pull/40993) with the flag `-Xfrontend -enable-experimental-opaque-parameters`, [Linux toolchain](https://download.swift.org/tmp/pull-request/40993/798/ubuntu20.04/swift-PR-40993-798-ubuntu20.04.tar.gz), [macOS toolchain](https://ci.swift.org/job/swift-PR-toolchain-osx/1315/artifact/branch-main/swift-PR-40993-1315-osx.tar.gz)

## Introduction

Swift's syntax for generics is designed for generality, allowing one to express complicated sets of constraints amongst the different inputs and outputs of a function. For example, consider an eager concatenation operation that builds an array from two sequences:

```swift
func eagerConcatenate<Sequence1: Sequence, Sequence2: Sequence>(
    _ sequence1: Sequence1, _ sequence2: Sequence2
) -> [Sequence1.Element] where Sequence1.Element == Sequence2.Element
```

There is a lot going on in that function declaration: the two function parameters are of different types determined by the caller, which are captured by `Sequence1` and `Sequence2`, respectively. Both of these types must conform to the `Sequence` protocol and, moreover, the element types of the two sequences must be equivalent. Finally, the result of this operation is an array of the sequence's element type. One can use this operation with many different inputs, so long as the constraints are met: 

```swift
eagerConcatenate([1, 2, 3], Set([4, 5, 6]))  // okay, produces an [Int]
eagerConcatenate([1: "Hello", 2: "World"], [(3, "Swift"), (4, "!")]) // okay, produces an [(Int, String)]
eagerConcatenate([1, 2, 3], ["Hello", "World"]) // error: sequence element types do not match
```

However, when one does not need to introduce a complex set of constraints, the syntax starts to feel quite heavyweight. For example, consider a function that composes two SwiftUI views horizontally:

```swift
func horizontal<V1: View, V2: View>(_ v1: V1, _ v2: V2) -> some View {
  HStack {
    v1
    v2
  }
}
```

There is a lot of boilerplate to declare the generic parameters `V1` and `V2` that are only used once, making this function look far more complex than it really is. The result, on the other hand, is able to use an [opaque result type](https://github.com/apple/swift-evolution/blob/main/proposals/0244-opaque-result-types.md) to hide the specific returned type (which would be complicated to describe), describing it only by the protocols to which it conforms.

This proposal extends the syntax of opaque result types to parameters, allowing one to specify function parameters that are generic without the boilerplate associated with generic parameter lists. The `horizontal` function above can then be expressed as:

```swift
func horizontal(_ v1: some View, _ v2: some View) -> some View {
  HStack {
    v1
    v2
  }
}
```

Semantically, this formulation is identical to the prior one, but is simpler to read and understand because the inessential complexity from the generic parameter lists has been removed. It takes two views (the concrete type does not matter) and returns a view (the concrete type does not matter).

Swift-evolution threads: [Pitch for this proposal](https://forums.swift.org/t/pitch-opaque-parameter-types/54914), [Easing the learning curve for introducing generic parameters](https://forums.swift.org/t/discussion-easing-the-learning-curve-for-introducing-generic-parameters/52891), [Improving UI of generics pitch](https://forums.swift.org/t/improving-the-ui-of-generics/22814)

## Proposed solution

This proposal extends the use of the `some` keyword to parameter types for function, initializer, and subscript declarations. As with opaque result types, `some P` indicates a type that is unnamed and is only known by its constraint: it conforms to the protocol `P`. When an opaque type occurs within a parameter type, it is replaced by an (unnamed) generic parameter. For example, the given function:

```swift
func f(_ p: some P) { }
```

is equivalent to a generic function described as follows, with a synthesized (unnamable) type parameter `_T`:

```swift
func f<_T: P>(_ p: _T)
```

Note that, unlike with opaque result types, the caller determines the type of the opaque type via type inference. For example, if we assume that both `Int` and `String` conform to `P`,  one can call or reference the function with either `Int` or `String`:

```swift
f(17)      // okay, opaque type inferred to Int
f("Hello") // okay, opaque type inferred to String

let fInt: (Int) -> Void = f       // okay, opaque type inferred to Int
let fString: (String) -> Void = f // okay, opaque type inferred to String
let fAmbiguous = f                // error: cannot infer parameter for `some P` parameter
```

[SE-0328](https://github.com/apple/swift-evolution/blob/main/proposals/0328-structural-opaque-result-types.md) extended opaque result types to allow multiple uses of `some P` types within the result type, in any structural position. Opaque types in parameters permit the same structural uses, e.g.,

```swift
func encodeAnyDictionaryOfPairs(_ dict: [some Hashable & Codable: Pair<some Codable, some Codable>]) -> Data
```

This is equivalent to:

```swift
func encodeAnyDictionaryOfPairs<_T1: Hashable & Codable, _T2: Codable, _T3: Codable>(_ dict: [_T1: Pair<_T2, _T3>]) -> Data
```

Each instance of `some` within the declaration represents a different implicit generic parameter.

## Detailed design

There are a two main restrictions on the use of opaque parameter types. The first is that opaque parameter types can only be used in parameters of a function, initializer, or subscript declaration, and not in (e.g.) a typealias or any value of function type. For example:

```swift
typealias Fn = (some P) -> Void    // error: cannot use opaque types in a typealias
let g: (some P) -> Void = f        // error: cannot use opaque types in a value of function type
```

The second restriction is that an opaque type cannot be used in a variadic parameter:

```swift
func acceptLots(_: some P...)
```

This restriction is in place because the semantics implied by this proposal might not be the appropriate semantics if Swift gains variadic generics. Specifically, the semantics implied by this proposal itself (without variadic generics) would be equivalent to:

```swift
func acceptLots<_T: P>(_: _T...)
```

where `acceptLots` requires that all of the arguments have the same type:

```swift
acceptLots(1, 1, 2, 3, 5, 8)          // okay
acceptLots("Hello", "Swift", "World") // okay
acceptLots("Swift", 6)                // error: argument for `some P` could be either String or Int
```

With variadic generics, one might instead make the implicit generic parameter a generic parameter pack, as follows:

```swift
func acceptLots<_Ts: P...>(_: _Ts...)
```

In this case, `acceptLots` accepts any number of arguments, all of which might have different types:

```swift
acceptLots(1, 1, 2, 3, 5, 8)          // okay, Ts contains six Int types
acceptLots("Hello", "Swift", "World") // okay, Ts contains three String types
acceptLots(Swift, 6)                  // okay, Ts contains String and Int
```

## Source compatibility

This is a pure language extension with no backward-compatibility concerns, because all uses of `some` in parameter position are currently errors.

## Effect on ABI stability

This proposal has no effect on the ABI or runtime because it is syntactic sugar for generic parameters.

## Effect on API resilience

This feature is purely syntactic sugar, and one can switch between using opaque parameter types and the equivalent formulation with explicit generic parameters without breaking either the ABI or API. However, the complete set of constraints must be the same in such cases.

## Future Directions

This proposal composes well with idea that allows the use of generic syntax to specify the associated type of a protocol, e.g., where `Collection<String>`is "a `Collection` whose `Element` type is `String`". Combined with this proposal, one can more easily express a function that takes an arbitrary collection of strings:

```swift
func takeStrings(_: some Collection<String>) { ... }
```

Recall the complicated `eagerConcatenate` example from the introduction:

```func eagerConcatenate<Sequence1: Sequence, Sequence2: Sequence>(
func eagerConcatenate<Sequence1: Sequence, Sequence2: Sequence>(
  _ sequence1: Sequence1, _ sequence2: Sequence2
) -> [Sequence1.Element] where Sequence1.Element == Sequence2.Element
```

With opaque parameter types and generic syntax on protocol types, one can express this in a simpler form with a single generic parameter representing the element type:

```swift
func eagerConcatenate<T>(
    _ sequence1: some Sequence<T>, _ sequence2: some Sequence<T>
) -> [T]
```

And in conjunction with opaque result types, we can hide the representation of the result, e.g.,

```swift
func lazyConcatenate<T>(
    _ sequence1: some Sequence<T>, _ sequence2: some Sequence<T>
) -> some Sequence<T>
```

## Acknowledgments

If significant changes or improvements suggested by members of the 
community were incorporated into the proposal as it developed, take a
moment here to thank them for their contributions. Swift evolution is a 
collaborative process, and everyone's input should receive recognition!
