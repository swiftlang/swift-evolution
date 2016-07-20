# Variadics as Attribute

* Proposal: [SE-NNNN](nnnn-variadics-as-attribute.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal seeks to redesign the current, unique variadic function declaration syntax to use an attribute instead, with a goal of unifying standard and variadic function declarations.

Swift-evolution thread: [Discussion thread topic](http://thread.gmane.org/gmane.comp.lang.swift.evolution/23303)

## Motivation

Variadics are essentially a call-site feature enabling a function to be called as if it being provided with multiple arguments, rather than a single list argument. However instead of being implemented as some kind of switch, variadics have a unique declaration syntax that separates them uncessarily from standard function declarations.
Currently this also means that redundancy is required in order to allow a function to be called both with an explicit array, and in the variadic style.

## Proposed solution

To unify both regular and variadic function declarations this proposal seeks to replace the unique trailing elipsis declaration syntax with a new `@variadic` attribute on regular function declarations, enabling optional variadic syntax at the call site.

In short this proposal would replace:
```
func someFunc(_ values:Int...) { … }
```
With the following:
```
func someFunc(_ values:@variadic [Int]) { … }
```

## Detailed design

The trailing elipsis declaration syntax will be removed, with a fixit providing a replacement to the new attribute-based syntax. The new `@variadic` attribute can be placed on any one function parameter with a type of `Array<Foo>` (or `[Foo]`), enabling the optional use of variadic declaration at the call site.

For example:
```
func someFunc(_ values:@variadic [Int]) { … }
```
Can be called in any of the following forms:
```
someFunc(1, 2, 3, 4, 5)   // Fixed length variadic call
someFunc([1, 2, 3, 4, 5]) // Fixed length array call
someFunc(foo)             // Dynamic array call passing the Array variable foo
```

### Advantages

1. Unifies standard and variadic function declarations, eliminating a unique syntax that is arguably unnecessary.
2. The type of the variadic parameter is absolutely explicit.
3. Enables calling of a variadic function with dynamic arrays, without the need for additional special syntax.
4. No redundant overloads to enable both call styles (one declaration provides both).
5. Enables further extension to support more collection types now or in future (see Proposed Extension below).
6. Moves the variadic feature declaration from syntax into the attributes list, which should aid discoverability (and simplify syntax very slightly).
7. The attribute is more explicit about what it does (provides a name that can be searched).

### Ambiguity

One technical issue with this change is the introduction of ambiguity as follows:
```
someFunc(_ values:@variadic [Any]) { … }
someFunc([1]) // Is this an array call of [1] or a variadic call of [[1]]?
someFunc(foo) // If foo is an array, is this an array call of foo, or a variadic call of [foo]?
```
However, this issue is only exhibited when the type of variadic is `Any` (or another type that can represent both an array of elements and the elements themselves) and only when there is possibly only a single argument.

The proposed solution to this is to reuse the new `@variadic` attribute, plus a `@nonVariadic` attribute*, enabling disambiguation like so:
```
someFunc(@variadic [1])     // Unambiguously a variadic call of [[1]]
someFunc(@nonVariadic [1])  // Unambiguously an array call of [1]
someFunc(@variadic foo)     // Unambiguously a variadic call of [foo]
```
In the variadic case it would also be possible to use a trailing comma for disambiguation like so:
```
someFunc([1],)  // Unambiguously a varaidic call of [[1]]
someFunc(foo,)  // Unambiguously a variadic call of [foo]
```
*These attributes could instead be compiler directives if that is more appropriate.

## Impact on existing code

All existing variadic function function declarations will be invalidated, either being replaced or producing a fixit to perform conversion like so:
```
func someFunc(_ values:Int...)          // Before
func someFunc(_ values:@variadic [Int]) // After
```

## Proposed Extension

One other advantage of the use of an attribute is the possibility of allowing variadic enabled functions to accept a wider range of parameter types.
For example, the above examples could be implemented instead like so:
```
func someFunc(_ values:@variadic MyArrayLiteralConvertible<Int>) { … } // Type conforming to ArrayLiteralConvertible
func someFunc<I:IteratorProtocol where I.Element == Int) { … } // Implementation supports all single and multi-pass types
func someFunc<S:Sequence where S.Iterator.Element == Int) { … } // Implementation supports all (probably) multi-pass types
func someFunc<C:Collection where C.Iterator.Element == Int) { … } // Implementation supports all guaranteed multi-pass, indexable types with known size
```

When a specific type is defined it must conform to `ArrayLiteralConvertible` to enable variadic calls, while generic conformances must be capable of being satisfied by an `Array` when called in variadic style. For example, the latter three examples would all receive an `[Int]` when called in variadic style, but can accept any suitable iterator, sequence or collection when called dynamically. In other words, when a function is called in variadic style it is always passed an `Array` unless its type is `ArrayLiteralConvertible`, so its supported type(s) must support this.

This extension has been moved into its own section as it is not critical to the proposal, however it does represent an advantage of the attribute based approach, and would be desirable to have if implementing it is sufficiently easy for it to be done at the same time.

## Alternatives considered

One alternative often mentioned is simply enabling the existing variadic declarations to be called with an array. However, this has the same issue with ambiguity to resolve, and leaves variadics as their own category of function, rather than unifying them with ordinary functions.

It is possible to both add the `@variadic` attribute and retain the current syntax as a shorthand, however if the proposed extension is implemented this would discourage consideration of the best collection type to use, and in general it would remove one advantage in removing this extraneous syntax.

The nuclear option is to remove variadics entirely; this is the preference of some (myself included) as it eliminates the inherent ambiguity of variadics in general, forcing explicit use of arrays and other types with no need for limitations, however there is sufficient support for variadics now that they exist that this option is unlikely to succeed.
