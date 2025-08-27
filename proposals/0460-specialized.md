# Explicit Specialization

* Proposal: [SE-0460](0460-specialized.md)
* Authors: [Ben Cohen](https://github.com/airspeedswift)
* Review Manager: [Steve Canon](https://github.com/stephentyrone)
* Status: **Implemented (Swift Next)**
* Review: ([pitch](https://forums.swift.org/t/pitch-explicit-specialization/76967)) ([review](https://forums.swift.org/t/se-0460-explicit-specialization/77541)) ([acceptance](https://forums.swift.org/t/accepted-se-0460-explicit-specialization/78583))

## Introduction

The Swift compiler has the ability to "specialize" a generic function at compile time. This specialization creates a custom implementation of the function, where the generic placeholders are substituted with specific types. This can unlock optimizations of that specialized function that can be dramatically faster than the unspecialized version in some circumstances. The compiler can generate this specialized version and call it when it can see at the call site with what concrete types a function is being called, and the body of the function to specialize.

In some cases, though, this information is obscured from the compiler. This proposal introduces a new attribute, `@specialized`, which allows the author of a generic function to generate pre-specialized versions of that function for specific types. When the unspecialized version of the function is called with one of those types, the compiler will generate code that will re-dispatch to those prespecialized versions if available.

## Motivation

Consider the following generic function that sums an array of any binary integer type:

```swift
extension Sequence where Element: BinaryInteger {
  func sum() -> Double {
    reduce(0) { $0 + Double($1) }
  }
}
```

If you call this function directly on an array of a specific integer type (e.g. `Array<Int>`):

```
let arrayOfInt: [Int] = // ...
let result = arrayOfInt.sum()
```

in optimized builds, the Swift compiler will generate a specialized version of `sum` for that type. 

If you inspect the binary, you will see this specialized version under a symbol `_$sST3sumSz7ElementRpzrlEAASdyFSaySiG_Tg5`, which demangles to `generic specialization <[Swift.Int]> of (extension in example):Swift.Sequence< where A.Element: Swift.BinaryInteger>.sum() -> Swift.Double`, alongside the unspecialized version.

This specialized version of `sum` will be optimized specifically for `Array<Int>`. It can move a pointer directly over the the array's buffer, loading the elements into registers directly from memory. On modern hardware, it can make use of dedicated instructions to convert the integers to floating point. It can do this because it can see the implementation of `sum`, and can see the exact types on which it is being called. What exact assembly instructions are generated will differ significantly between e.g. `Array<Int8>.sum` and `Array<UInt64>.sum`.

Here is that `Array<Int>`-specialized code when compiled to x86-64 with `swiftc -Osize`:

```assembly
_$sST3sumSz7ElementRpzrlEAASdyFSaySiG_Tg5:
        mov     rax, qword ptr [rdi + 16]
        xorpd   xmm0, xmm0
        test    rax, rax
        je      .LBB1_3
        xor     ecx, ecx
.LBB1_2:
        cvtsi2sd        xmm1, qword ptr [rdi + 8*rcx + 32]
        inc     rcx
        addsd   xmm0, xmm1
        cmp     rax, rcx
        jne     .LBB1_2
.LBB1_3:
        ret
```

Now consider some code that places an optimization barrier between the call site and the concrete type:

```swift
protocol Summable: Sequence where Element: BinaryInteger { }
extension Array: Summable where Element: BinaryInteger { }

var summable: any Summable

// later, when summable has been populated with an array of some kind of integer
let result = summable.sum()
```

The compiler now has no way of knowing what type `Summable` is at the call site – neither the sequence type, nor the element type. So its only option is to execute the fully unspecialized code. Instead of advancing a pointer over a buffer and loading values directly from memory, it must iterate the sequence by first calling `makeIterator()` and then calling `next()`, unwrapping optional values until it reaches `nil`.  And instead of using a single instruction to convert an `Int` to a `Double`, it must call the generic initializer on `Double` that uses methods on the `BinaryInteger` protocol to convert the value into floating point representation. Unsurprisingly, this code path will be about 2 orders of magnitude slower than the specialized version. This is true even if the actual type being summed ends up being `[Int]` at runtime.

A similar situation would occur when `sum` is a generic function in a binary framework which has not provided an `@inlinable` implementation. While the Swift compiler might know the types at the call site, it has no ability to generate a specialized version because it cannot see the implementation in order to generate it. So it must call the unspecialized version of `sum`.

The best way to avoid this situation is just to avoid type erasure in the first place. This is why concrete types and generics should be preferred whenever practical over existential types for performance-sensitive code. But sometimes type erasure, particularly for heterogenous storage, is necessary.

Similarly, ABI-stable binary framework authors do not always want to expose their implementations to the caller, as this tends to generate a very large and complex ABI surface that cannot be easily changed later. It also prevents upgrades of binary implementations without recompiling the caller, allowing for e.g. an operating system to fix bugs or security vulnerabilities without an app needing to be recompiled.

## Proposed solution

A new attribute, `@specialized`, will allow the author of a function to cause the compiler to generate specializations of that function. In the body of the unspecialized version, the types are first checked to see if they are of one of the specialized types. If they are, the specialized version will be called.

So in our example above:

```swift
extension Sequence where Element: BinaryInteger {
  @specialized(where Self == [Int])
  func sum() -> Double {
    reduce(0) { $0 + Double($1) }
  }
}
``` 

A specialized version of `[Int].sum` will be generated in the same way as if it had been specialized for a callsite. And inside the unspecialized generic code, the additional check-and-redispatch logic will be inserted at the start of the function.

Doing this restores the performance of the specialized version of `sum` (less a check and branch of the calling type) even when using the existential `any Summable` type.

## Detailed design

The `@specialized` attribute can be placed on any generic function. It takes an argument with the same syntax as a `where` clause for a generic signature. 

Multiple specializations can be listed:

```swift
extension Sequence where Element: BinaryInteger {
  @specialized(where Self == [Int])
  @specialized(where Self == [UInt32])
  @specialized(where Self == [Int8])
  func sum() -> Double {
    reduce(0) { $0 + Double($1) }
  }
}
```

Within the unspecialized function, redispatch will be based on the _exact_ type. That is, in pseudocode:

```swift
extension Sequence where Element: BinaryInteger {
  @specialized(where Self == [Int])
  @specialized(where Self == [Int8])
  func sum() -> Double {
    if Self.self == [Int].self {
      <execute specialization for [Int].sum()>
    } else if Self.self == [Int8].self {
      <execute specialization for [Int8].sum()>
    } else {
      reduce(0) { $0 + Double($1) }
    }
  }
}
```

(Note that this is just for illustrative purposes, the actual dispatch mechanism to the specific specialization may differ and change over time)

No attempt to implicitly convert the type is made (so for example, a specialization for `Int?` would not be executed when called on `Int`), nor is a specialization for a superclass executed when called with the generic type of the subclass.

These specializations are the same as the ones generated by the caller. They replace the dynamic dispatch of the unspecialized generic protocol with static dispatch to the methods on the concrete type, and this in turn unlocks other optimizations within the specialized function. Note that within these specializations, no different overload resolution takes place now that the concrete type is known. That is, the functions being called will be only those made available via the protocol witness table. This ensures that there is no _semantic_ effect from using `@specialized`, only a change in performance.

As well as protocol extensions, it can also be used on extensions of generic types, on computed properties (note, it must be put on `get` explicitly, not on the shorthand where it is elided), and on free functions:

```swift
extension Array where Element: BinaryInteger {
  @specialized(where Element == Int)
  func sum() -> Double {
    reduce(0) { $0 + Double($1) }
  }
  
  var product: Double {
    @specialized(where Element == Int8)
    get { reduce(1) { $0 * Double($1) } }
  }
}

@specialized(where T == Int)
func sum<T: BinaryInteger>(_ numbers: T...) -> Double {
  numbers.reduce(0) { $0 + Double($1) }
}
```

The `where` clause must fully specialize all the generic placeholders of the types in the function signature. In the case of a protocol extension, as seen above, that includes specifying `Self`. All placeholders must be fully specified even if they do not appear to be used in the function body:

```swift
extension Dictionary where Value: BinaryInteger {
  // error: Too few generic parameters are specified in 'specialize' attribute (got 1, but expected 2)
  // note: Missing equality constraint for 'Key' in 'specialize' attribute
  @specialized(where Value == Int)
  func sum() -> Double {
    values.reduce(0) { $0 + Double($1) }
  }
}
```

Bear in mind that even when not explicitly used in the body, they may be used implicitly. For example, in calculating the location of stored properties. Depending on how `Dictionary` is laid out, it may be important to know the size of the `Key` even if key values aren't used. But even if there is absolutely no use of a generic type in the body being specialized, the type must be explicitly specified. This requirement could be loosened in future, see "Partial Specialization" in future directions.

Where multiple placeholders need to be specified separately, they can be separated by commas, such as in the fix for the above example:

```swift
extension Dictionary where Value: BinaryInteger {
  @specialized(where Value == Int, Key == Int)
  func sum() -> Double {
    values.reduce(0) { $0 + Double($1) }
  }
}
```

## Source compatibility

The addition or removal of explicit specializations has no impact on the caller, and is opt-in. As such it has no source compatability implications.

## ABI compatibility

This proposal covers only _internal_ specializations, dispatched to from within the implementation of an unspecialized generic function. As such it has no impact on ABI. It can be applied to existing ABI-stable functions in libraries built for distribution, and can be removed later without ABI impact. Generic functions can continue to be inlinable to be specialized by the caller, and the code to dispatch to specialized versions will not appear in the inlinable code emitted into the swift interface file.

A future direction where explicit specializations are exposed as ABI appears in Future Directions.

## Implications on adoption

Explicit specializations impose no new runtime requirements on either the caller or the called function, so use of them can be back-deployed to earlier Swift runtimes.

## Future directions

### Partial Specialization

The need to fully specify every type when using `@specialized` is somewhat limiting. For example, in the `Dictionary` example above, no reference is made in the code to the `Key` type in summing the values. Having to explicitly state the concrete type for `Key` means you need separate specializations for `[String:Int]`, `[Int:Int]` and so on. 

Even in cases where dynamic dispatch through the protocol is still required for the unspecialized aspects (such as determining where to find the values in a dictionary's layout), this might not be in the hot part of the function and so partial specialization might be the better trade-off.

Closely related to partial specialization is the ability to specialize once for all particular type layouts. In the `Dictionary.sum` example, it might only matter what the size of the key type is in order to efficiently iterate the values.

Another example of this is `Array.append`. There is only one single implementation needed for appending an `AnyObject`-constrained to an array. The append operation needs to retain the object, but does not need any other properties. So two class instances could be appended using the same method irrespective of their actual type. Similar techniques could be used to provide shared specializations for `BitwiseCopyable` types, possibly with the addition of a supplied size argument to avoid having to use value witness calls.

### Making Symbols for Specializations Publicly Available

This proposal keeps entry points for explicit specializations internal only. Callers outside the module call the generic version of the function, which redispatches to the specialized version. For ABI-stable frameworks, a useful future direction would be to make these symbols publicly available and listed in the `.swiftinterface` file, for callers to link to directly. 

Doing this allows ABI-stable framework authors to expose specializations without exposing the full implementation details of a function as inlinable code. While adding a public specialized symbol to a framework is ABI, it is a much more limited ABI surface compared to providing an inlinable implementation, which requires any future changes to a type to consider the previous inlinable code's behavior to ensure it remains compatible forever in older binaries. A specialized entry point could be updated in a framework to fix a bug without recompiling the caller. Specializations in binary frameworks also have the benefit of avoiding duplication of code into the caller.

### Requiring Specialization

A related feature is the ability to _require_ specialization either at the call site, or on a protocol. Specialization does not always have to happen at the call site even when it could – it remains an optimization (albeit a very aggressively applied one currently). If the specializatino does not happen, it would be useful to force the compiler to override its heuristics, similar to forcing linlining of a long but critical function.

There are also protocols that are only meant to be used in specialized form in optimized builds. Arguably `BinaryInteger` is one of them. It may be worth exploring in these cases an annotation to indicate this to the caller, either via a compile-time errror/warning, or a runtime error.

### Marking types or extensions as `@specialized`

It may desirable to mark a number of generic functions "en-mass" as specialized for a particular type, by annotating either the type or an extension grouping.

This would mostly be just sugar for annotating each function individually. The exception could be annotation of classes or protocols where an entire specialized witness or vtable could then be passed around and used from other unspecialized functions.

### Tooling Directions

This proposal only outlines language syntax the developer can use to instruct the compiler to emit a specialized version of a function. Complimentary to this is development of tooling to identify profitable specializations to add, for example by profiling typical usage of an app. It should be noted that specialization is only required in highly performance sensitive code. In many cases, explicit specialization will have little impact on overall performance while increasing binary size. 

The current implementation requires the attribute to be attached directly to the function being specialized. Tooling to produce specializations would benefit from an additional syntax that could be added in a separate file, or even into a separately compiled binary.

## Alternatives considered

Many alternatives to this proposal – such as whole-program analysis to determine prespecializations automatically – are complimentary to this technique. Even in the presence of better optimizer heroics, there are still benefits to having explicit control over specialization.

This proposal takes as a given Swift's current dispatch mechanisms. Some alternatives to this proposal tend to end up requiring fundamental changes to Swift's core generics implementation, and are therefore out of scope for this proposal.

### Execution of custom functions based on type

Sometimes, it is desirable to execute not a compiler-generated specialization of a function, but a very different implementation based on the type:

```
extension Sequence where Element: BinaryInteger {
  func sum() -> Double {
    if let arrayOfInt = self as? [Int] {
      arrayOfInt.handVectorizedImplementation()
    } else {
      reduce(0) { $0 + Double($1) }
    }
  }
}
```

The specializations created by this proposal are entirely referentially transparent, using Swift's protocol dispatch semantics to ensure the only (reasonably )observable difference is how quickly the code runs. They are just optimizations where dynamic dispatch is replaced by static, code inlined, low-level optimizations applied to that code etc.

This is distinct from "when it's this type run this code, when it's that type, run that code", where this code and that code might do very different things semantically. You might not mean for them to differ semantically, but they can.

This is an interesting area to explore, but it's important to be clear that it's a very different feature (and hence not included in future directions).

