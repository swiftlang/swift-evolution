# "private" access control visible in extensions

* Proposal: [SE-NNNN](0000-private-access-in-extension.md)
* Authors: [Uros Krkic](https://github.com/uroskrkic)
* Review Manager: TBD
* Status: **Awaiting review**

## Introduction

Allow "private" members and methods of a type to be visible in an extension of that type. It will allows to keep extension code in a separate file, with possibility to access private members and methods in the original type.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20161031/028543.html)

## Motivation

In order to follow Single Responsibility Principle, we should break down the types (let's talk about classes in this example) into smaller pieces, decouple it and try to give to every single piece a separate functionality and responsibility.

Extensions, as a Swift mechanism to extend an existing type, provide this kind of decoupling and make it possible to keep an extension in a separate compile unit, which means, a separate file.

But, keeping an extension in a separate file does not allow to access private memebers/methods of the original type. 

**It forces developers to do two things:**

* Keep members/methods file-private, and put extension implementation in the same file.
* Make members/methods non-private, and put exntension in other file.

**Both approaches are bad:**

* The first approach forces us to create big classes (files). In practice, puting an extension in the same file with the original type has no any difference than putting the implementation in the type directly. Furthermore, we will have 3-5 lines more (extension declaration line and closing brace line). Of course, the main problem here is that we keep at least 2 reponsibilities in the same file. It is harder to organize, manage and maintain.
* The second approach allows us to keep extension in the separate file, but it makes our memebers/methods accessiable for all outside world and it breaks our encapsulation intention.

**Making "private" members/methods accessible only within extension does not violate any rules:**

* We can fully follow SRP.
* We don't violate OCP (Open/Closed Principle). We use an extension to extend original type, what we actually do. Making private members/methods visible in the extension does not violate OCP. We cannot change behavior by overriding some private method in the extension, which is the key point of OCP (to not change behavior, but to extend it). Furthermore, we can just change the state of the original type instance, which is absolutely valid to do in extensions. However, in most cases we will access private members/methods in extension for reading purpose, but also, changing it is not a violation of anything.
* "private" access modifier will have the same meaning like it has in the current version of Swift. It will just have a special meaning in extensions only.
* In the extension, we will have full access to original type, which also does not violate any principle. Don't mix it up with inheritance, where we don't want to access private members/methods in a subclass. A subclass is a brand new type, but an extension isn't.


## Proposed solution

1. Allow "private" access level to be visible inside extensions. (preferred solution)

2. *Alternatively*, keep the existing access levels to work as-is, but allow marking original type with something like `@extension-internal`. This will just allow "private" access level to be visible inside any extension of the type. (If a developer mark the original type with `@extension-internal`, it will just make private modifier visible inside the extension, but it is clearly stated it was the developer's intention).

## Benefits

We (developers) can follow SRP, keep our classes (types) smaller, keep our files smaller, without mixing different levels of abstraction, keep class (file) cohesion very high. Accessing private members of original type does not break SRP/OCP or violate a good design, especially in most cases when we are talking of an extension, we are talking about behavior extension (functions or protocol implementations). We will continue to encapsulate our functionalities in well defined types, keeping private all the things we don't want to share with outside world, but allowing it to be used directly in our type's extensions.

## Source compatibility

Both solutions, preferred one and alternative, will not violate source compatibility.

## Example

Let's consider an example where we have `UsersViewController` class which has a stored property `users` (let' say it is our model) and we want to keep it private. Let's suppose that `UsersViewController` uses `UITableView` and it handles datasource/delegate implementation. But, let's move datasource/delegate protocols implementation in an extension in a separate file named `UsersViewController+TableView` (Obj-C category naming style). This extension cannot access `users` property, because it is private.
*There are many other examples where we can apply the same approach.*

## Comments

Apple stated that in many cases, we don't need to specify an explicit access level in our code (source "The Swift Programming Language" book). But, majority of iOS developers develop iOS applications, which belongs to, as Apple Swift book says, "Access Levels for Single-Target Apps". It says that we should use default (internal) access level, because it will match all our requirements. The question is, why the language (Swift or Apple) forces us to have "bad" code design or better said, to not follow good design principles in single-target apps. If we don't develop a framework for world-wide use, it doesn't mean that we should not implement our apps in a good and clean way.

Additionally, "fileprivate" access level just simply forces us to create large classes, and nothing else. Furthermore, "open" access level just makes our lives more complicated. Introducing "protected"-meaning access modifier could also help developers to be more expressive.

Conclusion is, making "private" visible in extensions will not complicate anything. It will just allow developers to follow better design principles and keep the code cleaner, especially it will not violate source code compatibility or any existing meanings.
