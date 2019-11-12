# Package Manager Resources

* Proposal: [SE-0271](0271-package-manager-resources.md)
* Authors: [Anders Bertelrud](https://github.com/abertelrud), [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Boris Buegling](https://github.com/neonichu)
* Status: **Active review (11 12...11 19)**

## Introduction

Packages should be able to contain images, data files, and other resources needed at runtime.  This proposal describes SwiftPM support for specifying such package resources, and introduces a consistent way of accessing them from the source code in the package.

## Motivation

Packages consist primarily of source code intended to be compiled and linked into client executables.  Sometimes, however, the code needs additional resources that are expected to be available at runtime.  Such resources could include images, sounds, user interface specifications, OpenGL or Metal shaders, and other typical runtime resources.  During the build, some package resources might be copied verbatim into the product, while others might need to be processed in some way.

Resources aren't always intended for use by clients of the package; one use of resources might include test fixtures that are only needed by unit tests.  Such resources would not be incorporated into clients of the package along with the library code, but would only be used while running the package's tests.

One of the fundamental principles behind SwiftPM is that packages should be as platform-independent and client-agnostic as possible:  in particular, packages should make as few assumptions as possible about the details of how they will be incorporated into a particular client on a particular platform.

For example, a package product might in one case be built as a dynamic library or a framework that is embedded into an application bundle, and might in another case be statically linked into the client executable.  These differences might be due to requirements of the platform for which the package is being built, or might be a result of deployment packaging choices made by the client.

Packages should therefore be able to specify resources in a platform-independent way, and SwiftPM should provide a consistent way to access those resources without requiring the source code to make assumptions about exactly where the resources will be at runtime.  For example, the source code cannot assume that the resources will be in the same bundle as the compiled code (if bundles even exist as separate entities on a given platform).

Build systems (such as those in SwiftPM, Xcode, etc) are then free to build resources for runtime use in any way they choose, as long as the API for accessing those resources at runtime continues to work as described in this document.

## Goals

The most important goals of this design include:

* Making it easy to add resource files in a package.

* Avoiding unintentionally copying files not intended to be resources (e.g.  design documents) into the product.

* Supporting platform-specific resource types for packages written using specific APIs (e.g. Storyboards, XIBs, and Metal shaders on Apple platforms).

* Supporting localization.

* Letting package authors put resources where they like in their source directories (to allow functional organization of large code bases).

## Proposed Solution

We propose the following to support resources in Swift packages:

- Scope resources to targets i.e. resource files will be part of a target just like source files.

- Extend SwiftPM's file detection capabilities and apply a "rule" to every file in the target. SwiftPM will emit an error for any file in a target for which it is not able to automatically determine the rule. 

- Add two new rules "copy" and "process" to existing list of rules. At this time, there will be no additional built-in file type that use these two new rules. 

- Vend an API in libSwiftPM to allow its clients to register additional file types supported by those clients. SwiftPM will automatially detect the matching files in a target and report them in the package model data structure. Similar to source files, package authors will not need to explicitly declare these files in the package manifest. This ability is useful for clients like Xcode to support platform-specific file types (such as `.metal`) without having to bake in a hardcoded list in SwiftPM’s codebase.

- Add a new `resources` parameter in `target` and `testTarget` APIs to allow declaring resource files explicitly.

- Create a bundle for each module with resources and generate a `Resources` struct for each module it compiles for accessing the bundle. 

## Detailed Design

### Declaring Resources

The `target` and `testTarget` function in the PackageDescription API will be extended to have an optional `resources` parameter:

```swift
public static func target(
    name: String,
    dependencies: [Target.Dependency] = [],
    path: String? = nil,
    exclude: [String] = [],
    sources: [String]? = nil,
    resources: [Resource]? = nil,   // <=== NEW
    publicHeadersPath: String? = nil,
    cSettings: [CSetting]? = nil,
    cxxSettings: [CXXSetting]? = nil,
    swiftSettings: [SwiftSetting]? = nil,
    linkerSettings: [LinkerSetting]? = nil
) -> Target
```

Where the `Resource` type is defined as:

```swift
/// Represents an individual resource file.
public struct Resource {
    /// Apply the platform-specific rule to the given path.
    ///
    /// Matching paths will be processed according to the platform for which this
    /// target is being built. For example, image files might get optimized when
    /// building for platforms that support such optimizations.
    ///
    /// By default, a file will be copied if there is no specialized processing
    /// for its file type.
    ///
    /// If path is a directory, the rule is applied recursively to each file in the
    /// directory. 
    public static func process(_ path: String) -> Resource

    /// Apply the copy rule to the given path.
    ///
    /// Matching paths will be copied as-is and will be at the top-level
    /// in the bundle. The structure is retained for if path is a directory.
    public static func copy(_ path: String) -> Resource
}
```

The exact API in `libSwiftPM` for registering additional resource file types will be an implementation detail since it currently does not have a stable API.  However, there will be *some* API that provides this functionality. Such file types will be automatically picked up by SwiftPM and will not require explicit declaration using the `resources` parameter. SwiftPM contributors will iterate on this API with existing and future clients. For example, if Xcode registers `.metal` as a file type and there is a metal file in a target, the package will not need to declare that file in the resources list. However, the package can override the default rule for this file by adding it to the exclude list or by specifying the "copy" rule for this file.

Packages will also be able to explicitly declare the resource files using the two new APIs in `PackageDescription`. These APIs have some interesting behavior when the given path is a directory:

- The `.copy` API allows copying directories as-is which is useful if a package author wants to retain the directory structure.

- The `.process` API allows applying the rule recursively to files inside a directory. This is useful for packages that have all of its resources contained in directories for organization.

Each file in a target will be required to have a rule. SwiftPM will emit an error if it is not able to automatically determine the rule for a file. For example, if there is a `README.md` in the target, the package will need to make an explicit decision about this file by either adding to the exclude list or in the resources list.

### Resources Bundle

For each target that defines at least one resource file, SwiftPM will produce a Foundation-style bundle whose name and identifier are derived from an implementation-defined unique combination of the package name and the target name (the package source code should not concern itself with the exact name).  On Linux, each such resource bundle will be located next to the built executable that is the ultimate client of the target containing the resources.  On macOS and related platforms, each such bundle is located at a place of the build system's choosing (typically nested inside the ultimate client's main bundle).

