# Union Type

* Proposal: [SE-NNNN](NNNN-union-type.md)
* Author: [Cao, Jiannan](https://github.com/frogcjn)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Add union type grammar, represents the type which is one of other types.

```swift

var stringOrURL: String | URL = "https://www.apple.com"

```

Swift-evolution thread: [Discussion thread topic for that proposal](http://news.gmane.org/gmane.comp.lang.swift.evolution/023056)

## Motivation

There are many reasons to have this important feature.
The obvious one is that developer will write less type declaration code in Swift.

For example, there is three class type A, B and C:

```swift


class A {
    var commonProperty: String?
    var propertyInA: String?
}


class B {
    var commonProperty: String?
    var propertyInB: String?
}

class C {
    var commonProperty: String?
    var propertyInC: String?
}

```

Originaly, if we want to represent a varialbe whose type maybe A, B or C, we should announce a more common type:

```swift

protocol Common {
    var commonProperty: String? {get}
}

extension A : Common {}
extension B : Common {}
extension C : Common {}

func input(value: Common) {
    print(value.commonProperty)
    switch value {
    case let value as A:
        // value is type A
        print(value.propertyInA)
    case let value as B:
        // value is type B
        print(value.propertyInB)
    case let value as C:
        // value is type C
        print(value.propertyInC)
    default:
        // we don't want any Common type other then A, B, C, so we trigger a fatalError
        fatalError("No other type than A, B, C")
        // since we can't write this kind of requirement with protocol
    }
}
```

Or we can make an enum type of A, B, C to limit the type.

```swift

enum UnionOfABC {
    case _A(value: A)
    case _B(value: B)
    case _C(value: C)
    var value: Common {
        switch(self) {
        case let _A(value): return value
        case let _B(value): return value
        case let _C(value): return value
        }
    }
}

func input(u: UnionOfABC) {
    print(u.value.commonProperty)
    switch u {
    case let ._A(a):
        print(a.propertyInA)
    case let ._B(b):
        print(b.propertyInB)
    case let ._C(b):
        print(b.propertyInC)
    }
}
```

## Proposed solution

Now, if we using the new union type feature, we can declare type conveniently,
No other type declaration, and compiler will automatically calculate the common interface.

```swift
func input(value: A | B | C) {
    print(value.commonProperty)
    switch value {
    case let value as A:
        // value is type A
        print(value.propertyInA)
    case let value as B:
        // value is type B
        print(value.propertyInB)
    case let value as C:
        // value is type C
        print(value.propertyInC)
    }
    // there is no default case other than A, B or C. we already declared that.
}
```

and if the **class** A, B, C in example, were **protocol** A, B, C, it is more difficault to **add** a common type for them.
Because in current Swift environment, developer cannot make an existed protocol conform another protocol.

## Detailed design

There are serveral advance points:

* It keeps the code clear and does not need developer to announce some unnecessary protocols or enums.
    like `enum UnionOf3<T,U,V>` or `protocol CommonABC`
* It does not need wrap into an enum type.
    ```swift
    let a = new A()
    let union: (A|B|C) = a // no need wrap.
    ```
    other than

    ```swift
    let a = new A()
    let union: UnionOfABC = UnionOfABC._A(a) // wrap
    ```
* Compiler search their common properties and methods, then mark them as a member of the union type.
    ```swift
    let a = new A()
    let union: (A|B|C) = a // no need wrap.
    print(union.commonProperty)
    ```
    developer automatically get this, instead of developer to declare a common property.

* Compiler know the union type exactly composed with which types, better than only know which protocol.
    switch union type of A, B, C only needs three cases, but interface Common needs a default case.

* It will be easy to compare with value of original type.
```swift
    union == a // If union is not type A, then return false; If union is type A, then compare!!😊
```
instead of unwrap enum cases and compare.

* Original types and union types can have a rational relationship between each other.
    Original type is a sub-type of union types contain it.
    ```swift
        var fn0: A->Void = {print(v0)}
        var fn1: (A|B)->Void = {print(v0)}

        fn0 = fn1 // OK, because Original Type and Union Type has a sub-typing relationship

        var fn2: (A|B|C)->Void = {print($0)}

        fn0 = fn2 // OK
        fn1 = fn2 // OK
    ```
* And the most **important** part, It can replace enum `Optional<T>` to represent optional types.
    ```swift
        let string: String?
    ```
        is same to
    ```swift
        let string: String | None
    ```
        instead of
    ```swift
        let string: Optional<String>
    ```

    * IUO, Implicity Unwrapped Optional, can also use union to represent
     ```swift
        let string: String!
    ```
        will be the same as the union grammar:
    ``` swift
        let iuo: *String | None
    ```


## Impact on existing code

* This is a new feature, developer who need declare common type will alter to this new grammar.
* Optional<Wrapped> and IUO<Wrapped> may removed. Any Optional type will automatically replaced by union type.

