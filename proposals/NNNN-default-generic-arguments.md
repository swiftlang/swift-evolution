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

## Current Workaround

The problem can be partially solved by introducing a typealias that fulfils the generic argument.

```swift
typealias NonFailableSignal<T> = Signal<T, NoError>
```

This solution, however, requires tackling into the realm of the hardest problems in computer science - naming. It is often hard to find appropriate name for the partial specialisation of a multi-argument generic type. Additionally, in most cases the solution does not share overall feel of the programming language.

Similar partial solution can be achieved by subclassing, but it shares same disadvantages as typealiases and is limited to class types only.

## Proposed Solution

Allow setting default types to generic arguments in type and function declarations. This proposal suggests syntax inspired by default values of function arguments. 

### Declaration

Default generic type specialisation would follow generic argument declaration, separated by the equality sign:

```swift
struct X<T = Int> {}
```

In case of multiple generic arguments, it would be possible to default last *N* arguments where *N* is less than or equal to the total number of arguments:

```swift
struct X<T, U = Int> {}
struct X<T = Int, U = Int> {}
```

Defaulting `T`, but not `U` would not be permitted as declaring an instance of such type would ambiguous since the arguments are index-based.

When an argument is constrained, default type specification would be placed after the constraint:

```swift
struct X<T: P = Int> {}
```

Providing a default generic argument in the function signature would follow the same pattern.

```swift
func foo<X: P = Int>(x: X) -> X
```  

### Usage

When declaring an instance of generic type with default arguments following cases are worth considering:

(I) By not specialising any generic argument one accepts all default argument types. No empty brackets are needed in that case.

(II) By specialising first *N* arguments, one accepts the default argument types of the remaining arguments.

Given the type

```swift
struct X<T = Int, U = Float, V = Double> {}
```

following is assumed:


```swift
let x: X 						// assumes X<Int, Float, Double>
let x: X<Int32> 				// assumes X<Int32, Float, Double>
let x: X<Int32, Int64> 			// assumes X<Int32, Int64, Double>
let x: X<Int32, Int64, Int128> 	// assumes X<Int32, Int64, Int128>
```

It would not be possible to specialise argument at index *i* without specialising all prior arguments (those at indices less than *i*) due to arguments being index-based.

### Implications on Type Inference

How defaults interact with the type inference has been mostly discussed aspect of this proposal. There is a number of cases important to consider.

Following type will be used in the examples in next sections.

```swift
struct Foo<T = Int64> {
    init(t: T? = nil)
}
```

#### 1. Type Declarations

*No type inference will happen in type declarations. By omitting generic arguments one accepts the defaults.*

a) When declaring a property of generic type and omitting generic argument, the compiler will assume default type.

```swift
class X {
	let foo: Foo			// assumes Foo<Int64>
}
```

b) When declaring a variable or a constant of generic type and omitting generic argument, the compiler will assume default type.

```swift
let foo: Foo = ...			// assumes Foo<Int64>
```

Note that `Foo<Int64>` will be assumed regardless of what is on the right side of the expression. The compiler will throw an error in case of an incompatible type on the right side.

```swift
let foo: Foo = Foo(Int(5)) 	// error: Cannot assign Foo<Int> to Foo<Int64>.
```

To solve this, user would have to either declare the constant as `let foo: Foo<Int>` or completely drop the type declaration and let the compiler infer the type as described in the next section of the proposal.  

c) When declaring a function whose arguments and/or return type are of generic type with generic argument omitted, the compiler will assume default type.

```swift
func x(foo: Foo) -> Foo {} 	// assumes Foo<Int64>
```

d) When declaring an enum case with associated value of generic type with generic argument omitted, the compiler assumes default type.

```swift
enum X {
	case foo(Foo) 			// assumes Foo<Int64>
}
```

#### 2. Explicit Context

*Calling a generic function or an initializer in a context from which the argument types can be unambiguously inferred will result in using the __inferred__ types.*

The basic example would be initializing a variable of explicitly defined type.

```swift
let foo: Foo<Int64> = Foo(5) 	// infers right side to Foo<Int64>
```

As defined in previous section, a type declaration with omitted generic argument that has a default is still considered to explicitly define a type so following will also work:

```swift
let foo: Foo = Foo(5) 			// infers right side to Foo<Int64>
```

Explicit context can also be provided by a function arguments or return types.

```swift
func x() -> Foo<String> {
  return Foo()					// infers instance type to Foo<String>
}
```

```swift
func x() -> Foo {
  return Foo()					// infers instance type to Foo<Int64>
}
```

#### 3. Empty Context

*Calling a generic function or an initializer in a context that does not provide any hint to the argument types will result in using the __default__ type.*

```swift
let foo = Foo() 	// infers type to Foo<Int64>
```

#### 4. Loose Context and Defaults Mismatch

There are cases when the context might provide a hint about the type that's in a conflict with the default type. Those cases revolve around literal convertibles.

When a type suggested by the context is unrelated to the default argument, compiler will infer the suggested type.

```swift
let foo = Foo("abc") 	// infers type to Foo<String>
```

However, when the type in related, compiler will throw a fix-it.

```swift
let foo = Foo(5) 		// fix-it: Did you mean ‘Foo(5 as Int)’?
```

Hinted type `Int` is related to the default type `Int64` because both are conforming to `ExpressibleByIntegerLiteral` protocol. Integer literals are by default inferred to `Int`, but they can also be used to initialize anything conforming to `ExpressibleByIntegerLiteral`, like `Int64` in the example.

In order to avoid any confusion, the user should explicitly resolve such ambiguities.

## Impact on Existing Code

None. This functionality is strictly additive and does not break any existing code.


## Alternatives Considered

If generic argument would have labels like their function counterparts, it would be possible to default and declare any combination of arguments. However, since it is very rare that generic types have more than two or three arguments, such feature is deemed redundant.