Note that the construction of a bundle to hold the resources does not necessarily mean that the code is in the same bundle, i.e. it is not necessarily a framework.  Whether or not the code is colocated with the resources is an implementation detail.  The key part of this proposal is that the package's code not make any assumptions that limits the build system's choices in where to put the resources, as long as it can make them accessible to the package code at runtime.

### Runtime Access to Resources Bundle

SwiftPM will generate an internal static extension on `Bundle` for each module it compiles:

```swift
extension Bundle {
    /// The bundle associated with the current Swift module.
    static let module: Bundle = { ... }()
}
```

Because this is an internal static property, it would be visible only to code within the same module, and the implementations for each module would not interfere with each other. The implementation generated by SwiftPM would use information about the layout of the built product to instantiate and cache the bundle that contains the resources.

The first access to the `module` property would cause the bundle to be instantiated.  Modules without any resources would not have resource bundles, and for such modules, no declaration would be created.

Some examples:

```swift
// Get path to DefaultSettings.plist file.
let path = Bundle.module.path(forResource: "DefaultSettings", ofType: "plist")

// Load an image that can be in an asset archive in a bundle.
let image = UIImage(named: "MyIcon", in: Bundle.module, compatibleWith: UITraitCollection(userInterfaceStyle: .dark))

// Find a vertex function in a compiled Metal shader library.
let shader = try mtlDevice.makeDefaultLibrary(bundle: Bundle.module).makeFunction(name: "vertexShader")

// Load a texture.
let texture = MTKTextureLoader(device: mtlDevice).newTexture(name: "Grass", scaleFactor: 1.0, bundle: Bundle.module, options: options)
```

