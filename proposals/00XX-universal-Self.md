# Expanding Swift `Self` to class members and value types

* Proposal: [SE-XXXX](https://gist.github.com/erica/5a26d523f3d6ffb74e34d179740596f7)
* Author(s): [Erica Sadun](http://github.com/erica)
* Status: TBD
* Review manager: TBD

## Introduction

Within a class scope, `Self` means "the dynamic class of `self`". This proposal extends that courtesy to value types, where dynamic `Self` will match a construct's static type, and to the bodies of class members, where it may not. It also introduces a static variation, `#Self` that expands to static type of the code it appears within.

This proposal was discussed on the Swift Evolution list in the [\[Pitch\] Adding a Self type name shortcut for static member access](http://thread.gmane.org/gmane.comp.lang.swift.evolution/13708/focus=13712) thread.

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

* As type names grow large, readability suffers. `MyExtremelyLargeTypeName.staticMember` is unwieldy to type and read.
* Code using hardwired type names is less portable than code that automatically knows its type.
* Renaming a type means updating any `TypeName` references in code.
* Using `self.dynamicType` fights against Swift's goals of concision and clarity in that it is both noisy and esoteric.
* `self.dynamicType.classMember` and `TypeName.classMember` may not be synonyms in class types with non-final members.

## Detail Design

This proposal introduces `Self` and `#Self`.

* `Self` equates to the dynamic type of `self` and only the
dynamic type of `self`. You will continue to specify full type
names for any other use. Joe Groff writes, "I don't think it's all 
that onerous to have  to write `ClassName.foo` if that's really what 
you specifically mean."

* `#Self` expands to the static type of the code it is 
declared within. In value types, this is always the same as `Self`. 
`#Self` will offer a literal textual replacement just like `#file`, etc.

## Alternatives Considered

Not at this time

## Acknowlegements

Thanks Sean Heber, Kevin Ballard, Joe Groff, Timothy Wood, Brent Royal-Gordon, Andrey Tarantsov, Austin Zheng