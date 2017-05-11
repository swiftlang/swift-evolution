# Enforcing Calling Super

* Proposal: [SE-0052](https://github.com/apple/swift-evolution/blob/master/proposals/0052-enforcing_calling_super.md)
* Author(s): [Kyle Sherman](https://github.com/drumnkyle)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Many times when creating a subclass the superclass has reasons for certain overridden methods to call the superclass’s version of the method. This change would enforce that the subclass called the superclass's method in its overridden version at compile time.

Swift-evolution thread for discussion: [link to the discussion thread](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160215/010509.html)
Swift-evolution thread for revised discussion: [link to the discussion after modifications](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160222/010860.html)

## Motivation

A concrete example of the type of problem this solves can be taken from simple iOS code. When creating a subclass of UIViewController, you often need to override methods like viewDidLoad or viewWillAppear. You are supposed to call super.viewDidLoad or super.viewWillAppear, respectively, in your overridden implementation. If you don't, you will have undefined behavior and run into issues. Of course, this type of situation can be extrapolated to any class created in Swift. 
Currently, the only way this can be enforced is by commenting the superclass's code and making a note in the documentation. Quite obviously this can cause many issues as mistakes can be made by new developers quite easily who didn't look at the documentation for the method or even seasoned developers who simply overlooked this small detail. 
Clang has an attribute `objc_requires_super` [Clang Documentation](http://clang.llvm.org/docs/AttributeReference.html#objc-requires-super) that is declared as a macro in `NSFoundation` as  `NS_REQUIRES_SUPER`, but does not seemed to be used by Apple very much, if at all, and most developers seem to not know about it. This proposal should also include the work to add the attributes described to at least the most commonly subclassed `UIKit` classes.

## Proposed solution

The solution proposed here would be to use an attribute similar to `@available` and `@noescape` in order to convey this information. 
The compiler would use the information from the attribute to ensure that any overridden version of the method must call super. The compiler would also need to ensure that any method that was going to use this attribute had the same access control level as the class that contains it.
This solution will be much safer than what is currently available, because there is currently no way to enforce super being called in an overridden method from Swift. This bug happens constantly for iOS developers.

## Detailed design

A possible implementation of this may look like this:

```
class MyBaseClass {
    @requiresSuper func foo1() { }
}
```

Now, if the developer were to create a subclass and not call the super method, the compiler should display a warning. The warning that should be displayed should be similar to: “Overridden method must call the superclass’s implementation”
The compiler would also need to display an error in this case where the access control of the method is stricter than that of the class:

```
public class MyClass {
    @requiresSuper func foo() { }
}
```

The compiler should show a warning, such as “A method using `@requiresSuper` must have access control set to be at least as accessible as the class that contains it”.
There can also be a simple fix-it that adds in the call to the super’s method. The specifics of the exact name and syntax is flexible as long as it has the 3 features proposed and produces a warning.

## Impact on existing code

The good thing about this change is that it will not have any impact on existing Swift code. This is an optional attribute provided by the developer. Therefore, if the attribute is not used, nothing is changed.
Unfortunately, there is no good way to automatically migrate code to use this new attribute, because the information would have only been embedded in comments previously. Implementation of this feature by the developer is completely optional. Therefore, existing code will be unaffected and no migration of code will be necessary. However, when APIs are updated to use this new feature, some code will not compile if the developer did not use the APIs correctly. This should be a welcomed compilation error as it will result in less buggy code at runtime. The impact of this change is similar to adding nullability attributes to Objective-C.
It will be impossible to migrate code automatically, because this information cannot be derived in any way aside from reading comments if and only if the API author documented it.

## Alternatives considered

The alternative would simply be to not implement this feature. I also explored an option of allowing the developer to specify `@requiresSuper(start|end)` in order to say where the call to super must be called, but this was a hotly debated topic and in the end it was decided that this was too strict. Also, others wanted a way to disable the warning, but that seems like a larger Swift feature that needs to be added as a separate attribute or something similar.