Because the name of the accessor would always be `module`, code could be moved between modules (as long as the resources were moved as well) without requiring any source code changes.

This would be an improvement over the status quo in Cocoa code, which involves either `Bundle.init(for:<class>)` or `Bundle.init(identifier:)`.  The former is problematic because it assumes that the resources will necessarily be in the same bundle as the code (which won't be true for statically linked code), and the latter is problematic because it hardcodes the identifier name (and also because it doesn't automatically cause the bundle to be loaded if it hasn't been loaded already).

This approach also allows creating codeless resource bundles. Any package target that really wants to just vend the bundle of resources could implement a single property to publicly expose the bundle to clients. It seems reasonable that the package authors have to explicitly vend them.

For Objective-C, the build system will add a preprocessor define called `SWIFTPM_MODULE_BUNDLE` which can be used to access the bundle from any `.m` file.

### Localization Support

Localization support will build on top of the resources feature described in this proposal. We think resources and localization support are separable and it would be better to discuss localization in its own proposal.

## Rationale

This section describes the rationale for some of the design decisions taken in this proposal.

### Scoping of Resources to targets

Resources are most commonly referenced by the code that needs them, so it seems natural to consider source files and resource files as conceptually being a part of the same target.  Any client that depends on the target's code also needs the associated resources to be available at runtime (though it usually doesn't access them directly, but instead through the code that makes use of them).

Furthermore, the processing of some types of resources might result in the generation of more source code, which needs to be compiled into the same module as the code that needs the resource.  For this reason, too, it is natural to consider the resources (and any generated code) as conceptually being a part of the same target as the code that uses it.

Scoping resources by target also aligns naturally with how targets are currently built in other development environments that support resources:  in Xcode, for example, each target is built into a CFBundle (usually a framework or an application), and any resources associated with the target are copied into that bundle.  Since a bundle provides a namespace for the resources in it, scoping resources by target is natural.

If resources were not scoped by target, there would need to be some way to associate the resources with the source code that needs them.  This could take the form of defining a separate resource target, and making the code target depend on that resource target.  A library that needs just one or two resources would then require the use of two separate targets (one for the code and another for the resources).  This seems needlessly complicated, and is therefore not the approach used by this proposal.

### Rules for determining resource files

SwiftPM uses file system conventions for determining the set of source files that belongs to each target in a package:  specifically, a target's source files are those that are located underneath the designated "target directory" for the target.  By default this is a directory that has the same name as the target and is located in "Sources" (for a regular target) or "Tests" (for a test target), but this location can be customized in the package manifest.

Given that resources are conceptually associated with targets (as discussed in the previous section), then it seems logical for those resources to also reside inside the directories of the targets to which they belong.

The question then becomes how to determine which of the target files to treat as resources and which to treat as source files.

A flexible approach would be to treat resource files the same as source files, using rules to determine how to process each file inside the target directory.  Just as for source files, each resource file's role would be determined by its file type (as indicated by its filename suffix).

For example, SwiftPM already recognizes files with suffixes such as `.swift`, `.c`, `.s`, etc as source files, and has built-in rules to determine which build tool to invoke for each known type of source file.

This could be viewed as simply broadening the notion of what constitutes a "source file" beyond just source code to be compiled and linked into the executable part of the product;  the executable code is, after all, just one aspect of the built artifact.  In this broadened view, Storyboards, XIBs, Metal shaders, and Xcode Asset Catalogs are all just compiled to produce other kinds of files that then get incorporated into the built product.

Processing resource files the same way as source files is especially natural for file types that don't fit neatly into a source file / resource file dichotomy, such as Metal shaders and CoreData models.  Metal shaders, for example, are compiled as source code, and linked together to produce binary resource files that are loaded at runtime.  CoreData models are also compiled, and may generate source code as part of that compilation.

