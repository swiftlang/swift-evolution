# Introduce @required for closures

* Proposal: [SE-NNNN](0000-required-closures.md)
* Author: [James Campbell](https://github.com/swiftdev)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

I propose we add a `@required` type annotiation for closures. This is a handy
attribute that developers can use when creating classes and libraries to
require that a closure passed into a metho be called.

This is useful for situations where calling that callback may be critical to an
application's lifecycle, could trigger clean up methods to reclaim memory or in
the case of iOS let the system know you have finished processing
after a background update.

Swift-evolution thread: [Discussion thread topic for that proposal](https://lists.swift.org/pipermail/swift-evolution/Week-of-Mon-20160815/026288.html)

## Motivation

Right now it is fairly easy to ignore or forget to call a closure call when
the documentation reccomends we should.

For example in the iOS SDK it is easy to forget to call the closures which
inform the iOS Operating system that your app has finished processing. This
can cause strange behaviour and even for iOS to penalize your app
for abusing resources.

```
func application(application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: () -> Void) {

       // If there was alot of complicated code here with many if statements and such a developer
       // may forget to call completionHandler but the compiler doesn't help them out
}
```

## Proposed solution

My solution is to add a simple annotation attribute to closures `@required`. The example from the iOS SDK, would become:

```
func application(application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @required () -> Void) {

}
```
And so if any codepath didn't call the `completionHandler` closure the compile will throw a warning or error.

To fix it they simply just add a call:

```
func application(application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @required () -> Void) {
  completionHandler()
}
```

This adds safety since developer won't miss calling a callbabck and additional clarity since developer knows they need to call it.

If the closure is passed to another function, as long as the closure pattern matches and is also annotated as `@required` then the compiler will treat it as if it was invoked for this function:

```

func myMethod(completionHandler: @required () -> Void)) {
  completionHandler()
}

func application(application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @required () -> Void) {
  myMethod(completionHandler) // Since the closure matches for myMethod and is marked as @required - the compiler is happy
}
```

A helper method `withoutActuallyInvoking` will also be introduced so that methods from other modules that haven't adopted the attribute can still be interfaced with.

```

func myMethod(completionHandler: () -> Void)) {
  completionHandler()
}

func application(application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @required () -> Void) {
  myMethod(withoutActuallyInvoking(completionHandler))  marked as @required - the compiler is happy
}
```

`withoutActuallyInvoking` - satisfies the compiler requirement that the closure is called since it has a `@required` atrribute and it will match the shape of any closure.

It will return a special closure for the non-attibuted method which can be accepted by that method and will emit a runtime error when the closure is deallocated without being invoked.

## Detailed design

`@required`

This is added as a attribute type exclusive to closures used as a function arguments.

`withoutActuallyInvoking(closure: @required AnyClosure) -> AnyClosure`

Wraps and returns a closure with the `@required` attribute into a special closure
that invokes the original closure and throws an runtime error if the closure was deallocated
 without being invoked.


## Impact on existing code

This change is purley additive and we have the `withoutActuallyInvoking` nethod for those methods
who haven't adopted the new attribute but may take a closure who has.

A simple FIXME could be applied for those cases.

## Alternatives considered

An alternative where you marked a callsite with `required` was considered but this felt very heavy.
