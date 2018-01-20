# Compensate for the inconsistency of `@NSCopying`'s behaviour

* Proposal: [SE-0153](0153-compensate-for-the-inconsistency-of-nscopyings-behaviour.md)
* Authors: [Torin Kwok](https://github.com/TorinKwok)
* Review Manager: [Doug Gregor](https://github.com/DougGregor)
* Status: **Accepted**
* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170227/033357.html)
* Bug: [SR-4538](https://bugs.swift.org/browse/SR-4538)

<!--*During the review process, add the following fields as needed:*

* Decision Notes: [Rationale](https://lists.swift.org/pipermail/swift-evolution/), [Additional Commentary](https://lists.swift.org/pipermail/swift-evolution/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/apple/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)-->

## Introduction

First of all, in Swift, the Objective-C `copy` property attribute translates to `@NSCopying`.

Like Objective-C, in Swift, avoiding accessing ivar via setter methods in initializer is considered as the best practice. Unlike Objective-C, which gives developers the freedom to decide on whether assign a value to a property by invoking setter or by accessing ivar directly, accessing a property in Swift from within an initializer always does direct access to the storage rather than going through the setter, even if using `dot` syntax.

However, as a side-effect, `@NSCopying` attribute does not work as consistently as we usually expected in Swift initializers after developers declared a property as `@NSCopying`.

This proposal is intent on proposing several solutions to this inconsistency.

## Swift-evolution thread

- [@NSCopying currently does not affect initializers (from *The Week Of Monday 23 January 2017 Archive*)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170123/031049.html)
- [@NSCopying currently does not affect initializers (from *The Week Of Monday 30 January 2017 Archive*)](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20170130/031162.html)

## Motivation

Here's an example of the inconsistency mentioned above:

```swift
class Person: NSObject, NSCopying {

  var firstName: String
  var lastName: String
  var job: String?

  init( firstName: String, lastName: String, job: String? = nil ) {
    self.firstName = firstName
    self.lastName = lastName
    self.job = job

    super.init()
    }

  /// Conformance to <NSCopying> protocol
  func copy( with zone: NSZone? = nil ) -> Any {
    let theCopy = Person.init( firstName: firstName, lastName: lastName )
    theCopy.job = job

    return theCopy
    }

  /// For convenience of debugging
  override var description: String {
    return "\(firstName) \(lastName)" + ( job != nil ? ", \(job!)" : "" )
    }

  }
```

`Person` class has promised that it conforms to `<NSCopying>` protocol.

``` swift
let johnAppleseed = Person( firstName: "John", lastName: "Appleseed", job: "CEO" )
var refJohnAppleseed = johnAppleseed // assigning without copying semantic

refJohnAppleseed.job = "Engineer"

// `cloneJohnAppleseed` and `johnAppleseed` have the identical `job` ...

print( refJohnAppleseed ) // Prints "John Appleseed, Engineer"
print( johnAppleseed )	  // Prints "John Appleseed, Engineer" too

// ... and the assertion **would not** fail:
assert( refJohnAppleseed === johnAppleseed )

// Assigning a copy of johnAppleseed to clonedJohnAppleseed,
// which was returned by `copy( zone: ) -> Any`
var clonedJohnAppleseed = johnAppleseed/* refJohnAppleseed is also okay */.copy() as! Person

clonedJohnAppleseed.job = "Designer"
print( clonedJohnAppleseed ) // Prints "John Appleseed, Designer"
print( johnAppleseed )		 // Prints "John Appleseed, Engineer"
// Alright as what you see, setting the job of `clonedJohnAppleseed` doesn't affect the
// job stored in `johnAppleseed`.
```

Up to now, everything seems to run right. However, problems will soon emerge once we begin introducing a new class consuming instances of `Person` class:

``` swift
class Department: NSObject {

  // Here, we're expecting that `self.employee` would automatically
  // store the deeply-copied instance of `Person` class
  @NSCopying var employee: Person

  init( employee candidate: Person ) {

    // CAUTION! That's the key point:
    // `self.employee` has been marked with `@NSCopying` attribute
    // but what would take place here is only the shallow-copying.
   	//
    // In the other words, `self.employee` will share identical underlying
    // object with `candidate`.
    self.employee = candidate
    super.init()

    // Assertion will definitely fail since Swift do not actually 
    // copy the value assigned to this property even though 
    // `self.employee` has been marked as `@NSCoyping`:

    /* assert( self.employee !== employee ) */
    }

  override var description: String {
    return "A Department: [ ( \(employee) ) ]"
    }

  }
```

`Department`'s designated initializer receives an external instance of `Person` and expects to assign its deeply-copied value to `self.employee` property.

``` swift
let isaacNewton = Person( firstName: "Isaac", lastName: "Newton", job: "Mathematician" )
let lab = Department.init( employee: isaacNewton )

isaacNewton.job = "Astronomer"

print( isaacNewton ) 	// Prints "Isaac Newton, Astronomer"

print( lab.employee )	// Prints "Isaac Newton, Astronomer"
// Expected output printed here is "Isaac Newton, Mathematician" instead
```

Setting the job of `isaacNewton` affects the job stored in `lab.employee`. That's an unexpected behavior as we have declared `employee` property as `@NSCopying`. Obviously, `@NSCopying` semantic became effectless implicitly in the initializer of `Department` class.

For the moment, if we indeed require copy we have to invoke `copy()` method explicitly on instances that want to be copied to make sure that classes' properties are able to store deeply-copied results during the initialization:

``` swift
init( employee candidate: Person ) {
  // ...
  self.employee = candidate.copy() as! Person
  // ...
 }
```

The reason why it is considered *inconsistency* is that `@NSCopying` contract will be well respected within the rest of class definition:

``` swift
lab.employee = isaacNewton
isaacNewton.job = "Physicist"

print( isaacNewton )	// Prints "Isaac Newton, Physicist"
print( lab.employee ) 	// Prints "Isaac Newton, Astronomer"
```

It is undeniably reasonable to enforce programmers to access instance variables directly from initializer methods because of the potential troubles made by setter methods' additional side-effects when the initialization is not complete yet. However, I believe we at least should be warned by the Swift compiler when we assigned an instance of `NSCopying` conforming class to a class's property declared as `@NSCopying` during the initialization.

In Objective-C, developers can make a decision on this process explicitly by writing done either:

```objc
- ( instancetype )initWithName: ( NSString* )name {
  // ...
  self->_name = [ name copy ];
  // ...
  }
```

or:

```objc
- ( instancetype )initWithName: ( NSString* )name {
  // ...
  self.name = name; /* self.name has been qualified with @property ( copy ) */
  // ...
  }
```

Speaking of Swift, however, there is no stuff like `->` operator to access ivar directly. As a result, with property marked with `@NSCopying` attribute, developers who are new to this language, especially those who have had experience of writing Objective-C, are likely to automatically suppose it acts normally when they're writing down code like `self.employee = candidate` in initializer. That's bug-prone.

## Proposed solution

Do the compiler magic to call `copy( with: )` in the initializer so that `@NSCopying` attribute no longer subjects to the fact that setter methods would not be invoked in initializers. **Copying should always take place after a property has been declared as `@NSCopying`**. It seems like the most direct way to maintain the `@NSCopying` contract without changing the underlying direct-storage model.

## Source compatibility

Projects written with prior versions of Swift that have not yet adopted this proposal may fail to be built due to the compile-time error. But overall, it will be easy to be resolved. IDEs' Fix-it and auto migrator tools will deal with all works painlessly.

## Effect on ABI stability

The proposal doesn't change the ABI of existing language features.

## Alternatives Considered

### Compile-time checking

Instead of introducing the copy within the initializer, have the compiler emit a **compile-time error or warning** if developers are performing an assignment operation from within an initializer between a property declared as `@NSCopying` and an instance of a `<NSCopying>` protocol conforming class. Also, speaking of GUI integrated development environments such as Xcode, leaving this kind of error or warning **FIXABLE** would be needed in order to make them can be quickly fixed by both IDEs and migrator tools through simply appending `.copy() as! AutoInferredClassType`.

With the adjustment mentioned above, following code fragment, for instance, will no longer be successfully compiled:

``` swift
...
class Person: NSObject, NSCopying { /* ... */ }
...
@NSCopying var employee: Person
...
init( employee candidate: Person ) {
  // ...
  self.employee = candidate
  // ...
 }
```

GUI IDE will be expected to leave developers a fixable error or warning, and thus if we hit the either red or yelloe point in Xcode, or something similar to those in other IDEs, they will automatically append the lacked statement:

> self.employee = candidate***.copy() as! Person***

Inferring `AutoInferredClassType` from context should be the responsibility of compiler.
