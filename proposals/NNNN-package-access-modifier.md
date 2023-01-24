# New access modifier: `package`

* Proposal: [SE-NNNN](NNNN-package-access-modifier.md)
* Authors: [Ellie Shin](https://github.com/elsh), [Alexis Laferriere](https://github.com/xymus)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Awaiting review**
* Implementation: [apple/swift#61546](https://github.com/apple/swift/pull/62700), [apple/swift#62704](https://github.com/apple/swift/pull/62704), [apple/swift#62652](https://github.com/apple/swift/pull/62652), [apple/swift#62652](https://github.com/apple/swift/pull/62652)
* Review: ([pitch](https://forums.swift.org/t/new-access-modifier-package/61459))

## Introduction

This proposal introduces `package` as a new access modifier.  Currently, to access a symbol in another module, that symbol needs to be declared `public`.  However, a symbol being `public` allows it to be accessed from any module at all, both within a package and from outside of a package, which is sometimes undesirable.  We need a new access modifier to enable a more fine control over the visibility scope of such symbols.  

## Motivation

At the most basic level, every Swift program is just a collection of declarations: functions, types, variables, and so on.  In principle, every level of organization above this is arbitrary; all of those declarations could be piled into a single file, compiled, and run.  In reality, Swift programs are organized into separate files, directories, libraries, and so on.  At each level, this organization reflects programmer judgment about relationships, both in the code and in how it is developed.

As a language, Swift recognizes some of these levels.  Modules are the smallest unit of library structure, with an independent interface and non-cyclic dependencies, and it makes sense for Swift to recognize that in both namespacing and access control.  Files are the smallest grouping beneath that and are often used to collect tightly-related declarations, so they also make sense to respect in access control.

Packages, as expressed by the Swift Package Manager, are a unit of code distribution.  Some packages contain just a single module, but it's frequently useful to split a package's code into multiple modules.  For example, when a module contains some internal helper APIs, those APIs can be split out into a utility module and maybe reused by other modules or packages.

However, because Swift does not recognize organizations of code above the module level, it is not possible to create APIs like this that are purely internal to the package.  To be usable from other modules within the package, the API must be public, but this means it can also be used outside of the package.  This allows clients to form unwanted source dependencies on the API.  It also means the built module has to export the API, which has negative implications for code size and performance.

For example, here’s a scenario where a client has access to a utility API from a package it depends on.  The client `App` could be an executable or an Xcode project.  It depends on a package called `gamePkg`, which contains two modules, `Game` and `Engine`.  

Here are source code examples.

```
[Engine (a module in gamePkg)]

public struct MainEngine {
    public init() { ...  }
    // Intended to be public
    public var stats: String { ...  }
    // A helper function made public only to be accessed by Game
    public func run() { ...  }
}

[Game (a module in gamePkg)]

import Engine

public func play() {
    MainEngine().run() // Can access `run` as intended since it's within the same package
}

[App (an executable in `appPkg`)]

import Game
import Engine

let engine = MainEngine()
engine.run() // Can access `run` from App even if it's not an intended behavior
Game.play()
print(engine.stats) // Can access `stats` as intended
```

In the above scenario, App can import Engine (a utility module in 'gamePkg') and access its helper API directly, even though the API is not intended to be used outside of its package.

Allowing this kind of unintended public access to package APIs is especially bad because packages are a unit of code distribution. Swift wants to encourage programs to be divided into modules with well-defined interfaces, so it enforces the boundaries between modules with access control. Despite being divided this way, it's not uncommon for closely-related modules to be written by closely-related (or even the same) people. Access control between such modules still serves a purpose — it promotes the separation of concerns — but if a module's interface needs to be fixed, that's usually easy to coordinate, maybe even as simple as a single commit. However, packages allow code to be shared much more broadly than a single small organization. The boundaries between packages often represent significant differences between programmers, making coordination around API changes much more difficult. For example, the developers of an open source package generally don't know most of their clients, and the standard recommendation is for such packages to only ever remove existing APIs in major-version releases. It's therefore particularly important to allow programmers to enforce these boundaries between packages.


## Proposed solution

Our goal is to introduce a mechanism to Swift to recognize a package as a unit in the aspect of access control.  We propose to do so by introducing a new access modifier called `package`.  The `package` access modifier allows symbols to be accessed from outside of their defining module, but only from other modules in the same package.  This helps to set clear boundaries between packages.  

## Detailed design

### `package` Keyword

`package` is introduced as an access modifier.  It cannot be combined with other access modifiers.
`package` is a contextual keyword, so existing declarations named `package` will continue to work.  This follows the precedent of `open`, which was also added as a contextual keyword.  For example, the following is allowed:

```
package var package: String {...}
```


### Declaration Site

The `package` keyword is added at the declaration site.  Using the scenario above, the helper API `run` can be declared with the new access modifier like so:

```
[Engine]

public struct MainEngine {
    public init() { ...  }
    public var stats: String { ...  }
    package func run() { ...  }
}
```

The `package` access modifier can be used anywhere that the existing access modifiers can be used, e.g. `class`, `struct`, `enum`, `func`, `var`, `protocol`, etc.

Swift requires that the declarations used in certain places (such as the signature of a function) be at least as accessible as the containing declaration. For the purposes of this rule, `package` is less accessible than `open` and `public` and more accessible than `internal`, `fileprivate`, and `private`. For example, a `public` function cannot use a `package` type in its parameters or return type, and a `package` function cannot use an `internal` type in its parameters or return type. Similarly, an `@inlinable` `public` function cannot use a `package` declaration in its implementation, and an `@inlinable` `package` function cannot use an `internal` declaration in its implementation.


### Use Site

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
### Package Names

Two modules belong to the same package if they were built with the same package name.  A package name must be unique and a valid C99 identifier, i.e. a string consisting of alphanumeric characters and an underscore, starting with a letter.  It is passed to the Swift frontend via a new flag `-package-name`.  Swift Package Manager has a package identity per package, an identifier that's verified to be unique via a registry, and it will pass the identifier down automatically.  Note that the package identity can contain URL characters, and such character will be transposed to an underscore.  Other build systems such as Bazel will need to introduce a new build setting for a package name.  Since it needs to be unique, a reverse-DNS name may be used to avoid clashing; a dot in such string will be transposed to an underscore.  

Here's an example of how a package name is passed to a commandline invocation.

```
swiftc -module-name Engine -package-name gamePkg ...
[Game] swiftc -module-name Game -package-name gamePkg ...
[App] swiftc App -package-name appPkg ...
```

When building the Engine module, the package name 'gamePkg' is recorded in the built interface to the module.  When building Game, its package name 'gamePkg' is compared with the package name recorded in Engine's built interface; since they match, Game is allowed to access Engine's `package` declarations.  When building App, its package name 'appPkg' is different from `gamePkg`, so it is not allowed to access `package` symbols in either Engine or Game, which is what we want.

If `-package-name` is not given, the `package` access modifier is disallowed.  Swift code that does not use `package` access will continue to build without needing to pass in `-package-name`.

When the Swift frontend builds a `.swiftmodule` file directly from source, the file will include the package name and all of the `package` declarations in the module.  When the Swift frontend builds a `.swiftinterface` file from source, the file will include the package name, but it will put `package` declarations in a secondary `.package.swiftinterface` file.  When the Swift frontend builds a `.swiftmodule` file from a `.swiftinterface` file that includes a package name, but it does not have the corresponding `.package.swiftinterface` file, it will record this in the `.swiftmodule`, and it will prevent this file from being used to build other modules in the same package.

### Exportability

`package` functions can be made `@inlinable`.  Just like with `@inlinable public`, not all symbols are usable within the function: they must be `open`, `public`, `package`, or `@usableFromInline`.  Note that `@usableFromInline` allows the use of a symbol from `@inlinable` functions whether they're `package` or `public`.  `@usableFromPackageInline` is introduced to export a symbol only for use by `@inlinable package` functions.

### Resiliency

Library evolution makes modules resilient.  We can incorporate a package name into a resiliency check and bypass it if modules are in the same package.  This will remove the need for resilience overhead such as indirection and language requirements such as `@unknown default` for an unfrozen `enum`.  

### Subclassing and Overrides

Access control in Swift usually doesn't distinguish between different kinds of use.  If a program has access to a type, for example, that gives the programmer a broad set of privileges: the type name can be used in most places, values of the type can be borrowed, copied, and destroyed, members of the type can be accessed (up to the limits of their own access control), and so on.  This is because access control is a tool for enforcing encapsulation and allowing the future evolution of code.  Broad privileges are granted because restricting them more precisely usually doesn't serve that goal.

However, there are two exceptions.  The first is that Swift allows `var` and `subscript` to restrict mutating accesses more tightly than read-only accesses; this is done by writing a separate access modifier for the setter, e.g. `private(set)`.  The second is that Swift allows classes and class members to restrict subclassing and overriding more tightly than normal references; this is done by writing `public` instead of `open`.  Allowing these privileges to be separately restricted does serve the goal of encapsulation and evolution.

Because setter access levels are controlled by writing a separate modifier from the primary access, the syntax naturally extends to allow `package(set)`.  However, subclassing and overriding are different because they are controlled by writing a specific keyword as the primary access modifier.  This proposal has to decide what `package` by itself means for classes and class members.  It also has to decide whether to support the options not covered by `package` alone or to leave them as a possible future direction.

Here is a matrix showing where each current access level can be used or overridable:

<table>
<thead>
<tr>
<th></th>
<th>Use</th>
<th>Override/Subclass</th>
</tr>
</thead>
<tbody>
<tr>
<th>internal</th>
<td align="center">in-module</td>
<td align="center">in-module</td>
</tr>
<tr>
<th>public</th>
<td align="center">cross-module</td>
<td align="center">in-module</td>
</tr>
<tr>
<th>open</th>
<td align="center">cross-module</td>
<td align="center">cross-module</td>
</tr>
<tr>
</tbody>
</table>

With `package` as a new access modifier, the matrix is modified like so:

<table>
<thead>
<tr>
<th></th>
<th>Use</th>
<th>Override/Subclass</th>
</tr>
</thead>
<tbody>
<tr>
<th>internal</th>
<td align="center">in-module</td>
<td align="center">in-module</td>
</tr>
<tr>
<th>package</th>
<td align="center">cross-module (in package)</td>
<td align="center">in-module</td>
</tr>
<tr>
<th>?(1)</th>
<td align="center">cross-module (in package)</td>
<td align="center">cross-module (in package)</td>
</tr>
<tr>
<th>?(2)</th>
<td align="center">cross-module (cross-package)</td>
<td align="center">cross-module (in package)</td>
</tr>
<tr>
<th>public</th>
<td align="center">cross-module (cross-package)</td>
<td align="center">in-module</td>
</tr>
<tr>
<th>open</th>
<td align="center">cross-module (cross-package)</td>
<td align="center">cross-module (cross-package)</td>
</tr>
<tr>
</tbody>
</table>

This proposal takes the position that `package` alone should not allow subclassing or overriding outside of the defining module.  This is consistent with the behavior of `public` and makes `package` fit into a simple continuum of ever-expanding privileges.  It also allows the normal optimization model of `public` classes and methods to still be applied to `package` classes and methods, implicitly making them `final` when they aren't subclassed or overridden, without requiring a new "whole package optimization" build mode.

However, this choice leaves no way to spell the two combinations marked in the table above with `?`.  These are more complicated to design and implement and are discussed in Future Directions.


## Future Directions

### Subclassing and Overrides
The entities marked with `?(1)` and `?(2)` from the matrix above both require accessing and subclassing cross-modules in a package (`open` within a package). The only difference is that (1) hides the symbol from outside of the package and (2) makes it visible outside. Use cases involving (2) should be rare but its underlying flow should be the same as (1) except its symbol visibility. 

We will need to expand on the existing `open` access modifier or introduce a new access modifier. The exact name is TBD, but so far suggestions include `packageopen`, `package open`, `open(package)`, and `open package(set)`. The `open package(set)` might be a good candidate since we can utilize the existing flow between `open` and `public` that allows subclasses to be `public` and expand on it to control the visibility of the base class. If we were to use a new access modifier, we might need more than one, e.g. `packageopen` that corresponds to (1) and `public packageopen` that corresponds to (2), and will also need to handle the inheritance access level hirearchy, i.e. whether subclasses can be `public` when their base class is `packageopen`.

We will add a function that returns a two-dimensioned value for use and override. It will return the correct access level for use and indication on whether it's overridable. From the use aspect, the access level determined should just be `package` if not one of the existing access level. The overridable bit should return whether it's subclassable or overridable for all access levels.

### Package-private 
If a module in a package only contains symbols that are `package` or more restrictive, the whole module can be treated as private to the package. This "package-only" module can be useful for organizing modules (a utility module vs a public facing module) and enforcing the boundary with diagnostics. It can also allow module aliasing to apply automatically without the explicit module aliases parameter, which could be useful for multi-version dependencies of a package.

### Optimizations
* A package containing several modules can be treated as a resilience domain.  If same-package clients need access to module binaries, they don't need to be independently rebuildable and could have an unstable ABI; they could avoid resilience overhead and unnecessary language rules.  

* By default, `package` symbols are exported in the final libraries/executables.  We plan to introduce a build setting that allows users to hide package symbols for statically linked libraries.  Enabling package symbols to be hidden would help with code size optimizations.

## Source compatibility

A new keyword `package` is added as a new access modifier.  It is a contextual keyword and is an additive change.  Symbols that are named `package` should not require renaming, and the source code as is should continue to work.  

## Effect on ABI stability

Boundaries between separately-built modules within a package are still potentially ABI boundaries.  The ABI for package symbols is not different from the ABI for public symbols, although in the future we plan to add an option to not export package symbols that can be resolved within an image.  

## Alternatives considered

### Use Current Workarounds
A current workaround for the scenario in the Motivation is to use `@_spi` or `@_implemenationOnly`.  Each option has caveats.  The `@_spi` requires a group name, which makes it verbose to use and harder to keep track of, and `@_implementationOnly` can be too limiting as we want to be able to restrict access to only portions of APIs.  There are also hacky workarounds such as `@testable` and the `-disable-access-control` flag.  They elevate all `internal` (and `private` with the flag) symbols to `public`.  These options are unstable and also quickly lead to an increase of the binary and the shared cache size, not to mention symbol name clashes.

### Introduce Submodules
Instead of adding a new package access level above modules, we could allow modules to contain other modules as components.  This is an idea often called "submodules".  Packages would then define an "umbrella" module that contains the package's modules as components.  However, there are several weaknesses in this approach:

* It doesn't actually solve the problem by itself.  Submodule APIs would still need to be able to declare whether they're usable outside of the umbrella or not, and that would require an access modifier.  It might be written in a more general way, like `internal(MyPackage)`, but that generality would also make it more verbose.
* Submodule structure would be part of the source language, so it would naturally be source- and ABI-affecting.  For example, programmers could use the parent module's name to qualify identifiers, and symbols exported by a submodule would include the parent module's name.  This means that splitting a module into submodules or adding an umbrella parent module would be much more impactful than desired; ideally, those changes would be purely internal and not change a module's public interface.  It also means that these changes would end up permanently encoding package structure.
* The "umbrella" submodule structure doesn't work for all packages.  Some packages include multiple "top-level" modules which share common dependencies.  Forcing these to share a common umbrella in order to use package-private dependencies is not desirable.
* In a few cases, the ABI and source impact above would be desirable.  For example, many packages contain internal Utility modules; if these were declared as submodules, they would naturally be namespaced to the containing package, eliminating spurious collisions.  However, such modules are generally not meant to be usable outside of the package at all.  It is a reasonable future direction to allow whole modules to be made package-private, which would also make it reasonable to automatically namespace them.


## Acknowledgments

Doug Gregor, Becca Royal-Gordon, Allan Shortlidge, Artem Chikin, and Xi Ge provided helpful feedback and analysis as well as code reviews on the implementation.
