# Class and Subtype existentials

* Proposal: [SE-XXXX](XXXX-subclass-existentials.md)
* Authors: [David Hart](http://github.com/hartbit/), [Austin Zheng](http://github.com/austinzheng)
* Review Manager: TBD
* Status: TBD

## Introduction

This proposal brings more expressive power to the type system by allowing Swift to represent existentials of classes and subtypes which conform to protocols.

## Motivation

Currently, the only existentials which can be represented in Swift are conformances to a set of protocols, using the `&` protocol composition syntax:

```swift
Protocol1 & Protocol2
```

On the other hand, Objective-C is capable of expressing existentials of classes and subclasses conforming to protocols with the following syntax:

```objc
id<Protocol1, Protocol2>
Base<Protocol>*
```

We propose to provide similar expressive power to Swift, which will also improve the bridging of those types from Objective-C.

## Proposed solution

The proposal keeps the existing `&` syntax but allows the first element, and only the first, to be either the `class` keyword or of class type. The equivalent to the above Objective-C types would look like this:

```swift
class & Protocol1 & Protocol2
Base & Protocol
```

As in Objective-C, the first line is an existential of classes which conform to `Protocol1` and `Protocol2`, and the second line is an existential of subtypes of `Base` which conform to `Protocol`.

Here are the new proposed rules for what is valid in a existential conjunction syntax:

1. The first element in the protocol composition syntax can be the `class` keyword to enforce a class constraint:
    ```swift
    protocol P {}
    struct S : P {}
    class C : P {}
    let t: P & class // Compiler error: class requirement must be in first position
    let u: class & P = S() // Compiler error: S is not of class type
    let v: class & P = C() // Compiles successfully
    ```
2. The first element in the protocol composition syntax can be a class type to enforce the existential to be a subtype of the class:
    ```swift
    protocol P {}
    struct S {}
    class C {}
    class D : P {}
    class E : C, P {}
    let t: P & C // Compiler error: subclass contraint must be in first position
    let u: S & P // Compiler error: S is not of class type
    let v: C & P = D() // Compiler error: D is not a subtype of C
    let w: C & P = E() // Compiles successfully
    ```
3. When a protocol composition type contains a typealias, the validity of the type is determined using the following steps:
    * Expand the typealias
    * Normalize  the type by removing duplicate constraints and replacing less specific constraints by more specific constraints (a `class` constraint is less specific than a class type constraint, which is less specific than a constraint of a subclass of that class).
    * Check that the type does not contain two class-type constraints
    ```swift
    class C {}
    class D : C {}
    class E {}
    protocol P1 {}
    protocol P2 {}
    typealias TA1 = class & P1
    typealias TA2 = class & P2
    typealias TA3 = C & P2
    typealias TA4 = D & P2
    typealias TA5 = E & P2

    typealias TA5 = TA1 & TA2
    typealias TA5 = class & P1 & class & P2 // Expansion
    typealias TA5 = class & P1 & P2 // Normalization
    // TA5 is valid

    typealias TA6 = TA1 & TA3
    typealias TA6 = class & P1 & C & P2 // Expansion
    typealias TA6 = C & P1 & P2 // Normalization (class < C)
    // TA6 is valid

    typealias TA7 = TA3 & TA4
    typealias TA7 = C & P2 & D & P2 // Expansion
    typealias TA7 = D & P2 // Normalization (C < D)
    // TA7 is valid

    typealias TA8 = TA4 & TA5
    typealias TA8 = D & P2 & E & P2 // Expansion
    typealias TA8 = D & E & P2 // Normalization
    // TA8 is invalid because the D and E constraints are incompatible
    ```

## `class` and `AnyObject`

This proposal merges the concepts of `class` and `AnyObject`, which now have the same meaning: they represent an existential for classes. They are four solutions to this dilemna:

1. Do nothing.
2. Replace all uses of `AnyObject` by `class`, breaking source compatibility.
3. Replace all uses of `class` by `AnyObject`, breaking source compatibility.
4. Redefine `AnyObject` as `typealias AnyObject = class`.

## Source compatibility

Leaving aside what is decided concerning `class` and `AnyObject`, this change will not break Swift 3 compability mode because Objective-C types will continue to be imported as before. But in Swift 4 mode, all types bridged from Objective-C which use the equivalent Objective-C existential syntax could break code which does not meet the new protocol requirements. For example, the following Objective-C code:

```objc
@interface MyViewController
- (void)setup:(nonnull UIViewController<UITableViewDataSource,UITableViewDelegate>*)tableViewController;
@end
```

is imported into Swift-3 mode as:

```swift
class MyViewController {
    func setup(tableViewController: UIViewController) {}
}
```

which allows calling the function with an invalid parameter:

```swift
let myViewController: MyViewController()
myViewController.setup(UIViewController())
```

The previous code continues to compile but still crashs if the Objective-C code calls a method of `UITableViewDataSource` or `UITableViewDelegate`. But if this proposal is accepted and implemented as-is, the Objective-C code will be imported in Swift 4 mode as:

```swift
class MyViewController {
    func setup(tableViewController: UIViewController & UITableViewDataSource & UITableViewDelegate) {}
}
```

That would then cause the Swift code run in version 4 mode to fail to compile with an error which states that `UIViewController` does not conform to the `UITableViewDataSource` and `UITableViewDelegate` protocols.

## Alternatives considered

None.

## Acknowledgements

Thanks to [Austin Zheng](http://github.com/austinzheng) and [Matthew Johnson](https://github.com/anandabits) who brought a lot of attention to existentials in this mailing-list and from whom most of the ideas in the proposal come from.