Specialized file types such as Storyboards, XIBs, CoreData models, or Metal shaders doesn't introduce much risk of mischaracterizing the intent of having the file in the target; these are specialized file types with unambiguous filename suffixes and a clear purpose.

But multi-purpose file types such as `.md`, `.png`, `.jpg`, `.txt`, or `.pdf` are more problematic:  should a Markdown file or a PDF found in a source directory be treated as a resource to be copied into the built product, or is it just a document describing internal implementation details?  Similarly, is any given PNG file an artwork resource, or does it perhaps belong to a Markdown file containing internal design notes?  And files of an unknown type altogether might or might not be resources, without any clear way for SwiftPM to tell.

On several occasions, developers have accidentally ended up shipping internal design documents or other files because they were automatically included as resources in their apps based on their types.

This design aims to reduce that risk as much as possible by limiting the additional built-in rules to only those file types where the intent is clear (Storyboards, XIBs, Metal shaders, CoreData models, Xcode Asset Catalogs, etc).  Resource files of more ambiguous types have to be explicitly designated as resources.

## Impact on existing packages

The new APIs and behavior described in this proposal will be guarded against the tools version this proposal is implemented in. Packages that want to use this feature will need to update their tools version.

Once a package updates its tools version, it might need to make some changes to make explicit decisions about any files that were previously being ignored implicitly.

## Alternatives considered

### Requiring all resources to be in a special directory

While an approach involving a magical directory (such as one in a particular location and with a particular name) might be simpler, it would cause problems with adding package support for the large number of CocoaPods and other projects that don't have all of their resources confined to a particular directory.

One possible approach would be consider resource files as being completely disjoint from source files, requiring all of a target's resources to be located in a separate "Resources" directory inside the target directory.

While this might be appropriate for some source package layouts, many existing source hierarchies are not structured this way.  For example, many CocoaPods have resource files interspersed with source files; this is also common in Xcode projects.

This practice is especially common for types of resource files that are closely associated with source files; for example, Storyboards and XIB files are commonly located together with the source code that loads those Storyboards and XIB files, grouped by functional component.

A variation of this would be to have a new top-level "Resources" directory next to "Sources" and "Targets", and to rely on naming conventions to associate a target's resources with a target's sources, but that moves the resources even further from the existing source hierarchy for the target.

## Future Directions

### Type-safe access to individual resource files

Historically, macOS and iOS resources have been accessed primarily by name, using untyped Bundle APIs such as `path(forResource:ofType:)` that assume that each resource is stored as a separate file.  Missing resources or mismatched types (e.g. trying to load a font as an image) have historically resulted in runtime errors rather than being detected at build time.

In the long run, we would like to do better.  Because SwiftPM knows the names and types of resource files, it should be able provide type-safe access to those resources by, for example, generating the right declarations that the package's authored code could reference.  Missing or mismatched resources would produce build-time errors, leading to early detection of problems.

This would also serve to separate the referencing of a resource from the details about how that resource is stored in the built artifact; instead of getting the path to an image, for example, and then loading that image using a separate API (which assumes that the image is stored in a separate file on disk), the image accessor could do whatever is needed to load the image based on the platform and build-time processing that was done, so that the package code doesn't have to be aware of such details.

In the short term, however, we want to keep things simple and allow existing code to work without major modifications.  Therefore, the short-term approach suggested here is to stay with Bundle APIs for the actual resource access, and to provide a very simple way for code in a package to access the bundle associated with that code.  A future proposal could introduce typed resource references as additional functionality.

### Filename patterns

As a separate enhancement, we would like to consider enhancing sources, exclude and resources array to accept a glob pattern using `fnmatch()` semantics.  The semantics involving the presence or absence of a path separator are useful in that they provide great expressibility in a manner that is intuitive for anyone familiar with shell name-vs-path lookup semantics etc.
