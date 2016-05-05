# Expanding Swift `Self` to class members and value types

* Proposal: [SE-0068](0068-universal-self.md)
* Author: [Erica Sadun](http://github.com/erica)
* Status: **Accepted** ([Bug](https://bugs.swift.org/browse/SR-1340))
* Review manager: [Chris Lattner](http://github.com/lattner)
* Previous version: [Review version](https://github.com/apple/swift-evolution/blob/13d9771e86c5639b8320f05e5daa31a62bac0f07/proposals/0068-universal-self.md)

## Introduction

Within a class scope, `Self` means "the dynamic class of `self`". This proposal extends that courtesy to value types and to the bodies of class members
by renaming `dynamicType` to `Self`. This establishes a universal and consistent
way to refer to the dynamic type of the current receiver. 


*This proposal was discussed on the Swift Evolution list in the [\[Pitch\] Adding a Self type name shortcut for static member access](http://thread.gmane.org/gmane.comp.lang.swift.evolution/13708/focus=13712) thread.*

## Motivation

It is common in Swift to reference an instance's type, whether accessing 
a static member or passing types for unsafe bitcasts, among other uses.
You can either specify a type by its full name or use `self.dynamicType`
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

* `dynamicType` remains an exception to Swift's lowercased keywords rule. This change eliminates a special case that's out of step with Swift's new standards.
* `Self` is shorter and clearer in its intent. It mirrors `self`, which refers to the current instance.
* It provides an easier way to access static members. As type names grow large, readability suffers. `MyExtremelyLargeTypeName.staticMember` is unwieldy to type and read.
* Code using hardwired type names is less portable than code that automatically knows its type.
* Renaming a type means updating any `TypeName` references in code.
* Using `self.dynamicType` fights against Swift's goals of concision and clarity in that it is both noisy and esoteric.

Note that `self.dynamicType.classMember` and `TypeName.classMember` may not be synonyms in class types with non-final members.

## Detail Design

This proposal introduces `Self`, which equates to and replaces `self.dynamicType`. 
You will continue to specify full type names for any other use. Joe Groff writes, "I don't think it's all that onerous to have  to write `ClassName.foo` if that's really what you specifically mean."

## Alternatives Considered

Not at this time

## Acknowlegements

Thanks Sean Heber, Kevin Ballard, Joe Groff, Timothy Wood, Brent Royal-Gordon, Andrey Tarantsov, Austin Zheng