# Default Generic Arguments 

* Proposal: [SE-NNNN](XXXX-default-generic-arguments.md)
* Author: [Srdan Rasic](https://github.com/srdanrasic)
* Review manager: TBD
* Status: TBD

## Introduction

Generics are one of the most powerful features of Swift. They enable us to write code that operates on various types while providing compile-time type safety. Sometimes it is natural for generic code to often operate on the same type, but currently this is not facilitated by the language. This proposal introduces default generic arguments.

## Motivation

In some scenarios, a generic argument is often fulfilled by the same type. Consider the following type from popular reactive frameworks:

```swift
struct Signal<T, E: Error> {}
```

Such type is more often than not used with the second argument set to a non-instantiable `NoError` type:

```swift
let message: Signal<String, NoError>
```

It would be convenient if the second argument could be defaulted to the `NoError` type so that the previous declaration can look like:

```swift
let message: Signal<String>
```

Supporting default arguments would make the typical declarations clean and concise while allowing more specific declarations when needed.   

Additionally, the feature would allow developers to introduce new generic arguments to existing types without causing source-breaking changes.

## Current Workaround

Some of the problems can currently be partially solved by introducing a typealias that fulfils the generic argument.

```swift
typealias NonFailableSignal<T> = Signal<T, NoError>
```

This solution, however, requires tackling into the realm of the hardest problems in computer science - naming. It is often hard to find appropriate name for the partial specialisation of a multi-argument generic type. Additionally, in most cases the solution does not share overall feel of the programming language.

Similar partial solution can be achieved by subclassing, but it shares same disadvantages as typealiases and is limited to class types only.

## Proposed Solution

Allow setting default types to generic arguments in type and function declarations. This proposal suggests syntax inspired by default values of function arguments. 

### Declaration

Default generic type specialization would follow generic argument declaration, separated by the equality sign:

```swift
struct X<T = Int> {}
```

In case of multiple generic arguments, it would be possible to default last *N* arguments where *N* is less than or equal to the total number of arguments:

```swift
struct X<T, U = Int> {}
struct X<T = Int, U = Int> {}
```

Defaulting `T`, but not `U` would not be permitted as declaring an instance of such type would ambiguous since the arguments are index-based.

When an argument is constrained, default type specialization would be placed after the constraint:

```swift
struct X<T: P = Int> {}
```

Providing a default generic argument in the function signature would follow the same pattern.

```swift
func foo<X: P = Int>(x: X) -> X
```  

### Usage

When declaring an instance of generic type with default arguments following cases are worth considering:

(I) By not specialising any generic argument one lets the compiler specialize them. No empty angle brackets are needed in that case.

(II) By specialising first *N* arguments, one lets the compiler specialize the remaining arguments.

Given the type

```swift
struct X<T = Int, U = Float, V = Double> {}
```

following will be assumed unless something else is inferred from the context:


```swift
X 							// assumes X<Int, Float, Double>
X<Int32> 					// assumes X<Int32, Float, Double>
X<Int32, Int64> 			// assumes X<Int32, Int64, Double>
X<Int32, Int64, Int128> 	// assumes X<Int32, Int64, Int128>
```

It would not be possible to specialise argument at index *i* without specialising all prior arguments (those at indices less than *i*) due to arguments being index-based.

### Implications on Type Inference

How defaults interact with the type inference has been mostly discussed aspect of this proposal. There are number of cases important to consider.

Following type will be used in the examples that follow.

```swift
struct Foo<T = Int64> {
    init(t: T? = nil)
}
```

#### 1. No Context

*Calling a generic function or an initializer in a context that does not provide any hint to the argument types will result in using the __default__ type.*

In case if a variable or a property is not explicitly given a type and there are no values passed to the initializer from which the type of generic argument could be inferred, default type of the argument will be used:

```swift
let foo = Foo()				// infers type to Foo<Int64>
```

Similarly, if a variable is given a type, but generic argument is omitted, default will be used in case of no additional context on the right side:

```swift
let foo: Foo = Foo() 		// infers type to Foo<Int64>
```

When declaring a function whose arguments and/or return type are of generic type with generic arguments omitted, the compiler will always assume default type.

```swift
func x(foo: Foo) -> Foo {} 	// assumes Foo<Int64>
```

Same will be assumed for an enum case with associated value of generic type with generic arguments omitted.

```swift
enum X {
	case foo(Foo) 			// assumes Foo<Int64>
}
```

#### 2. Explicit Context

*Calling a generic function or an initializer in a context from which the argument types can be unambiguously inferred will result in using the __inferred__ types regardless of the default type.*

The basic example would be initializing a variable of explicitly defined type.

```swift
let foo: Foo<Int> = Foo(5) 		// infers right side to Foo<Int>
```

Explicit context can also be provided by a function argument or return types.

```swift
func x() -> Foo<String> {
  return Foo()					// infers instance type to Foo<String>
}
```

When declaring a function, its argument and return types are not affected by type inference so they provide explicit context for the code of function body.

```swift
func x() -> Foo {				// assumes Foo<Int64>, provides explicit context for the body
  return Foo(5)					// infers instance type to Foo<Int64>
}
```


#### 3. Loose Context (Defaults Mismatch)

There are cases when the context is not explicit, but provides a hint about the type that's in a conflict with the default type. Such cases revolve around literal convertibles. The problem can be demonstrated by the following example:

```swift
// example I
let foo = Foo(5)
```

Here we have the context hinting that the type could be inferred to `Int` while the default hints to `Int64`.

Similar example, but with the difference that the hinted types are unrelated would be:

```swift
// example II
let foo = Foo("abc")
```

In this case we have the context hinting that the type could be inferred to `String` while the default hints to `Int64`.

Solving the problem of what type gets inferred in those cases has been a topic of long discussions. Same problem has also been observed and [discussed](https://internals.rust-lang.org/t/interaction-of-user-defined-and-integral-fallbacks-with-inference/2496) in the development of Rust language. Author suggested following strategies:

* **Unify All (UA)**: Always specialize the variables with all defaults. This is the conservative choice in that it gives an error if there is any doubt.

* **Prefer Literal (PL)**: Always prefer the literal type. This is the maximally backwards compatible choice, but it leads to very surprising outcomes.

* **Prefer User (PU)**: Always prefer the user-defined choice. This is simple from one point of view, but does lead to a potentially counterintuitive result for example II.

* **Do What I Mean (DWIM)**: Prefer the user-defined default, but fallback to the literal type if the literal type is unrelated to the user-defined default (example II). This is more complex, but leads to sensible results on both examples.

Applying those strategies to our examples gives following outcomes:

| Strategy       	   | Example I  | Example II |
| ---------------------| ---------- | ---------- |
| Unify All      	   | Error      | Error      |
| Prefer Literal		   | Int        | String     |
| Prefer User  		   | Int64      | Error      |
| Do What I Mean       | Int64      | String     |


*Unify All* seems to be the least favourable strategy as it requires the user to be explicit in many cases where the outcome is obvious. That goes directly against the overall look and feel of the language so only the remaining three strategies have been considered. 

*Prefer Literal* would allow user to introduce a default to an **existing** type argument without causing source-breaking changes.

```swift
// before
func foo<T>(input: T)
foo(0) // Int

// after
func foo<T = Int64>(input: T)
foo(0) // Int
```

However, this is in direct conflict with the pattern that would allow user to introduce a **new** generic type argument without causing source-breaking changes.

```swift
// before
func foo(input: Int64)
foo(0)  // Int64

// after
func foo<T=Int64>(input: T)
foo(0) // Int64
```

Such pattern is supported by *Prefer User* strategy and has been broadly accepted in discussions of this proposal as the most important aspect of default generic arguments.

*Prefer User*, however, has a drawback that it fails in cases where the literal is unrelated to the user-defined default when it's obvious what the outcome should be, as depicted by *example II*.

*This proposal thus proposes implementing Do What I Mean strategy for resolving such mismatches. It favours the user-default, but falls back to literal in cases where default makes no sense. It also seems more consistent with other language aspects that allow the user to write concise and non overly explicit code.*

By applying *Do What I Mean* our examples get most reasonable solutions.

```swift
let foo = Foo(5)		// inferred to Int64
let foo = Foo("abc")	// inferred to String
```

It's worth noting, that by applying *Do What I Mean* (or *Prefer User*) strategy one can still introduce defaults to existing arguments without making source-breaking changes as long as the chosen default is not a literal convertible or a supertype of another type.

## Impact on Existing Code

None. This feature is strictly additive and does not break any existing code. Using this feature, however, allows developers to introduce source-breaking changes by adding defaults to existing arguments.

## Alternatives Considered

If generic arguments would have labels like their function counterparts, it would be possible to default and declare any combination of arguments. However, since it is very rare that generic types have more than two or three arguments, such feature is deemed redundant.

It was suggested that empty angle brackets should be required in cases where user accepts all default arguments. Further discussions concluded that empty angle brackets do not convey any valuable information to readers and maintainers of the code so such requirement is not proposed.

When resolving defaults mismatches, strategy *Prefer User* was considered as a more conservative approach that could later be evolved into *Do What I Mean*. It was, however, presumed to be intolerable because of wide use of literals in Swift code. 

## Acknowledgments

Thanks to Alexis Beingessner for elaborating and working out issues around defaults mismatches and for sharing his experience from Rust development.
