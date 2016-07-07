# Feature name

* Proposal: [SE-NNNN](0000-variadics-as-attribute.md)
* Author: [Haravikk](https://github.com/haravikk)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

This proposal is for a redesign of the variadic function parameter syntax as an attribute for greater flexibility.

## Motivation

Currently Swift variadic functions cannot be called with an array of values, potentially requiring two declarations like so:

```
func someMethod<C:Collection where C.Iterator.Element == Int>(_ values:C) { … } // Regular method
func someMethod(_ values:Int...) { someMethod(values) } // Variadic method
```

In some cases this leads to only one being defined, forcing developers to use that particular style. When this is the variadic option this means the method is restricted in how it can be used, and parameters constructed.

## Proposed solution

This proposal is to replace the current form of variadic declaration syntax (trailing elipsis) with a new attribute `@variadic` that enables any suitable iterable parameter to be called in variadic form if desired.

## Detailed design

Quite simply, instead of a trailing elipsis, a variadic parameter will instead be defined via a new `@variadic` attribute which can be placed upon any function parameter with a type conforming to `ArrayLiteralConvertible`, or which is a generic constraint against `IteratorProtocol`, `Sequence` or `Collection` such that a default (such as `Array`) can be used to fulfil the variadic call. Otherwise variadic parameters can be specified with the same restrictions they have now (must not be ambiguous).

For example, consider the following variadic function:

```
func someMethod(_ values:Int...) { … }
```

Under this proposal the above can be rewritten as one of the following:

```
func someMethod(@variadic _ values:[Int]) { … } // Basic Array solution
func someMethod(@variadic _ values:Foo) { … }   // Foo is a custom ArrayLiteralConvertible type
func someMethod<I:IteratorProtocol where I.Element == Int>(@variadic _ values:I) { … } // Flexible, single-pass, generic solution
func someMethod<S:Sequence where S.Iterator.Element == Int>(@variadic _ values:S) { … } // Flexible, (probably) multi-pass, generic solution
func someMethod<C:Collection where C.Iterator.Element == Int>(@variadic _ values:C) { … } // Flexible, definitely multi-pass, indexed, generic solution
```

In this case the Iterator variation is preferred for greatest flexibility, but it will depend upon the actual requirements of the method. Any of these can be called as follows:

```
someMethod([1, 2, 3, 4, 5, 6])  // normal array-literal call for any of the above
someMethod(1, 2, 3, 4, 5, 6)    // variadic call, synonymous with array-literal call
someMethod(foo)                 // foo is an existing Array, Foo, Iterator, Sequence or Collection variable as appropriate
```

This altered declaration syntax has a number of advantages over existing variadics:

* No requirement for a custom syntax (see alternatives however)
* A single declaration can handle variadic and collection/sequence/iterator invocation (no need for some other workaround such as reflection).
* Greater flexibility over the actual type of the variadic collection/sequence/iterator, not restricted to `Array` or array-like.
* Developers are free to choose the syntax used at the call-site based upon preference (or pass a variable instead).
* Declaration is more discoverable (option-click the @variadic attribute to view documenation).

## Impact on existing code

This proposal as given would remove the existing variadic syntax (trailing elipsis), but a fix-it should enable easy conversion between the following:

```
func someMethod(_ values:Int...) { … } // Old style
func someMethod(@variadic _ values:[Int]) { … } // New style
```

However there is an alternative to consider below that will affect this.

## Alternatives considered

One alternative is to simply have the existing variadic syntax produce a method taking an array of the same type, that is implicitly capable of being used in variadic style (but also used directly with `Array` values). However this has less flexibility than the above, which permits non-`Array` types.
A compromise could be to allow the existing style to remain as a shorthand, though this may discourage consideration of the most appropriate type (in general developers should be encouraged to accept generic types for greatest utility wherever possible, but if trailing elipsis is easy we may just end up with `Array` being used most often).

The other main alternative considered was removing variadics completely; while this is actually the preference of some (myself included), it seems a lot developers do not wish this. This proposal is intended as a compromise that coallesces variadics with regular functions, without eliminating the possibility to use either style at the call site as developers prefer.
