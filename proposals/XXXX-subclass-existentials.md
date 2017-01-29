# Existentials for classes conforming to protocols

* Proposal: [SE-XXXX](XXXX-subclass-existentials.md)
* Authors: [David Hart](http://github.com/hartbit/), [Austin Zheng](http://github.com/austinzheng)
* Review Manager: TBD
* Status: TBD

## Introduction

This proposal brings more expressive power to the type system by allowing Swift to represent existentials of classes and subclasses which conform to protocols.

## Motivation

Currently, the only existentials which can be represented in Swift are conformances to a set of protocols, using the `&` syntax:

```swift
let existential: Hashable & CustomStringConvertible
```

On the other hand, Objective-C is capable of expressing existentials of subclasses conforming to protocols with the following syntax:

```objc
UIViewController<UITableViewDataSource, UITableViewDelegate>* existential;
```

We propose to provide similar expressive power to Swift, which will also improve the bridging of those types from Objective-C.

## Proposed solution

The proposal keeps the existing `&` syntax but allows the first element, and only the first, to be of class type. The equivalent declaration to the above Objective-C declaration would look like this:

```swift
let existential: UIViewController & UITableViewDataSource & UITableViewDelegate
```

As in Objective-C, this existential represents classes which have `UIViewController` in their parent inheritance hierarchy and which also conform to the `UITableViewDataSource` and `UITableViewDelegate` protocols.

As only the first element in the existential composition syntax can be a class type, and by extending this rule to typealias expansions, we can make sure that we only need to read the first element to know if it contains a class requirement. As a consequence, here is a list of valid and invalid code and the reasons for them:

```swift
let a: Hashable & CustomStringConvertible
// VALID: This is still valid, as before

let b: MyObject & Hashable
// VALID: This is the new rule which allows an object type in first position

let c: CustomStringConvertible & MyObject
// INVALID: MyObject is not allowed in second position. A fix-it should help transform it to:
// let c: MyObject & CustomStringConvertible

typealias MyObjectStringConvertible = MyObject & CustomStringConvertible
let d: Hashable & MyObjectStringConvertible
// INVALID: The typealias expansion means that the type of d expands to Hashable & MyObject & CustomStringConvertible, which has the class in the wrong position. A fix-it should help transform it to:
// let d: MyObjectStringConvertible & Hashable

typealias MyObjectStringConvertible = MyObject & CustomStringConvertible
let e: MyOtherObject & MyObjectStringConvertible
// INVALID: The typealias expansion would allow an existential with two class requirements, which is invalid
```

The following examples could technically be legal, but we believe we should keep them invalid to keep the rules simple:

```swift
let a: MyObject & MyObject & CustomStringConvertible
// This is equivalent to MyObject & CustomStringConvertible

let b: MyObjectSubclass & MyObject & Hashable
// This is equivalent to MyObjectSubclass & Hashable

typealias MyObjectStringConvertible = MyObject & CustomStringConvertible
let d: MyObject & MyObjectStringConvertible
// This is equivalent to MyObject & CustomStringConvertible
```

## Source compatibility

This is a source breaking change. All types bridged from Objective-C which use the equivalent Objective-C feature import without the protocol conformances in Swift 3. This change would increase the existential's requirement and break on code which does not meet the new protocol requirements. For example, the following Objective-C code:

```objc
@interface MyViewController
- (void)setup:(nonnull UIViewController<UITableViewDataSource,UITableViewDelegate>*)tableViewController;
@end
```

is imported into Swift 3 as:

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

The previous code would have worked as long as the Objective-C code did not call any method of `UITableViewDataSource` or `UITableViewDelegate`. But if this proposal is accepted and implemented as-is, the Objective-C code would now be imported as:

```swift
class MyViewController {
    func setup(tableViewController: UIViewController & UITableViewDataSource & UITableViewDelegate) {}
}
```

That would then cause the Swift code to fail to compile with an error which states that `UIViewController` does not conform to the `UITableViewDataSource` and `UITableViewDelegate` protocols.

It is a source-breaking change, but should have a minimal impact for the following reasons:

* Not many Objective-C code used the existential syntax in practice.
* There generated errors are a good thing because they point out potential crashes which would have gone un-noticed.

## Alternatives considered

None.

## Acknowledgements

Thanks to [Austin Zheng](http://github.com/austinzheng) and [Matthew Johnson](https://github.com/anandabits) who brought a lot of attention to existentials in this mailing-list and from whom most of the ideas in the proposal come from.