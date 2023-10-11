# Inferring `@Sendable` for methods

* Proposal: [SE-NNNN](https://github.com/kavon/swift-evolution/blob/sendable-functions/proposals/NNNN-filename.md)
* Authors: [Angela Laar](https://github.com/angela-laar), [Kavon Farvardin](https://github.com/kavon)
* Review Manager: TBD
* Status: Awaiting Implementation
* Review: ([pitch](https://forums.swift.org/t/pitch-inferring-sendable-for-methods/66565))

## Introduction

This proposal is focused on a few corner cases in the language surrounding functions as values when using concurrency. The goal is to improve flexibility, simplicity, and ergonomics without significant changes to Swift.

## Motivation

The partial application of methods and other first-class uses of functions have a few rough edges when combined with concurrency.

Let’s look at partial application on its own before we combine it with concurrency.  In Swift, you can create a function-value representing a method by writing an expression that only accesses (but does not call) a method using one of its instances. This access is referred to as a "partial application" of a method to one of its (curried) arguments - the object instance.

```
struct S {
  func f() { ... }
}

let partial: (() -> Void) = S().f 
```


When referencing a method *without* partially applying it  to the object instance, using the expression NominalType.method, we call it "unapplied."


```
let unapplied: (T) -> (() -> Void) = S.f
```


Suppose we want to create a generic method that expects an unapplied function method conforming to Sendable as a parameter. We can create a protocol ``P`` that conforms to the `Sendable` protocol and tell our generic function to expect some generic type that conforms to ``P``. We can also use the `@Sendable` attribute, introduced for closures and functions in [SE-302](https://github.com/kavon/swift-evolution/blob/sendable-functions/proposals/0302-concurrent-value-and-concurrent-closures.md), to annotate the closure parameter. 


```
protocol P: Sendable {
  init()
}

func g<T>(_ f: @escaping @Sendable (T) -> (() -> Void)) where T: P {
  Task {
    let instance = T()
    f(instance)()
  }
}
```

Now let’s call our method and pass our struct type `S` . First we should make `S` conform to Sendable, which we can do by making `S` conform to our new Sendable type `P` . 

This should make `S` and its methods Sendable as well. However, when we pass our unapplied function `S.f`  to our generic function `g`, we get a warning that `S.f` is not Sendable as `g()` is expecting.  


```
struct S: P {
  func f() { ... }
}

g(S.f) // Converting non-sendable function value to '@Sendable (S) -> (() -> Void)' may introduce data races
```


We can work around this by wrapping our unapplied function in a Sendable closure.  

```
// S.f($0) == S.f()
g({ @Sendable **in** S.f($0) })
```


This is a lot of churn to get the expected behavior. The compiler should preserve `@Sendable` in the type signature instead.

## Proposed solution

We propose the compiler should automatically employ `@Sendable`  to functions that cannot capture non-Sendable states. This includes partially-applied and unapplied instance methods of `Sendable` types, as well as non-local functions. Additionally, it should be disallowed to utilize `@Sendable` on instance methods of non-`Sendable` types.

For a function, the `@Sendable` attribute primarily influences the kinds of values that can be captured by the function. But methods of a nominal type do not capture anything but the object instance itself. Semantically, a method can be thought of as being represented by the following functions:


```
// Pseudo-code declaration of a Nominal Type:
type NominalType {
  func method(ArgType) -> ReturnType { /* body of method */ }
}

// Can desugar to these two global functions:
func NominalType_method_partiallyAppliedTo(_ obj: NominalType) -> ((ArgType) -> ReturnType) {
  let inner = { [obj] (_ arg1: ArgType) -> ReturnType in
    return NominalType_method(obj, arg1)
  }
  return inner
}
// The actual method call
func NominalType_method(_ self: NominalType, _ arg1: ArgType) -> ReturnType {
  /* body of method */
}
```

Thus, the only way a partially-applied method can be `@Sendable` is if the `inner` closure were `@Sendable`, which is true if and only if the nominal type conforms to `Sendable`.


```
type NominalType : Sendable {
  func method(ArgType) -> ReturnType { /* body of method */ }
}
```

For example, by declaring the following type `Sendable`, the partial and unapplied function values of the type would have implied Sendability and the following code would compile with no errors.
```
struct User : Sendable {
  func updatePassword (new: String, old:String) -> Bool {
    /* update password*/ 
    return true
  }
}

let unapplied: @Sendable (User) -> ((String, String) → Bool) = User.updatePassword // no error

let partial: @Sendable (String, String) -> Bool = User().updatePassword // no error
```



## Detailed design

This proposal includes four changes to `Sendable` behavior.

The first two are what we just discussed regarding partial and unapplied methods.

```
struct User : Sendable {
  var address
  var password
  
  func changeAddress () {/*do work*/ }
}
```

1. The inference of `@Sendable` for unapplied references to methods of a Sendable type. 

```
let unapplied : @Sendable (User) → ((String, String) → Void) = User.changeAddress // no error
```

2. The inference of `@Sendable` for partially-applied methods of a Sendable type.

```
let partial : @Sendable (String, String) → Void = User().changeAddress // no error
```

These two rules include partially applied and unapplied static methods but do not include partially applied or unapplied mutable methods. Unapplied references to mutable methods are not allowed in the language because they can lead to undefined behavior.  More details about this can be found in [SE-0042](https://github.com/apple/swift-evolution/blob/main/proposals/0042-flatten-method-types.md).

Next is:

3. The inference of `@Sendable`  when referencing non-local functions.

Unlike closures, which retain the captured value, global functions can't capture any variables - because global variables are just referenced by the function without any ownership. With this in mind there is no reason not to make these `Sendable` by default. This change will also include static global functions.

```
func doWork() -> Int {
`  Int.random(in: 1..<42)`
}

Task<Int, Never>.detached(priority: **nil**, operation: doWork) // Converting non-sendable function value to '@Sendable () async -> Void' may introduce data races
```

Currently, trying to start a `Task` with the global function `doWork` will cause an error complaining that the function is not `Sendable`. This should compile with no issue.  

4. Prohibition of marking methods `@Sendable` when the type they belong to is not `@Sendable`.
```
    class C {
        var random: Int = 0 // random is mutable so `C` can't be checked sendable
        
        @Sendable func generateN() async -> Int { //error: adding @Sendable to function of non-Senable type prohibited
             random = Int.random(in: 1..<100)
             return random
        }
    }

    func test(c: C) { c.generateN() }

    let num = C()
    Task.detached {
       test(num)
    }
    test(num) // data-race
```

If we move the previous work we wanted to do into a class that stores the random number we generate as a mutable value, we could be introducing a data race by marking the function responsible for this work `@Sendable` . Doing this should be prohibited by the compiler.

Since `@Sendable` attribute will be automatically determined with this proposal, you will no longer have to explicitly write it on function and method declarations.

## Source compatibility

No impact.

## Effect on ABI stability

When you remove an explicit `@Sendable` from a method, the mangling of that method will change. Since `@Sendable` will now be inferred, if you choose to remove the explicit annotation to "adopt" the inference, you may need to consider the mangling change.

## Effect on API resilience

No effect on ABI stability. 

## Future Directions 

Accessors are not currently allowed to participate with the `@Sendable` system in this proposal. It would be straight-forward to allow getters to do so in a future proposal if there was demand for this.

## Alternatives Considered 

Swift could forbid explicitly marking function declarations with the` @Sendable` attribute, since under this proposal there’s no longer any reason to do this.

```
/*@Sendable*/ func alwaysSendable() {}
```

However, since these attributes are allowed today, this would be a source breaking change. Swift 6 could potentially include fix-its to remove `@Sendable` attributes to ease migration, but it’d still be disruptive. The attributes are harmless under this proposal, and they’re still sometimes useful for code that needs to compile with older tools, so we have chosen not to make this change in this proposal. We can consider deprecation at a later time if we find a good reason to do so.

