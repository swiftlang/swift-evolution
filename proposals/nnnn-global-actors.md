# Global actors

* Proposal: [SE-NNNN](NNNN-global-actors.md)
* Authors: [John McCall](https://github.com/rjmccall), [Doug Gregor](https://github.com/DougGregor)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: Available in [recent `main` snapshots](https://swift.org/download/#snapshots) behind the flag `-Xfrontend -enable-experimental-concurrency`

## Introduction

[Actors](https://github.com/DougGregor/swift-evolution/blob/actors/proposals/nnnn-actors.md) are a new kind of reference type that protect their instance data from concurrent access. Swift actors achieve this with *actor isolation*, which ensures (at compile time) that all accesses to that instance data go through a synchronization mechanism that serializes execution.

This proposal introduces *global actors*, which extend the notion of actor isolation outside of a single actor type, so that global state (and the functions that access it) can benefit from actor isolation, even if the state and functions are scattered across many different types, functions and modules. Global actors make it possible to safely work with global variables in a concurrent program, as well as modeling other global program constraints such as code that must only execute on the "main thread" or "UI thread". 

Swift-evolution thread: [Discussion thread topic for that proposal](https://forums.swift.org/)

## Motivation

Actors are fantastic for isolating instance data, providing a form of reference type that can be used in concurrent programs without introducing data races. However, when the data that needs to be isolated is scattered across a program, or is representing some bit of state that exists outside of the program, bringing all of that code and data into a single actor instance might be impractical (say, in a large program) or even impossible (when interacting with a system where those assumptions are pervasive).

A primary motivator of global actors is to apply the actor model to the state and operations that can only be accessed by the *main thread*. In an application, the main thread is generally responsible for executing the primary event-handling loop that processes events from various sources and delivers them to application code. Graphical applications often deliver user-interaction events (a keyboard press, a touch interaction) on the main thread, and require that any stateful updates to the user interface occur there as well. Global actors provide the mechanism for describing the main thread in terms of actors, utilizing Swift's actor isolation model to aid in correct usage of the main thread.

## Proposed solution

A global actor is a globally-unique actor identified by a type. That type becomes a custom attribute (similar to [property wrapper types](https://github.com/apple/swift-evolution/blob/master/proposals/0258-property-wrappers.md) or [result builder types](https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md)). Any declaration can state that it is actor-isolated to that particular global actor by naming the global actor type as an attribute, at which point all of the normal actor-isolation restrictions come into play: the declaration can only be synchronously accessed from another declaration on the same global actor, but can be asynchronously accessed from elsewhere. For example, this proposal introduces `MainActor` as a global actor describing the main thread. It can be used to require that certain functions only execute on the main thread:

```swift
@MainActor var globalTextSize: Int

@MainActor func increaseTextSize() { 
  globalTextSize += 2   // okay: 
}

func notOnTheMainActor() async {
  globalTextSize = 12  // error: globalTextSize is isolated to MainActor
  increaseTextSize()   // error: increaseTextSize is isolated to MainActor, cannot call synchronously
  await increaseTextSize() // okay: asynchronous call hops over to the main thread and executes there
}
``` 

### Defining global actors

A global actor is a non-protocol type that has the `@globalActor` attribute and contains a `static let` property named `shared` that provides an actor instance. `MainActor` is one such actor, defined as follows:

```swift
@globalActor
public final actor MainActor {
  public static let shared = MainActor()
}
```

The type of `shared` must be an actor type. The shared instance is a globally-unique actor instance that becomes synonymous with the global actor type. 

> **Note**: integrating the main actor with the system's main thread requires support for [custom executors][customexecs], which is the subject of another proposal. For systems that use the Apple's [Dispatch](https://developer.apple.com/documentation/DISPATCH) library as the underlying concurrency implementation, the main actor uses a custom executor that wraps the [main dispatch queue](https://developer.apple.com/documentation/dispatch/dispatchqueue/1781006-main). However, the notion is a general one, and can be adapted to other concurrency runtime implementations.

### Using global actors on functions and data

As illustrated in our first example, both functions and data can be attributed with a global actor type to isolate them to that global actor. Note that global actors are not restricted to global functions or data as in the first example. One can mark members of types as belonging to a global actor as well. For example, in a view controller for a graphical UI, we would expect to receive notification of user interactions on the main thread, and must update the UI on the main thread. Therefore want both the methods called on notification and also the data they use to be on the main actor. Here's an small part of a view controller from some [AppKit sample code](https://developer.apple.com/documentation/appkit/cocoa_bindings/navigating_hierarchical_data_using_outline_and_split_views):

```swift
class IconViewController: UIViewController {
  @MainActor @objc private dynamic var icons: [[String: Any]] = []
    
  @MainActor var url: URL?
    
  @MainActor private func updateIcons(_ iconArray: [[String: Any]]) {
    icons = iconArray
        
    // Notify interested view controllers that the content has been obtained.
    // ...
  }
}
```

Note that the data in this view controller, as well as the method that performs the update of this data, is isolated to the `@MainActor`. That ensures that UI updates for this view controller only occur on the main thread, and any attempts to do otherwise will result in a compiler error.

The sample code actually triggers an update when the `url` property is set. With Swift's concurrency mechanisms, that would look something like this:

```swift
@MainActor var url: URL? {
  didSet {
    // Asynchronously perform an update
    Task.runDetached { [url] in                // not isolated to any actor
      guard let url = url else { return }
      let newIcons = self.gatherContents(url)
      await self.updateIcons(newIcons)         // 'await' required so we can hop over to the main actor
    }
  }
}
```

### Using global actors on a type

It is common for entire types (and even class hierarchies) to predominantly require execution on the main thread, and for asynchronous work to be a special case. In such cases, the type itself can be annotated with a global actor, and all of the instance methods, properties, and subscripts will implicitly be isolated to that global actor. Any members of the type that do not want to be part of the global actor can opt out, e.g., using the [`nonisolated` modifier][isolation]. For example:

```swift
@MainActor
class IconViewController: UIViewController {
   @objc private dynamic var icons: [[String: Any]] = [] // implicitly @MainActor
    
  var url: URL? // implicitly @MainActor
    
  private func updateIcons(_ iconArray: [[String: Any]]) { // implicitly @MainActor
    icons = iconArray
        
    // Notify interested view controllers that the content has been obtained.
    // ...
  }
  
  nonisolated private func gatherContents(url: URL) -> [[String: Any]] {
    // ...
  }
}

class RemoteIconViewController : IconViewController { // implicitly @MainActor
  func connect() { ... } // implicitly @MainActor
}
```

## Global actor function types and closures

A synchronous function type can be qualified to state that the function is only callable on a specific global actor:

```swift
var callback: @MainActor (Int) -> Void
```

Such a function can only be synchronously called from code that is itself isolated to the same global actor.

Values may be converted from a function type with no global actor qualifier to a function with a global actor qualifier. For example:

```swift
func acceptInt(_: Int) { } // not on any actor

callback = acceptInt // okay: conversion to @MainActor (Int) -> Void
```

The type of a reference to a synchronous function with a global actor is qualified with that global actor. Values of types with global actor qualifiers can be `@sendable` (but do not have to be). 

A closure can be specified to be isolated to a global actor by providing the attribute prior to the `in` in the closure specifier, e.g.,

```swift
callback = { @MainActor in
  print($0)
}

callback = { @MainActor (i) in 
  print($i)
}
```

When a global actor is applied to a synchronous closure, the type of the global is qualified with that global actor. When a global actor is applied to an `async` closure, there is no effect on the closure type, but the closure body will execute on the specified global actor.

> **Note**: this can be used to replace the common pattern used with Apple's Dispatch library of executing main-thread code via `DispatchQueue.main.async { ... }`. One would instead write:
> ```swift
> Task.runDetached { @MainActor in 
>   // ...
> }
> ```
> This formulation ensures that the closure body is executed on the main actor, and can synchronously use other `@MainActor`-annotated declarations.

If a closure is used to directly initialize a parameter or other value of a global-actor-qualified function type, and the closure itself does not have a global actor explicitly specified on it, the closure will have that global actor inferred. For example:

```swift
@MainActor var globalTextSize: Int

callback = {
  globalTextSize = $0  // okay: closure is inferred to be isolated to the @MainActor
}
```

## Detailed design

Global actor attributes apply to declarations as follows:

* A declaration cannot have multiple have global actor attributes.  The rules below say that, in some cases, a global actor attribute is propagated from one declaration to another.  If the rules say that an attribute “propagates by default”, then no propagation is performed if the destination declaration has an explicit global actor attribute.  If the rules say that attribute “propagates mandatorily”, then it is an error if the destination declaration has an explicit global actor attribute that does not identify the same actor.  Regardless, it is an error if global actor attributes that do not identify the same actor are propagated to the same declaration.

* A function declared with a global actor attribute becomes isolated to the given global actor.

* A stored variable or constant declared with a global actor attribute becomes part of the isolated state of the given global actor.

* The accessors of a variable or subscript declared with a global actor attribute become isolated to the given global actor.  (This includes observing accessors on a stored variable.)

* Local variables and constants cannot be marked with a global actor attribute.

* A type declared with a global actor attribute propagates the attribute to all instance methods, instance properties, instance subscripts, and extensions of the type by default. 

* An extension declared with a global actor attribute propagates the attribute to all the members of the extension by default.

* A protocol declared with a global actor attribute propagates the attribute to its conforming types by default.

* A protocol requirement declared with a global actor attribute propagates the attribute to its witnesses. A given witness must either have the same global actor attribute or be non-isolated. (This is the same rule observed by all witnesses for actor-isolated requirements).

* A class declared with a global actor attribute propagates the attribute to its subclasses mandatorily.

* An overridden declaration propagates its global actor attribute (if any) to its overrides mandatorily.  Other forms of propagation do not apply to overrides.  It is an error if a declaration with a global actor attribute overrides a declaration without an attribute.

* An actor type cannot have a global actor attribute.  Stored instance properties of actor types cannot have global actor attributes.  Other members of an actor type can have global actor attributes; such members are isolated to the global actor, but not to the enclosing actor. (Per the proposal on [improved control over actor isolation][isolation], the `self` of such methods is not `isolated`).

* A `deinit` cannot have a global actor attribute and is never a target for propagation.


## Source compatibility

Global actors are an additive feature that have no impact on existing source code.

## Effect on ABI stability

A global actor annotation has no effect on the ABI of any declaration to which it is applied.

## Effect on API resilience

The `@globalActor` attribute can be added to a type without breaking API.

A global actor attribute (such as `@MainActor`) can neither be added nor removed from an API; either will cause breaking changes for source code that uses the API.

## Future Directions

### Requiring global actors on global data

In the Swift concurrency model developed thus far, mutable global variables and static variables defined in types are accessible from any actor and, therefore, can be accessed in a manner that admits data races. One way to eliminate such data races is to require that every such variable be isolated to some global actor. In doing so, all access each global or static variable is serialized through its global actor, eliminating the possibility of data races.

## Alternatives considered

### Singleton support

Global actors are, effectively, baking a convention for singletons in the language. Singletons are occasionally used in Swift, and if they were to get special language syntax, global actors could be introduced with less boilerplate as "singleton actors", e.g., 

```swift
singleton actor MainActor {
  // integration with system's main thread
}
```

This would eliminate the `@globalActor` attribute from the proposal, but would otherwise leave it unchanged.

### Propose only the main actor

The primary motivation for global actors is the main actor, and the semantics of this feature are tuned to the needs of main-thread execution. We know abstractly that there are other similar use cases, but it's possible that global actors aren't the right match for those use cases. Rather than provide a general feature for global actors now, we could narrow this proposal to `@MainActor` only, then provide global actors (or some other abstraction) at some later point to subsume `@MainActor` and other important use cases.

[customexecs]: https://github.com/rjmccall/swift-evolution/blob/custom-executors/proposals/0000-custom-executors.md
[isolation]: https://github.com/DougGregor/swift-evolution/blob/actor-isolation-control/proposals/nnnn-actor-isolation-control.md
