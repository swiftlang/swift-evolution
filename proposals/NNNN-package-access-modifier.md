# New access modifier: `package`

* Proposal: [SE-NNNN](NNNN-package-access-modifier.md)
* Authors: [Ellie Shin](https://github.com/elsh), [Alexis Laferriere](https://github.com/xymus)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting review**
* Implementation: [apple/swift#61546](https://github.com/apple/swift/pull/62700), [apple/swift#62704](https://github.com/apple/swift/pull/62704), [apple/swift#62652](https://github.com/apple/swift/pull/62652)
* Review: ([pitch](https://forums.swift.org/t/new-access-modifier-package/61459))

## Introduction

This proposal introduces `package` as a new access modifier. Currently, to access a symbol in another module, that symbol needs to be declared `public`. However, a symbol being `public` allows it to be accessed from any module at all, both within a package and from outside of a package, which is sometimes undesirable. We need a new access modifier to enable a more fine control over the visibility scope of such symbols. 

## Motivation

At the most basic level, every Swift program is just a collection of declarations: functions, types, variables, and so on. In principle, every level of organization above this is arbitrary; all of those declarations could be piled into a single file, compiled, and run. In reality, Swift programs are organized into separate files, directories, libraries, and so on. At each level, this organization reflects programmer judgment about relationships, both in the code and in how it is developed.

As a language, Swift recognizes some of these levels. Modules are the smallest unit of library structure, with an independent interface and non-cyclic dependencies, and it makes sense for Swift to recognize that in both namespacing and access control. Files are the smallest grouping beneath that and are often used to collect tightly-related declarations, so they also make sense to respect in access control.

Packages, as expressed by the Swift Package Manager, are a unit of code distribution. Some packages contain just a single module, but it's frequently useful to split a package's code into multiple modules. For example, when a module contains some internal helper APIs, those APIs can be split out into a utility module and maybe reused by other modules or packages.

However, because Swift does not recognize organizations of code above the module level, it is not possible to create APIs like this that are purely internal to the package. To be usable from other modules within the package, the API must be public, but this means it can also be used outside of the package. This allows clients to form unwanted source dependencies on the API. It also means the built module has to export the API, which has negative implications for code size and performance.

For example, here’s a scenario where a client (App) has access to a utility API from a package (gamePkg) it depends on.

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

These costs are particularly unfortunate given that packages are a unit of code distribution. Boundaries between packages often reflect divisions between development teams; different packages are developed on different schedules by different groups of people. These boundaries are therefore especially important to enforce, because accidental dependencies can require extra work and cooperation to detangle.


## Proposed solution

Our goal is to introduce a mechanism to Swift to recognize a package as a unit in the aspect of access control. We proposed to do so by introducing a new access modifier `package`. The `package` access modifier will allow accessing symbols from outside of its defining module as long as they are within the same package. This will help set clear boundaries between packages. 

This also paves the path to include a package name in the namespace in the future, which will help disambiguate modules with the same name.  

## Detailed design

### `package` keyword

A new keyword `package` is introduced. It is a contextual keyword, i.e. a symbol can be named `package`.
For example, the following is allowed.

```
package var package: String {...}
```

This is similar to `open`, which is also a contextual keyword.

### Declaration Site

The `package` keyword is added at the declaration site. Using the scenario above, the helper API `run` can be declared with the new access modifier like so:

```
[Engine]

public struct MainEngine {
    public init() { ... }
    public var stats: String { ... }
    package func run() { ... }
}
```

The `package` access modifier can be added to any types where an existing access modifier can be added, e.g. `class`, `struct`, `enum`, `func`, `var`, `protocol`, etc. It is less restrictive than `internal` and more restrictive than `public`. For example, a `public` function cannot have `internal` or `package` parameters or return type in its signature, and a `package` function cannot have `internal` parameters or return type in its signature. 


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

### Package names

A package name is a unique string with c99 identifier characters, and is passed down to Swift frontend via a new flag `-package-name`. It is then stored in the module binary and used to compare with package names of other modules to determine if they are part of the same package. 

If `-package-name` is not given, the `package` access modifier is disallowed. Swift code that does not use `package` access will continue to build without needing to pass in `-package-name`.

Here's an example of how a package name is passed to a commandline invocation.

```
swiftc -module-name Engine -package-name gamePkg ...
[Game] swiftc -module-name Game -package-name gamePkg ...
[App] swiftc App -package-name appPkg ...
```

When building the Engine module, the package name 'gamePkg' and package symbols is stored in the Engine binary. When building Game, the input to its package name 'gamePkg' is compared with Engine's package name; since they match, access to package symbols is allowed. When building App, the name comparison shows 'appPkg' is different from its dependency module's so access to package symbols is deined, which is what we want.

Swift Package Manager has a package identity per package, an identifier that's verified to be unique via a registry, and it will pass it down automatically. Other build systems such as Bazel can introduce a new build setting to set the value for a package name. Since it needs to be unique, a reverse-DNS name could be used to avoid clashing.

### Exportability

Package symbols will be stored in .swiftmodule only, and not in the public interface file (.swiftinterface). We plan to introduce a .package.swiftinterface that contains package symbols, similar to a .private.swiftinterface which contains SPI symbols. We will store information on whether the .swiftmodule was built from a .package.swiftinterface into the .swiftmodule. We will also store the package name in both .swiftmodule and .swiftinterface. This is to enforce loading a .swiftmodule instead of .swiftinterface when building modules in the same package. 

`package` functions can be made `@inlinable`. Just like with `@inlinable public`, not all symbols are usable within the function: they must be `open`, `public`, `package`, or `@usableFromInline`. Note that `@usableFromInline` allows the use of a symbol from `@inlinable` functions whether they're `package` or `public`. `@usableFromPackageInline` will be introduced to export a symbol only for use by `@inlinable package` functions.

We plan to introduce an option to hide package symbols. By default, all package symbols will be exported in the final library/executable.

### Resiliency

Library evolution makes modules resilient. We can incorporate a package name into a resiliency check and bypass it if modules are in the same package. This will remove the need for resilience overhead such as indirection and language requirements such as `@unknown default` for an unfrozen `enum`.  

### Subclassing and Overrides

Access control in Swift usually doesn't distinguish between different kinds of use.  If a program has access to a type, for example, that gives the programmer a broad set of privileges: the type name can be used in most places, values of the type can be borrowed, copied, and destroyed, members of the type can be accessed (up to the limits of their own access control), and so on.  This is because access control is a tool for enforcing encapsulation and allowing the future evolution of code.  Broad privileges are granted because restricting them more precisely usually doesn't serve that goal.

However, there are two exceptions.  The first is that Swift allows `var` and `subscript` to restrict mutating accesses more tightly than read-only accesses; this is done by writing a separate access modifier for the setter, e.g. `private(set)`.  The second is that Swift allows classes and class members to restrict subclassing and overriding more tightly than normal references; this is done by writing `public` instead of `open`.  Allowing these privileges to be separately restricted does serve the goal of encapsulation and evolution.

Because setter access levels are controlled by writing a separate modifier from the primary access, the syntax naturally extends to allow `package(set)`.  However, subclassing and overriding are different because they are controlled by writing a specific keyword as the primary access modifier.  This proposal has to decide what `package` by itself means for classes and class members.  It also has to decide whether to support the options not covered by `package` alone or to leave them as a possible future direction.

Here is a matrix showing what access levels currently allow accessing or subclassing:

```
                                Accessible in...
                             ___anywhere___|____module_____
              |  anywhere   |     open     |   (illegal)
Subclassable  |  module     |    public    |    internal
    in...     |  nowhere    | public final | internal final

```

With `package` as a new access modifier, the matrix is modified like so:

```
                                      Accessible in...
                             ___anywhere____|_____package____|____module_____
              |  anywhere   |     open      |    (illegal)   |   (illegal)
Subclassable  |  package    |     open      |   packageopen  |   (illegal)
    in...     |  module     |    public     |     package    |    internal
              |  nowhere    |  public final |  package final |  internal final

```

Some of the boxes are naturally illegal: it of course doesn't make sense for a class to be subclassable when it can't access at all. 

A `package` class is accessible from outside of its defining modules as long as they are within the same package. Similar to `public`, it can only be subclassed within its defining module. If the `package` class needs to be subclassed outside of its defining module, a `package open` or `packageopen` (exact name TBD) needs to be used. This proposal focuses on `package`; the subclassing functionality (and the exact name) will be addressed in the future. 

The reason for not allowing both accessing and subclassing under `package` is as follows:

We want to allow a linear progression from `private` through `open` where each step incrementally offers capabilities to a wider range of clients. If `package` were to allow subclassing/overrides outside of its defining modules, making a `package` class `public` would break subclasses defined in other modules in the same package. 

We want to follow the optimization model for `public`; a `public` class has no subclasses outside of its defining module, and a `public` class member has no overrides outside of its defining module. The optimizer can take advantage of this information in whole-module builds to replace dynamic dispatch with static dispatch among other things. 

## Future Directions

Subclassing
* A separate access modifier will likely need to be introduced to allow subclassing and overriding within a package. The reason for a new access modifier is described in the Details section.

Namespacing 
* A package name might potentially be added to a mangled name. This could help disambiguate module names that clash.

Optimizations
* A package containing several modules can be treated as a resilience domain. If same-package clients need access to module binaries, they don't need to be independently rebuildable and could have an unstable ABI; they could avoid resilience overhead and unnecessary language rules. 

* By default, `package` symbols are exported in the final libraries/executables. We plan to introduce a build setting that allows users to decide whether to hide package symbols for statically linked libraries. Enabling package symbols to be hidden would help with size optimizations.

## Source compatibility

A new keyword `package` is added as a new access modifier. It is a contextual keyword and is an additive change. Symbols that are named `package` should not require renaming, and the source code as is should continue to work. 

## Effect on ABI stability

Boundaries between separately-built modules within a package are still potentially ABI boundaries. The ABI for package symbols is not different from the ABI for public symbols, although in the future we plan to add an option to not export package symbols that can be resolved within an image. 

## Alternatives considered

A current workaround for the scenario in the Motivation is to use `@_spi` or `@_implemenationOnly`. Each option has caveats. The `@_spi` requires a group name, which makes it verbose to use and harder to keep track of, and `@_implementationOnly` can be too limiting as we want to be able to restrict access to only portions of APIs. There are also hacky workarounds such as `@testable` and the `-disable-access-control` flag. They elevate all `internal` (and `private` with the flag) symbols to `public`. These options are unstable and also quickly lead to an increase of the binary and the shared cache size, not to mention symbol name clashes.

Instead of a package, submodules could have been considered. Introducing another "umbrella" module or dividing a module into "sub" modules, however, would require much more significant work and would be both source and ABI breaking. A package already exists as a unit corresponding to a group of modules, and treating it as a unit above a module in the grouping hierarchy enables a nautral transition into a submodule-like structure. 

## Acknowledgments

Doug Gregor, Becca Royal-Gordon, Allan Shortlidge, Artem Chikin, and Xi Ge provided helpful feedback and analysis as well as code reviews on the implementation.
