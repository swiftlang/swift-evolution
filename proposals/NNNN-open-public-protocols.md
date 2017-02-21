# Open and Public Protocols

* Proposal: [SE-NNNN](NNNN-open-public-protocols.md)
* Authors: [Matthew Johnson](https://github.com/anandabits)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

This proposal introduces `open protocol` and changes the meaning of `public protocol` to match the meaning of `public class` (in this case, conformances are only allowed inside the declaring module).

The draft thread for this proposal was: [open and public protocols](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170213/032355.html)

The pitch thread leading up to this proposal was: [consistent public access modifiers](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170206/031653.html)

## Motivation

A general principle the Swift community has adopted for access control is that defaults should reserve maximum flexibility for a library.  The ensures that any capabilities beyond mere visibility are not available unless the author of the library has explicitly declared their intent that the capabilities be made available.  Finally, when it is possible to switch from one semantic to another without breaking clients (but not vice-versa) we should prefer the more forgiving (i.e. fixable) semantic as the (soft) default.

`public` is considered a "soft default" in the sense that it is the first access modifier a user will reach for when exposing a declaration outside of the module.  In the case of protocols the current meaning of `public` does not meet the principle of preserving maximum flexibility for the author of the library.  It allows users of the library to conform to the protocol.

There are good reasons a library may not wish to allow users to add conformances to a protocol.  It has been suggested that enums could offer similar behavior by using a case per type in the set that would conform if a protocol were used.  One important difference is that this alternative design does not allow the concrete types to be hidden as they would be associated values of cases of the enum.  

Even if cases could be private there are still good reasons to prefer the protocol-based solution.  Enums require an implementation to use switch statements rather than polymorphism.  Library authors may not want to have to maintain switch statements every time they need to add or remove a conforming type which would be necessary if an enum were used instead.  Polymorphism allows us to avoid this, giving us the ability to add and remove conforming types within the implementation of the library without the burden of maintaining switch statements.

Aligning the access modifiers for protocols and classes allows us to specify both conformable and non-conformable protocols, provides a soft default that is consistent with the principle of (soft) defaults reserving maximum flexibility for the library, and increases the overall consistency of the language by aligning the semantics of access control for protocols and classes.

The standard library currently has at least one protocol (`MirrorPath`) that is documented as disallowing client conformances.  If this proposal is adopted it is likely that `MirrorPath` would be declared `public protocol` and not `open protocol`.

Jordan Rose has indicated that the Apple frameworks also include a number of protocols documented with the intent that users do not add conformances.  Perhaps an importer annotation would allow the compiler to enforce these semantics in Swift code as well.

## Proposed solution

The proposed solution is to change the meaning of `public protocol` to disallow conformances outside the declaring module and introduce `open protocol` to allow conformances outside the decalring module (equivalent to the current meaning of `public protocol`).

## Detailed design

The detailed design is relatively straightforward but there are three important wrinkles to consider.

### User refinement of public protocols

Consider the following example:

```swift
// Library module:
public protocol P {}
public class C: P {}

// User module:
protocol User: P {}
extension C: User {}
```

The user module is allowed to add a refinement to `P` because this does not have any impact on the impelementation of the library or its possible evolution.  It simply allows the user to write code that is generic over a subset of the conforming types provided by the library.

### Public protocols with open conforming classes

Consider the following example:

```swift
public protocol P {}
open class C: P {}
```

Users of this module will be able to add subclasses of `C` that have a conformance to `P`.  This is allowed becuase the client of the module did not need to explicitly declare a conformance and the module has explicitly stated its intent to allow subclasses of `C` with the `open` access modifier.

### Open protocols that refine public protocols

Consider the following example:

```swift
// library module:
public protocol P {}
open protocol Q: P {}
open protocol R: P {}

// user module:
struct S: P {} // error `P` is not `open`
struct T: Q {} // ok
struct U: R {} // ok
```

The user module is allowed to introudce a conformance to `P`, but only indirectly by also conforming to `Q`.  The meaning we have ascribed to the keywords implies that this should be allowed and it offers libraries a very wide design space from which to choose.  The library is able to have types that conform directly to `P`, while placing additional requirements on user types if necessary.

## Source compatibility

This proposal breaks source compatibility, but in a way that allows for a simple mechanical migration.  A multi-release stratgegy will be used to roll out this proposal to provide maximum possible source compatibility from one release to the next.

1. In Swift 4, introduce the `open` keyword and the `@nonopen` attribute (which can be applied to `public protocol` to give it the new semantics of `public`).
2. In Swift 4 (or 4.1 if necessary) start warning for `public protocol` with no annotation.
3. In the subsequent release `public protocol` without annotation becomes an error.
4. In the subsequent release `public protocol` without annotation takes on the new semantics.
5. `@nonopen` becomes a warning, and evenutally an error as soon as we are comfortable making those changes.

## Effect on ABI stability

I would appreciate it if others can offer input regarding this section.  I believe this proposal has ABI consequences, but it's possible that it could be an additivie ABI change where the ABI for conformable protocols remains the same and we add ABI for non-conformable protocols later.  If that is possible, the primary impact would be the ABI of any standard library protocols that would prefer to be non-conformable.

## Effect on API resilience

This proposal would may impact one or more protocols in the standard library, such as `MirrorPath`, which would likely choose to remain `public` rather than adopt `open`.

## Alternatives considered

The primary alternatives are to either make no change, or to add something like `closed protocol`.  The issues motivating the current proposal as a better alternative than either of these options are covered in the motivation section.
