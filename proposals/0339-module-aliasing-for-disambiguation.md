# Module Aliasing For Disambiguation

* Proposal: [SE-0339](0339-module-aliasing-for-disambiguation.md)
* Authors: [Ellie Shin](https://github.com/elsh)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Accepted** (with modifications not yet applied; see acceptance)
* Pitch: [Module Aliasing](https://forums.swift.org/t/pitch-module-aliasing/51737)
* Implementation: ([toolchain](https://github.com/apple/swift/pull/40899)),
[apple/swift-package-manager#4023](https://github.com/apple/swift-package-manager/pull/4023), others
* Review: ([review](https://forums.swift.org/t/se-0339-module-aliasing-for-disambiguation/54730)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0339-module-aliasing-for-disambiguation/55032))

## Introduction

Swift does not allow multiple modules in a program to share the same name, and attempts to do so will fail to build. These name collisions can happen in a reasonable program when using multiple packages developed independently from each other. This proposal introduces a way to resolve these conflicts without making major, invasive changes to a package's source by turning a module name in source into an alias, a different unique name.

## Motivation

As the Swift package ecosystem has grown, programmers have begun to frequently encounter module name clashes, as seen in several forum discussions including [module name 'Logging' clash in Vapor](https://forums.swift.org/t/logging-module-name-clash-in-vapor-3/25466) and [namespacing packages/modules regarding SwiftNIO](https://forums.swift.org/t/namespacing-of-packages-modules-especially-regarding-swiftnio/24726). There are two main use cases where these arise:

* Two different packages include logically different modules that happen to have the same name.  Often, these modules are "internal" dependencies of the package, which would be submodules if Swift supported submodules; for example, it's common to put common utilities into a `Utils` module, which will then collide if more than one package does it.  Programmers often run into this problem when adding a new dependency or upgrading an existing one.
* Two different versions of the same package need to be included in the same program.  Programmers often run into this problem when trying to upgrade a dependency that another library has pinned to a specific version.  Being unable to resolve this collision makes it difficult to gradually update dependencies, forcing migration to be done all at once later.

In both cases, it is important to be able to resolve the conflict without making invasive changes to the conflicting packages.  While submodules might be a better long-term solution for the first case, they are not currently supported by Swift.  Even if submodules were supported, they might not always be correctly adopted by packages, and it would not be reasonable for package clients to have to rewrite the package to properly use them.  Submodules and other namespacing features would not completely eliminate the need to "retroactively" resolve module name conflicts.

## Proposed solution

We believe that module aliasing provides a systematic method for addressing module name collisions. The conflicting modules can be given unique names while still allowing the source code that depends on them to compile. There's already a way to set a module name to a different name, but we need a new aliasing technique that will allow source files referencing the original module names to compile without making source changes. This will be done via new build settings which will then translate to new compiler flags described below. Together, these low-level tools will allow conflicts to be resolved by giving modules a unique name while using aliases to avoid the need to change any source code. 

We propose to introduce the following new settings in SwiftPM. To illustrate the flow, let's go over an example. Consider the following scenario: `App` imports the module `Game`, which imports a module `Utils` from the same package. `App` also imports another module called `Utils` from a different package. This collision might have been introduced when updating to a new version of `Game`'s package, which introduced an "internal" `Utils` module for the first time.

```
App 
  |— Module Game (from package ‘swift-game’)
      |— Module Utils (from package ‘swift-game’)
  |— Module Utils (from package ‘swift-draw’) 
```

The modules from each package have the following code:

```
[Module Game] // swift-game

import Utils  // swift-game
public func start(level: Utils.Level) { ... }
```

```
[Module Utils] // swift-game

public struct Level { ... }
public var currentLevel: Utils.Level { ... }
```

```
[Module Utils] // swift-draw

public protocol Drawable { ... }
public class Canvas: Utils.Drawable { ... }
```

Since `App` depends on these two `Utils` modules, we have a conflict, thus we need to rename one. We will introduce a new setting in SwiftPM called `moduleAliases` that will allow setting unique names for dependencies, like so:
```
 targets: [
  .executableTarget(
    name: "App",
    dependencies: [
     .product(name: "Game", moduleAliases: ["Utils": "GameUtils"], package: "swift-game"), 
     .product(name: "Utils", package: "swift-draw"), 
   ])
 ]
```

The setting `moduleAliases` will rename `Utils` from the `swift-game` package as `GameUtils` and alias all its references in the source code to be compiled as `GameUtils`. Since renaming one of the `Utils` modules will resolve the conflict, it is not necessary to rename the other `Utils` module. The references to `Utils` in the `Game` module will be built as `GameUtils` without requiring any source changes. If `App` needs to reference both `Utils` modules in its source code, it can do so via the unique names:
```
[App]

import GameUtils
import Utils
```

Module aliasing relies on being able to change the namespace of all declarations in a module, so initially only pure Swift modules will be supported and users will be required to opt in.  Support for languages that give declarations names outside of the control of Swift, such as Objective-C, C, and C++, would be limited as it will require special handling; see the **Requirements / Limitations** section for more details.


## Detailed design

### Changes to Swift Frontend

Most use cases should just require setting `moduleAliases` in a package manifest.  However, it may be helpful to understand how that setting changes the compiler invocations under the hood. In our example scenario, those invocations will change as follows:

1. First, we need to take the `Utils` module from `swift-game` and rename it `GameUtils`. To do this, we will compile the module as if it was actually named `GameUtils`, while treating any references to `Utils` in its source files as references to `GameUtils`.
    1. The first part (renaming) can be achieved by passing the new module name (`GameUtils`) to `-module-name`. The new module name will also need to be used in any flags specifying output paths, such as `-o`,  `-emit-module-path`, or `-emit-module-interface-path`.  For example, the binary module file should be built as `GameUtils.swiftmodule` instead of `Utils.swiftmodule`.
    2. The second part (treating references to `Utils` in source files as `GameUtils`) can be achieved with a new compiler flag `-module-alias [name]=[new_name]`. Here, `name` is the module name that appears in source files (`Utils`), while `new_name` is the new, unique name (`GameUtils`).  So in our example, we will pass `-module-alias Utils=GameUtils`.
    
    Putting these steps together, the compiler invocation command would be `swiftc -module-name GameUtils -emit-module-path /path/to/GameUtils.swiftmodule -module-alias Utils=GameUtils ...`.
    
    For all intents and purposes, the true name of the module is now `GameUtils`.  The name `Utils` is no longer associated with it.  Module aliases can be used in specific parts of the build to allow source code that still uses the name `Utils` (possibly including the module itself) to continue to compile.
2. Next, we need to build the module `Game`.  `Game` contains references to `Utils`, which we need to treat as references to `GameUtils`. We can do this by just passing `-module-alias Utils=GameUtils` without any other changes. The overall compiler invocation command to build `Game` is `swiftc -module-name Game -module-alias Utils=GameUtils ...`. 
3. We don't need any build changes when building `App` because the source code in `App` does not expect to use the `Utils` module from `swift-game` under its original name.  If `App` tries to import a module named `Utils`, that will refer to the `Utils` module from `swift-draw`, which has not been renamed.  If `App` does need to import the `Utils` module from `swift-game`, it must use `import GameUtils`.


The arguments to the `-module-alias` flag will be validated against reserved names, invalid identifiers, wrong format or ordering (`-module-alias Utils=GameUtils` is correct but `-module-alias GameUtils=Utils` is not). The flag can be repeated to allow multiple aliases, e.g. `-module-alias Utils=GameUtils -module-alias Logging=SwiftLogging`, and will be checked against duplicates. Diagnostics and fix-its will contain the name Utils in the error messages as opposed to GameUtils to be consistent with the names appearing to users. 

The validated map of aliases will be stored in the AST context and used for dependency scanning/resolution and module loading; from the above scenario, if Game is built with `-module-alias Utils=GameUtils` and has `import Utils` in source code, `GameUtils.swiftmodule` should be loaded instead of `Utils.swiftmodule` during import resolution.  

While the name Utils appears in source files, the actual binary name will be used for name lookup, semantic analysis, symbol mangling (e.g. `$s9GameUtils5Level`), and serialization. Since the binary names will be stored during serialization, the aliasing flag will only be needed to build the conflicting modules and their immediate consuming modules; building non-immediate consuming modules will not require the flag. 

The module alias map will also be used to disallow any references to the binary module names in source files; only the name Utils should appear in source files, not the binary name GameUtils. This is true only if the `-module-alias` was used to build the module (if the renamed modules were directly imported, those names (binary module names) can appear in source files). This restriction is useful as it can make it easier to rename the module again later if needed, e.g. from GameUtils to SwiftGameUtils.   

Unlike source files, the generated interface module (.swiftinterface) will contain the binary module name in all its references. The binary module name will also be stored for indexing and debugging, and treated as the source of truth. 

### Changes to Code Assistance / Indexing

The compiler arguments including the new flag `-module-alias` will be available to SourceKit and indexing. The aliases will be stored in the AST context and used to fetch the right results for code completion and other code assistance features. They will also be stored for indexing so features such as jump to definition can navigate to decls under the binary module names. 

Generated documentation, quick help, and other assistance features will contain the binary module names, which will be treated as the source of truth. 

### Changes to Swift Driver

The module aliasing arguments will be used during dependency scan for both implicit and explicit build modes; the resolved dependency graph will contain the binary module names. In case of the explicit build mode, the dependency input passed to the frontend will contain the binary module names in its json file. Similar to the frontend, validation of the aliasing arguments will be performed at the driver. 

### Changes to SwiftPM

To make module aliasing more accessible, we will introduce new build configs which can map to the compiler flags for aliasing described above. Let’s go over how they can be adopted by SwiftPM with the above scenario (copied below). 
```
App 
  |— Module Game (from package ‘swift-game’)
      |— Module Utils (from package ‘swift-game’)
  |— Module Utils (from package ‘swift-draw’) 
```

Here are the example manifests for `swift-game` and `swift-draw`. 

```
{
 name: "swift-game",
 dependencies: [],
 products: [
   .library(name: "Game", targets: ["Game"]),
   .library(name: "Utils", targets: ["Utils"]),
 ],
 targets: [
   .target(name: "Game", targets: ["Utils"]),
   .target(name: "Utils", dependencies: [])
 ]
}
```

```
{
 name: "swift-draw",
 dependencies: [],
 products: [
   .library(name: "Utils", targets: ["Utils"]),
 ],
 targets: [
   .target(name: "Utils", dependencies: [])
 ]
}
```

The `App` manifest needs to explicitly define unique names for the conflicting modules via a new parameter called `moduleAliases`. 
```
{
 name: "App",
 dependencies: [
  .package(url: https://.../swift-game.git),
  .package(url: https://.../swift-draw.git)
 ],
 products: [
  .executable(name: "App", targets: ["App"])
 ]
 targets: [
  .executableTarget(
    name: "App",
    dependencies: [
     .product(name: "Game", moduleAliases: ["Utils": "GameUtils"], package: "swift-game"), 
     .product(name: "Utils", package: "swift-draw"), 
   ])
 ]
}
```

SwiftPM will check validations on `moduleAliases`; for each entry in `moduleAliases`, it will check if the specified module meets the requirements described in the **Requirements/Limitations** section below, such as whether the module is a pure Swift module. If validations pass, it will trigger a build with `-module-alias` for the module as described earlier. Note that only one new name can be given to a conflicting module and it should be a unique name. 


### Resources

Tools invoked by a build system to compile resources should be modified to handle the module aliasing. The module name entry should get the renamed value and any references to aliased modules in the resources should correctly map to the corresponding binary names. The resources likely impacted by this are IB, CoreData, and anything that explicitly requires module names. We will initially only support asset catalogs and localized strings as module names are not required for those resources. 

### Debugging

When module aliasing is used, the binary module name will be stored in mangled symbols, e.g. `$s9GameUtils5Level` instead of `$s5Utils5Level`, which will be stored in Debuginfo.

For evaluating an expression, the name Utils can be used as it appears in source files (that were already compiled with module aliasing); however, the result of the evaluation will contain the binary module name. 

If a module were to be loaded directly into lldb, the binary module name should be used, i.e. `import GameUtils` instead of `import Utils`, since it does not have access to the aliasing flag. 

In REPL, binary module names should be used for importing or referencing; support for aliasing in that mode may be added in the future.

## Requirements / Limitations

To allow module aliasing, the following requirements need to be met, which come with some limitations.

* Only pure Swift modules allowed for aliasing: no ObjC/C/C++/Asm due to potential symbol collision. Similarly, `@objc(name)` is discouraged. 
* Building from source only: aliasing distributed binaries is not possible due to the impact on mangling and serialization.
* Runtime: calls to convert String to types in module, i.e direct or indirect calls to `NSClassFromString(...)`, will fail and should be avoided.
* For resources, only asset catalogs and localized strings are allowed.
* Higher chance of running into the following existing issues:
    * [Retroactive conformance](https://forums.swift.org/t/retroactive-conformances-vs-swift-in-the-os/14393): this is already not a recommended practice and should be avoided.   
    * Extension member “leaks”: this is [considered a bug](https://bugs.swift.org/browse/SR-3908) which hasn’t been fixed yet. More discussions [here](https://forums.swift.org/t/pre-pitch-import-access-control-a-modest-proposal/50087). 
* Code size increase will be more implicit and requires a caution, although module aliasing will be opt-in and a size threshold could be added to provide a warning. 

## Source compatibility
This is an additive feature. Currently when there are duplicate module names, it does not compile at all. This feature requires explicitly opting in to allow and use module aliaisng via package manifests or compiler invocation commands and does not require source code changes. 

## Effect on ABI stability
The feature in this proposal does not have impact on the ABI.

## Effect on API resilience
This proposal does not introduce features that would be part of a public API.

## Future Directions

* Currently when a module contains a type with the same name, fully qualifying a decl in the module results in an error; it treats the left most qualifier as a type instead of the module ([SR-14195](https://bugs.swift.org/browse/SR-14195), [pitch](https://forums.swift.org/t/fixing-modules-that-contain-a-type-with-the-same-name/3025), [pitch](https://forums.swift.org/t/pitch-fully-qualified-name-syntax/28482)); `XCTest` is a good example as it contains a class called `XCTest`. Trying to access a top level function `XCTAssertEqual` via `XCTest.XCTAssertEqual(...)` results in `Type 'XCTest' has no member 'XCTAssertEqual'` error. Module aliasing could mitigate this issue by renaming `XCTest` as `XCTestFramework` without requiring source changes in the `XCTest` module and allowing the function access via `XCTestFramework.XCTAssertEqual(...)` in the user code.

* Introducing new import syntax such as `import Utils as GameUtils` has been discussed in forums to improve module disambiguation. The module aliasing infrastructure described in this proposal paves the way towards using such syntax that could allow more explicit (in source code) aliasing.  

* Visibility change to import decl access level (from public to internal) pitched [here](https://forums.swift.org/t/pre-pitch-import-access-control-a-modest-proposal/50087) could help address the extension leaks issues mentioned in **Requirements / Limitations** section. 

* Swift modules that have C target dependencies could, in a limited capacity, be supported by changing visibility to C symbols.

* C++ interop support could potentially allow C++ modules to be aliased besides pure Swift modules.  

* Nested namespacing or submodules might be a better long-term solution for some of the collision issues described in **Motivation**. However, it would not completely eliminate the need to "retroactively" resolve module name conflicts. Module aliasing does not introduce any lexical or structural changes that might have an impact on potential future submodules support; it's an orthogonal feature and can be used in conjunction if needed.

## Acknowledgments
This proposal was improved with feedback and helpful suggestions along with code reviews by Becca Royal-Gordon, Alexis Laferriere, John McCall, Joe Groff, Mike Ash, Pavel Yaskevich, Adrian Prantl, Artem Chikin, Boris Buegling, Anders Bertelrud, Tom Doron, and Johannes Weiss, and others.  
