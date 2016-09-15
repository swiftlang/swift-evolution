# Feature name

* Proposal: [SE-NNNN](NNNN-forbid-weak-keyword-for-computed-properties.md)
* Author: [Andrey Volodin](https://github.com/s1ddok)
* Status: **Awaiting review**
* Review manager: TBD

## Introduction

Current compiler version allow `weak` keyword for every type of properties. For stored properties this works just fine, but when it comes to computed ones it brings a lot of questions to the table.


## Motivation

Let me start by showing you the most simple example that one can do.

```swift
class Foo {
    private var a: Int = 0
}

class FooFactory {
    public weak var newFoo: Foo? {
        return Foo()
    }
}
```

Let's not get into architecture sides of it and proceed straight to the property `newFoo`. As you can see it is a pure computed get-only property. It is very unclear of what `weak` modificator is supposed to mean in this case. As far as I can see it has no affect at all on property's behaviour, but requires to be an optional type. This is strange behaviour which makes code less readable and makes you wonder about how certain things works and what affect some keywords (`weak`) have.

Now we will look at slightly more complex example on how `weak` keyword can bring a lot of confusion to the API.

```swift
class Foo {
    private var a: Int = 0
}

class FooContainer {
    private var _f: Foo!

    public weak var newFoo: Foo? {
        get { return _f }
        set {
            // some **necessary** logic here, that can't be putted in willSet
            _f = newValue
            // some **necessary** logic here, that can't be putted in didSet
        }
    }
}
```

We all love Swift's `didSet` and `willSet` code containers, they are really useful in avoiding excess code and adding certain behaviour to stored properties. But sometimes we **really** want to implement our own getter/setter. For example if we need to handle both will- and did- set cases, but need to remember some state in between them. As you can see in the example above, our computed (but not a get-only) property is marked by `weak` keyword and has an optional type on it, but the things is that it is mapped to strong private property, which makes the whole thing obsolette.

The problem is not only that keyword has no affect and brings obsolette restrictions (forcing optional type), but also leads to ambigouty and brings a lot of confusion while debugging and reading code.

As it is now, `weak` keyword for computed properties has exactly same effect as documention. It claims the behaviour, but does not guarantee that.

## Proposed solution

I propose to fully forbid `weak` keyword for all properties which are either computed or implement custom get/set pair.

## Detailed design

Show hinting (fixable in XCode) compilation error for all such properties.

## Impact on existing code

It should be relatively easy to provide a code-migration tool, but code with such properties will not compile anymore.

## Alternatives considered

We can also forbid only get-only computed properties and show warning on the ones which implement their own get/set pair.
