# New access modifier: `package`

* Proposal: [SE-NNNN](NNNN-package-access-modifier.md)
* Authors: [Ellie Shin](https://github.com/elsh), [Alexis Laferriere](https://github.com/xymus)
* Review Manager: TBD
* Status: Awaiting review
* Implementation: [apple/swift#61546](https://github.com/apple/swift/pull/61546)
* Review: [pitch](https://forums.swift.org/t/new-access-modifier-package/61459)

## Introduction

This proposal introduces `package` as a new access modifier. Currently, to access a symbol in another module, that symbol needs to be declared `public`. It allows access across modules within the same library but also outside of the library, which is undesirable. The new access modifier enables a more fine control over the visibility scope of such symbols. 

## Motivation

Packages are often composed of multiple modules; packages exist as a way to organize modules in Swift, and organizing often involves splitting a module into smaller modules. For example, a module containing internal helper APIs can be split into a utility module only with the helper APIs and the other module(s) containing the rest. In order to access the helper APIs, however, the helper APIs need to be made public. The side effect of this is that they can “leak” to a client that should not have access to those symbols. Besides the scope of visibility, making them public also has an implication on the code size and performance.

For example, here’s a scenario where App depends on modules from package 'gamePkg'.

```
App (Xcode project or appPkg)
  |— Game (gamePkg)
      |— Engine (gamePkg)
```

Here are source code examples.

```
[Engine]

public struct MainEngine {
    public init() { ... }
    // Intended to be public
    public var stats: String { ... }
    // A helper function made public only to be accessed by Game
    public func run() { ... }
}

[Game]

import Engine

public func play() {
    MainEngine().run() // Can access `run` as intended since it's within the same package
}

[App]

import Game
import Engine

let engine = MainEngine()
engine.run() // Can access `run` from App even if it's not an intended behavior
Game.play()
print(engine.stats) // Can access `stats` as intended
```

In the above scenario, App can import Engine (a utility module in 'gamePkg') and access its helper API directly, even though the API is not intended to be used outside of its package.


## Proposed solution

A current workaround for the above scenario is to use `@_spi`, `@_implemenationOnly`, or `@testable`. However, they have caveats. The `@_spi` requires a group name, which makes it verbose to use and harder to keep track of, and `@_implementationOnly` can be too limiting as we want to be able to restrict access to only portions of APIs. The `@testable` elevates all internal symbols to public, which leads to an increase of the binary size and the shared cache size. If there are multiple symbols with the same name from different modules, they will clash and require module qualifiers everywhere. It is hacky and is strongly discouraged for use.

We want a solution that will clearly communicate that the visibility scope is somewhere between `internal` and `public`, and is limited to modules within a package, thus we propose a new access modifier `package`.


## Detailed design


### Declaration Site

Using the scenario above, the helper API `run` can be declared `package`.

```
[Engine]

public struct MainEngine {
    public init() { ... }
    public var stats: String { ... }
    package func run() { ... }
}
```

The `package` access modifier can be added to any types where an existing access modifier can be added, e.g. `class`, `struct`, `enum`, `func`, `var`, `protocol`, etc. 


### Use site

The Game module can access the helper API `run` since it is in the same package as Engine.

```
[Game]

import Engine

public func play() {
    MainEngine().run() // Can access `run` as it is a package symbol in the same package
}
```

However, if a client outside of the package tries to access the helper API, it will not be allowed.

```
[App]

import Game
import Engine

let engine = MainEngine()
engine.run() // Error: cannot find `run` in scope

```

During type check a package name that's stored in an imported module binary will be looked up and compared with the current module's package name to allow or disallow access to a package symbol from that module. More details are explained below.


### Lookup by package name

A new flag `-package-name` will be introduced to enable grouping modules per package. In Swift Package Manager, the input to the flag will be a package identity and will be passed down automatically. Each package identity is unique and can contain non-alphanumeric characters such as a hyphen and a dot (currently any URL valid characters are allowed); such characters will be transposed into a c99 identifier. Other build systems such as Xcode and Basel will need to pass a new command-line argument `-package-name` to the build command; the input may be Reverse-DNS package names so it can prevent potential clashes with other project or package names. 

```
[Engine] swiftc -module-name Engine -package-name gamePkg ...
[Game] swiftc -module-name Game -package-name gamePkg ...
[App] swiftc App -package-name appPkg ...
```

When building the Engine module, the package name 'gamePkg' and package symbols will be stored in the Engine.swiftmodule. When building Game, the input to its package name 'gamePkg' will be compared with Engine's package name; since they match, access to package symbols is allowed. When building App, the name comparison shows 'appPkg' is different from its dependency module's so access to package symbols will be deined, which is what we want.

If `-package-name` is not passed, but `package` access modifier is used, then an error will be thrown; Building files that do not have `package` symbols should continue to work without needing to pass in `-package-name`. 


### Exportability

The package symbols will be stored in .swiftmodule but not in .swiftinterface. The package name will be stored in both .swiftmodule and .swiftinterface, but only the swiftmodule will be loaded when building a same-package module; this will prevent loading a fall-back module (swiftinterface) which does not contain package symbols.  

The exportability rule at the declaration site will be similar to the the existing behavior; for example, a public class is not allowed to inherit a package class, and a public func is not allowed to have a package type in its signature. 

The `@inlinable` will be applicable to `package`; we plan to introduce`@usableFromPackageInline` to allow references from `@inlinable package` and not from `@inlinable public`.

Package symbols will be exported in the final libraries/executables and emitted in llvm.used; we plan to introduce a build setting that lets users decide whether to hide package symbols if statically linked.


### Subclassing / Overrides

A `package` class will not be allowed to be subclassed from another module, thus a `package` class member will not be allowed to be overidden either. 

This follows the behavior and optimization model for `public`; a `public` class has no subclasses outside of its defining module, and a `public` class member has no overrides outside of its defining module. The optimizer can take advantage of this information in whole-module builds to replace dynamic dispatch with static dispatch among other things.

It also allows a linear progression from `private` through `open` where each step incrementally offers capabilities to a wider range of clients. If `package` were to allow subclassing/overrides outside of its defining modules, making a `package` class `public` would break subclasses defined in other modules within the same package. 

If a `package` class needs to be subclassed, it will need to be declared `open`, or be converted to a protocol, which is a recommended practice.


## Future Directions

Limiting the scope of visibility per package can open up a whole lot of optimization opportunities. A package containing several modules can be treated as a resilience domain.

Even with the library evolution enabled, modules within a package could be treated non-resilient. If same-package clients need access to swiftmodules, they don't need to be independently rebuildable and could have an unstable ABI; they could avoid resilience overhead and language rules such as the `@unknown default` requirement.


## Source compatibility

The changes is additive, so it's not source breaking.

## Effect on ABI stability

Does not impact ABI stability.

## Alternatives considered

A current workaround is to use `@_spi`, `@_implemenationOnly`, or `@testable`. Each option has caveats. The `@_spi` requires a group name, which makes it verbose to use and harder to keep track of, and `@_implementationOnly` can be too limiting as we want to be able to restrict access to only portions of APIs. The `@testable` elevates all internal symbols to public, which leads to an increase of the binary size and the shared cache size. If there are multiple symbols with the same name from different modules, they will clash and require module qualifiers everywhere. It is hacky and is strongly discouraged for use.

## Acknowledgments

Alexis Laferriere, Doug Gregor, Becca Royal-Gordon, Allan Shortlidge, Artem Chikin, and Xi Ge provided helpful feedback and analysis. Alexis Laferriere has been part of the discussion from the beginning and reviewed implementation of the prototype. 
