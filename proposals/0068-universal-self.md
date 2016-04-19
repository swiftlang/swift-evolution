# Expanding Swift `Self` to class members and value types

* Proposal: [SE-0068](0066-standardize-function-type-syntax.md)
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: TBD
* Review manager: [Chris Lattner](http://github.com/lattner)

## Introduction

Within a class scope, `Self` means "the dynamic class of `self`". This proposal extends that courtesy to value types and to the bodies of class members
by renaming `dynamicType` to `Self`. This introduces a universal way to refer 
to the dynamic type of the current receiver. 

Under this proposal `Self` is a special associated type member that exists 
in every type, just like `dynamicType` currently does. Unifying these concepts,
eliminates the `dynamicType` keyword and replaces it with `x.Self`. 

A further static identifier, `#Self` expands to static type of the code it appears within, completing the ways code may want to refer to the type it is declared in.

*This proposal was discussed on the Swift Evolution list in the [\[Pitch\] Adding a Self type name shortcut for static member access](http://thread.gmane.org/gmane.comp.lang.swift.evolution/13708/focus=13712) thread and [Pitch] Rename `x.dynamicType` to `x.Self`*

## Motivation

It is common in Swift to reference an instance's type, whether for accessing 
a static member or passing a type for an unsafe bitcast, among other uses.
At this time, you can either fully specify a type by name or use `self.dynamicType`
to access an instance's dynamic runtime type as a value. 

```
struct MyStruct {
    static func staticMethod() { ... }
    func instanceMethod() {
        MyStruct.staticMethod()
        self.dynamicType.staticMethod()
    }
}
```

Introducing `Self` addresses the following issues:

* `dynamicType` remains an exception to Swift's lowercased keywords rule. This change eliminates a special case that falls out of Swift standards.
* `Self` is shorter and clearer in its intent. It mirrors `self`, which refers to the current instance.
* It provides an easier way to access static members. As type names grow large, readability suffers. `MyExtremelyLargeTypeName.staticMember` is unwieldy to type and read.
* Code using hardwired type names is less portable than code that automatically knows its type.
* Renaming a type means updating any `TypeName` references in code.
* Using `self.dynamicType` fights against Swift's goals of concision and clarity in that it is both noisy and esoteric.
* `self.dynamicType.classMember` and `TypeName.classMember` may not be synonyms in class types with non-final members.

## Detail Design

This proposal introduces `Self` and `#Self`.

* `Self` equates to and replaces `self.dynamicType`. 
You will continue to specify full type
names for any other use. Joe Groff writes, "I don't think it's all 
that onerous to have  to write `ClassName.foo` if that's really what 
you specifically mean."

* `#Self` expands to the static type of the code it is 
declared within. In value types, this is always the same as `Self`. 
In reference types, it refers to the declaring type.
`#Self` will offer a literal textual replacement just like `#file`, etc.

## Alternatives Considered

Not at this time

## Acknowlegements

Thanks Sean Heber, Kevin Ballard, Joe Groff, Timothy Wood, Brent Royal-Gordon, Andrey Tarantsov, Austin Zheng