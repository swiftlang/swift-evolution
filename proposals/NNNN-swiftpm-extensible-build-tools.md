# Package Manager Extensible Build Tools

* Proposal: [SE-NNNN](NNNN-filename.md)
* Authors: [Anders Bertelrud](https://github.com/abertelrud), [Konrad 'ktoso' Malawski](https://github.com/ktoso), [Tom Doron](https://github.com/tomerd)
* Review Manager: TBD
* Status: **WIP**
* Previous Pitch and Forum Discussion: [Package Manager Extensible Build Tools](https://forums.swift.org/t/package-manager-extensible-build-tools/10900)

## Introduction

This is a proposal for extensible build tools support in Swift Package Manager. The initial set of functionality is intentionally basic, and focuses on a general way of allowing extensions to add commands to the build graph. The approach is to:

- provide a scalable way for packages to define extensions that can provide build-related capabilities
- support a narrowly scoped initial set of possible capabilities that extensions can provide

The set of possible capabilities can then be extended in future SwiftPM versions. The goal is to provide short-term support for common tasks such as source code generation, with a design that can scale to more complex tasks in the future.

This proposal depends on improvements to the existing Binary Target type in SwiftPM — the details are the subject of a separate proposal that will be put up for review shortly after this one and whose review period will end concurrently with this one.

## Motivation

SwiftPM doesn’t currently provide any means of performing custom actions during a build. This includes source generation as well as custom processing for special types of resources.

This is very restrictive, and affects even packages with relatively simple customization needs.  Examples include invoking source generators such as [SwiftProtobuf](https://github.com/apple/swift-protobuf) or [SwiftGen](https://github.com/SwiftGen/SwiftGen), or running a custom command to do various kinds of source generation or source inspection.

Providing even basic support for extensibility is expected to allow more codebases to be built using the Swift Package Manager, and to automate many steps that package authors currently have to do manually (such as generate sources manually and commit them to their package repositories).

## Proposed solution

This proposal introduces a new SwiftPM target type called `extension`.

Package extensions are Swift targets that use specialized API in a new `PackageExtension` library (provided by SwiftPM) to configure commands that will run during the build.

The initial `PackageExtension` API described in this proposal is minimal, and is mainly focused on source code generation.  However, this API is expected to be able to grow over time to support new package extension capabilities in the future.

Package extensions are somewhat analogous to package manifests:  both are Swift scripts that are evaluated in sandboxed environments and that use specialized APIs for a limited and specific purpose.  In the case of a package manifest, the purpose is to define those characteristics of a package that cannot be inferred from the contents of the file system.  In the case of a package extension, the purpose is to procedurally define new commands and dependencies that should run before, during, or after a build.

A package extension is invoked after package resolution and validation, and is given access to an input context that describes the target to which the extension is applied. The package extension also has read-only access to the package directory of the target, and is also allowed to write to specially designated areas of the build output directory.

Note that the extension itself does *not* perform the actual work of the build tool — that’s done by the command line invocation that the package extension creates.  The extension can be thought of as a procedural way of generating command line arguments, and is typically quite small.

Because extensions are SwiftPM targets, the use of an extension is specified by depending on the extension target in the regular way.

This initial proposal does not directly provide a way for the client of an extension target to specify configuration parameters to the extension. However, because extensions have read-only access to the package directory, they can read custom configuration files as needed. While this means that configuration of the extension resides outside of the package manifest, it does allow each package extension to provide a configuration format suitable for its own needs. This pattern is commonly used in practice already, in the form of configuration files that are used to configure source generators, etc. Future proposals are expected to let package extensions define options that can be controlled in the client package's manifest.

A package extension target should declare dependencies on the targets that provide the executable tools that will be needed during the build. The binary target type will be extended to let it vend pre-built executables for build tools that aren't built with SwiftPM (this is the subject of a separate upcoming companion proposal to this one, as mentioned in the introduction).

A package extension script will not initially be able to use other libraries than `PackageExtension` and the Swift standard libraries. Note that the extension itself is only expected to contain a minimal amount of logic to construct a command that will invoke a tool during the actual build. The tool that is invoked during the build (the one for which the extension generates a command line) is a regular target of the `executable` type and can depend on an arbitrary number of other SwiftPM targets, or can be provided as a binary artifact.

It is a future goal to allow package extension scripts themselves to depend on custom libraries, but that will require larger changes to how SwiftPM — and any IDEs that use libSwiftPM — create their build plans and run their builds.  In particular, it will require those build systems to be able to build any libraries needed by the extension script before invoking it, prior to the actual build of the Swift package.

A package extension target can be used by other targets in the same package without declaring a corresponding product in the manifest, but in order to let other packages use it, the `extension` target must be exported using an `extension` product type. If and when a future version of SwiftPM unifies the concepts of products and targets (which would be desirable), this distinction between package extension targets and package extension products will become unnecessary.

As with the `PackageDescription` API for package manifests, the `PackageExtension` API availability annotations will be tied to the Swift Tools Version of the package that contains the `extension` target.

## Detailed design

To allow extensions to be declared, the following API will be added to `PackageDescription`:

```swift
extension Target {

    /// Defines a new package extension target with a given name, declaring it as
    /// providing a capability of adding custom build commands to SwiftPM (and to
    /// any IDEs based on libSwiftPM).
    ///
    /// The capability determines what kind of build commands it can add. Besides
    /// determining at what point in the build those commands run, the capability
    /// determines the context that is available to the extension and the kinds of
    /// commands it can create.
    ///
    /// In the initial version of this proposal, three capabilities are provided:
    /// prebuild, build tool, and postbuild. See the declaration of each capability
    /// under `ExtensionCapability` for more information.
    ///
    /// The package extension itself is implemented using a Swift script that is
    /// invoked for each target that uses it. The script is invoked after the
    /// package graph has been resolved, but before the build system creates its
    /// dependency graph. It is also invoked after changes to the target or the
    /// build parameters.
    ///
    /// Note that the role of the package extension is only to define the commands
    /// that will run before, during, or after the build. It does not itself run
    /// those commands. The commands are defined in an IDE-neutral way, and are
    /// run as appropriate by the build system that builds the package. The exten-
    /// sion itself is only a procedural way of generating commands and their input
    /// and output dependencies.
    ///
    /// The package extension may specify the executable targets or binary targets
    /// that provide the build tools that will be used by the generated commands
    /// during the build. In the initial implementation, prebuild actions can only
    /// depend on binary targets. Build tool and postbuild extensions can depend
    /// on executables as well as binary targets. This is because of limitations
    /// in how SwiftPM constructs its build plan, and the goal is to remove this
    /// restriction in a future release.
    public static func `extension`(
        name: String,
        capability: ExtensionCapability,
        dependencies: [Dependency] = []
    ) -> Target
}

extension Product {

    /// Defines a product that vends a package extension target for use by clients
    /// of the package containing the definition. It is not necessary to define a
    /// product for a package extension that is only used within the same package
    /// as it is defined. All the targets listed must be extension targets in the
    /// same package as the product. They will be applied in the listed order for
    /// any clients that depend on the extension product.
    public static func `extension`(
        name: String,
        targets: [String]
    ) -> Product
}

final class ExtensionCapability {

    /// Extensions that define a `prebuild` capability define commands to run before
    /// building the target. Such commands are run before every build, and can be
    /// used for generating source code or for performing other actions where the
    /// names of the output files cannot be determined before the command runs.
    ///
    /// Because the commands emitted by `prebuild` extensions are invoked on every
    /// build, they can negatively impact build performance. Such commands should
    /// therefore do their own dependency analysis to avoid any unnecessary work.
    public static func prebuild() -> ExtensionCapability
    
    /// Extensions that define a `buildTool` capability define commands to run at
    /// various points during the build, as determined by their input and output
    /// dependencies.
    ///
    /// This is the preferred kind of extension when the names of the output files
    /// can be determined before running the command, because it allows the command
    /// to be incorporated into the build dependency graph, so that it only runs
    /// when necessary.
    /// 
    /// Unlike commands generated by `prebuild` and `postbuild` extensions, those
    /// generated by the `buildTool` extension need to declare correct input and
    /// output paths based on the files that the command uses and those it creates.
    public static func buildTool(        
        /// Currently the extension is invoked for every target that is specified as
        /// using it. Future SwiftPM versions could refine this so that extensions
        /// could, for example, provide input filename filters that further control
        /// when they are invoked.
    ) -> ExtensionCapability
    
    /// Extensions that define a `postbuild` capability define commands to run after
    /// building the target. Such commands are run after every build, and can be
    /// used for performing actions after all the artifacts have been built and the
    /// fate of the build is known.
    ///
    /// Because the commands emitted by `postbuild` extensions are invoked on every
    /// build, they can negatively impact build performance. Such commands should
    /// therefore do their own dependency analysis to avoid any unnecessary work.
    public static func postbuild() -> ExtensionCapability
    
    // The idea is to add additional capabilities in the future, each with its own
    // semantics. An extension can implement one or more of the capabilities, and
    // will be invoked within a context relevant for that capability. This should
    // be extensible to letting package extensions extend various parts of a build
    // graph, such as testing, documentation generation, archiving actions, etc.
}
```

To allow extensions to be used, the following API will be added to `PackageDescription`:

```swift
extension Target.Dependency {

    /// Creates an extension dependency that resolves to either an extension target
    /// or an extension product.
    ///
    /// - parameters:
    ///   - name: The name of the extension target or extension product.
    ///   - package: The name of the package dependency in which it is defined, or
    ///       nil if it is defined in the same package as the target using it. 
    public static func `extension`(
        name: String,
        package: String? = nil
    ) -> Target.Dependency
}
```

This is in addition to the existing `target`, `product`, and `byName` dependency types.

To use an extension target, the client target specifies an `extension` dependency on it by including it in its `dependencies` parameter.  The target types that can depend on extensions are currently `target`, `executableTarget`, and `testTarget`.

The extensions on which a target depends are applied in the order in which they are listed — this allows one extension to act on output files produced by another extension that provides the same capability.  This allows, for example, a target to determine whether a linter should operate on source files generated by a different extension.

Note that because the commands that are generated by extensions with a build tool capability define inputs and outputs for the command, the order in which the extensions are applied does not necessarily determine the order in which the commands will be run during the build.  Instead this will be determined by the dependencies that the extension defines.

The API of the new `PackageExtension` library lets the extension construct one or more build commands based on the build context for the client target. The context includes the target and module names, the set of source files for the target (including those generated by previously applied extensions),  information about the target's dependency closure, and other inputs from the package. The context also includes environmental conditions such as the build directory, intermediates directory, etc.

The initial proposed `PackageExtension` API is:

```swift
/// Like package manifests, package extensions are Swift scripts that use API
/// from a special library provided by SwiftPM. In the case of package exten-
/// sions, this is `PackageExtension`. Extensions run in a sandbox, and have
/// read-only access to the package directory.
///
/// The input to a package extension is passed by SwiftPM when it is invoked,
/// and can be accessed through the `targetBuildContext` global. The extension
/// generates commands to run during the build using the `commandConstructor`
/// global, and can emit diagnostics using the `diagnosticsEmitter` global.



/// Provides information about the target being built, as well as contextual
/// information such as the paths of the directories to which commands should
/// be configured to write their outputs. This information should be used when
/// generating the commands to be run during the build.
let targetBuildContext: TargetBuildContext

/// Constructs commands to run during the build, including full command lines.
/// All paths should be based on the ones passed to the extension in the target
/// build context.
let commandConstructor: BuildCommandConstructor

/// Emits errors, warnings, and remarks to be shown as a result of running the
/// extension.
let diagnosticsEmitter: DiagnosticsEmitter


/// Provides information about the target being built, as well as contextual
/// information such as the paths of the directories to which commands should
/// be configured to write their outputs. This information should be used as
/// part of generating the commands to be run during the build.
protocol TargetBuildContext {
    /// The name of the target being built.
    var targetName: String { get }
    
    /// The module name of the target. This is currently derived from the name,
    /// but could be customizable in the package manifest in a future SwiftPM
    /// version.
    var moduleName: String { get }
    
    /// The path of the target source directory.
    var targetDir: FilePath { get }
    
    /// That path of the package that contains the target.
    var packageDir: FilePath { get }
    
    /// Absolute paths of the files in the target being built, including the
    /// sources, resources, and other files. This also includes any source
    /// files generated by other extensions that are listed earlier than this
    /// extension in the dependency list of the target being built.
    var inputFiles: [FilePath] { get }
    
    /// Information about all targets in the dependency closure of the target
    /// to which the extension is being applied. This list is in topologically
    /// sorted order, with immediate dependencies appearing earlier and more
    /// distant dependencies later in the list. This is mainly intended for
    /// generating lists of search path arguments, etc.
    var dependencies: [DependencyTargetInfo] { get }
    
    /// Provides information about a target in the dependency closure of the
    /// target to which the extension is being applied.
    protocol DependencyTargetInfo {
        
        /// The name of the target.
        var targetName: String { get }
        
        /// The module name of the target. This is currently derived from the
        /// name, but could be customizable in the package manifest in a future
        /// SwiftPM version.
        var moduleName: String { get }
        
        /// The path of the target source directory.
        var targetDir: FilePath { get }
    }

    /// The path of an output directory into which files generated by the build
    /// commands that are created by the package extension can be written. The
    /// package extension itself may also write to this directory.
    var outputDir: FilePath { get }
        
    /// Looks up and returns the path of a named command line executable tool.
    /// The executable must be either in the toolchain or in the system search
    /// path for executables, or be provided by an executable target or binary
    /// target on which the package extension target depends. Throws an error
    /// if the tool cannot be found.
    func lookupTool(named name: String) throws -> FilePath
}

/// Constructs commands to run during the build, including full command lines.
/// All paths should be based on the ones passed to the extension in the target
/// build context.
protocol CommandConstructor {
    
    /// Creates a command to run during the build. The executable should be a
    /// path returned by `TargetBuildContext.lookupTool(named:)`, and all the
    /// paths in both the command line and the input and output lists should be
    /// based on the paths provided in the target build context structure.
    ///
    /// Note that input and output dependencies are ignored for prebuild and
    /// postbuild actions, since they always run before and after the build,
    /// respectively. The display name will be shown in the build log when
    /// the command is run.
    func addCommand(
        displayName: String,
        executable: FilePath,
        arguments: [String],
        workingDirectory: FilePath? = nil,
        environment: [String: String] = [:],
        inputPaths: [FilePath] = [],
        outputPaths: [FilePath] = []
    )

    /// Registers a generated source file that will be passed to later stages
    /// of the build. Note that this is separate from the output dependencies
    /// specified when adding a command, which identify the paths of files and
    /// directories created by the command but which are not treated as source
    /// files for further processing.
    func addGeneratedSourceFile(path: FilePath)
    
    /// Registers a directory into which a `prebuild` command will write output
    /// files that should be considered as generated source files of the target
    /// being built.
    ///
    /// It is an error to call this function from another kind of extension than
    /// a `prebuild` extension.
    func addPrebuildGeneratedSourceDirectory(path: FilePath)
}

/// Emits errors, warnings, and remarks to be shown as a result of running the
/// extension. If any errors are emitted, the extension will be considered to
/// have failed; otherwise it will be considered to have succeeded.
protocol DiagnosticsEmitter {
    func emit(error message: String, file: FilePath? = nil, line: Int? = nil)
    func emit(warning message: String, file: FilePath? = nil, line: Int? = nil)
    func emit(remark message: String, file: FilePath? = nil, line: Int? = nil)
}

/// In addition, the API of `FilePath` from SwiftSystem will be available.
```

During package graph resolution, packages and any binary artifacts are fetched as usual.  After resolving the package graph, SwiftPM invokes the package extensions that are used by the targets in the package graph.

Applying an extension to a client target is done in a similar way to how package manifests are evaluated. This is largely an implementation detail, but the semantics are as if the Swift script that implements the extension is either interpreted — or compiled to an executable and then run — in a sandbox. Input from SwiftPM is passed to the extension in serialized form and made available through the `TargetBuildContext` type.  Output from the extension, generated via `CommandConstructor` and `DiagnosticsEmitter` calls, is passed back to SwiftPM in a similar manner.

Each extension is invoked once for each target that uses it, with that target’s context as its input. The command definitions emitted by a package extension are used to set up build commands to run before, during, or after the build. Any diagnostics emitted by the extension are shown to the user, and any errors cause the build to fail.

The commands that run before and after the build (as indicated by specifying `prebuild` and `postbuild` , respectively, as the extension capability) run before and after the actual build occurs. Output files created by commands resulting from `prebuild` extensions can feed into the build plan creation, if they are emitted into directories designated by the extension as prebuild output directories. This allows them to generate output files whose names are not known until the command runs. These output files are expected to be created in temporary directories passed to the extension for that purpose — the extension will run in a sandbox that cannot modify the source files in the package.

Because commands emitted by `prebuild` and `postbuild` extensions are run on every build, they can negatively impact build performance. Such commands should do their own dependency analysis and use caching to avoid any unnecessary work. Caches can be written to the output directory given as input to the extension when it is invoked.

Command invocations emitted by package extensions that have the `buildTool` capability can additionally specify input and output dependencies. These commands are incorporated into the build graph, and are only run when their outputs are missing or their inputs have changed. This is preferable when the names of outputs and inputs can be predicted before running the command, since it lets the commands use the build system’s dependency analysis to only run the commands when needed.

It is important to emphasize the distinction between a package extension and the build commands it defines:

- The *extension* is invoked before the build, after the structure of the target that uses it is known but before any build commands are run. It may also be invoked again if there the target structure or other input conditions change. It is not invoked again when the *contents* of files change.

- The *commands* that are defined by an extension, on the other hand, are invoked before, during, or after each build, in accordance with their defined input and output dependencies.

Binary targets will be improved to allow them to contain executable commands and other needed files (such as the system `.proto` files in the case of `protoc`, etc). Binary targets will need to support different executable binaries based on platform and architecture. This is the topic of a separate evolution proposal to extend binary targets to support executables in addition to XCFrameworks.

### Extension capabilities

This proposal defines three different extension capabilities, which determine how the extension is used.

- `prebuild` — The prebuild capability indicates that the commands defined by the extension should run before the start of every build. This capability should only be used when the paths of the inputs and outputs of the command cannot be known until the command is actually run. When the outputs paths are known ahead of time, the `buildTool` capability should instead be used.
  Examples of extensions that need to use the `prebuild` capability include SwiftGen and other tools that need to see the whole input and whose output files are determined by the contents (not just the paths) of the input files. These extensions usually generate just one command and configures it with an output directory into which all generated sources will be written.
  Because they run on every build, prebuild extensions should use caching to do as little work as possible (ideally none) when there are no changes to their inputs.
- `buildTool` — The build tool capability indicates that the commands defined by the extension should be incorporated into the build system's dependency graph, so that they run as needed during the build based on their declared inputs and outputs. This requires that the paths of any outputs can be known before the command is run (usually by forming the names of the outputs from some combination of the output directory and the name of the input file).
  Examples of extensions that can use the `buildTool` capability include most compiler-like tools, such as Protobuf (with most source generator plug-ins, such as SwiftProtobuf) and other tools that take a fixed set of inputs and produce a fixed set of outputs.
  The `buildTool` capability is preferable when possible, since commands don't have to run unless their outputs are missing or their inputs have changed since the last time they ran.
- `postbuild` — The postbuild capability indicates that the commands defined by the extension should run after the end of every build. This can be used for postprocessing of artifacts or for documentation generation.
  Because they run on every build, postbuild extensions should use caching to do as little work as possible (ideally none) when there are no changes to their inputs.

## Example 1: SwiftGen

This example is a package that uses SwiftGen to generate source code for accessing resources. The package extension target can be defined in the same package as the one that provides the source generation tool (SwiftGen, in this case), so that client packages access it just by adding a package dependency on the SwiftGen package.

The `swiftgen` command may generate output files with any name, and they cannot be known without either running the command or separately parsing the configuration file. In this initial proposal for build extensions, this means that the SwiftGen extension must specify a `prebuild` capability in order for the source files it generates to be processed during the build.

### Client Package

This is the structure of an example client package of SwiftGen:

```
MyPackage
 ├ Package.swift
 ├ swiftgen.yml
 └ Sources
    └ MyLibrary
        ├ Assets.xcassets
        └ SourceFile.swift
```


SwiftGen supports using a config file named `swiftgen.yml` and this example implementation of the extension assumes a convention that it is located in the package directory.  A different implementation of the extension might assume a per-target convention, or a combination of the two.

The package manifest has a dependency on the SwiftGen package, which vends an extension product that the client package can use for any of its targets by adding target dependencies in the package manifest:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "MyPackage",
    dependencies: [
        .package(url: "https://github.com/SwiftGen/SwiftGen", from: "6.4.0")
    ]
    targets: [
        .executable(
            name: "MyLibrary",
            dependencies: [
                .extension(name: "SwiftGenExtension", package: "SwiftGen")
            ]
        )
    ]
)
```

By specifying that the `MyLibrary` target depends on the extension, `SwiftGenExtension` will be invoked for the target.

The order in which extensions are listed in `dependencies` determines the order in which they will be applied compared with other extensions in the list that provide the same capability. This can be used to control which extensions will see the outputs of which other extensions. In this case, only one extension is used.

### Extension Package

Using the facilities in this proposal, the SwiftGen package authors could implement a package extension that creates a command to run `swiftgen` before the build.

This is the SwiftGenExtension target referenced in the client package:

```
SwiftGen
 ├ Package.swift
 └ Sources
    ├ . . .
    └ SwiftGenExtension
       └ main.swift     
```

In this case, `main.swift` is the Swift script that implements the package extension target.

The package manifest would have an `extension` target in addition to the existing target that provides the `swiftgen` command line tool itself:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "SwiftGen",
    targets: [
        /// Package extension that tells `swiftpm` how to run `swiftgen` based on
        /// the configuration file. Client targets use this extension by adding a
        /// dependency on it. This example uses the `prebuild` action, to make
        /// `swiftgen` run before each build. A different example might use the
        /// `builtTool` action if the names of inputs and outputs could be known
        /// ahead of time.
        .extension(
            name: "SwiftGenExtension",
            capability: .prebuild(),
            dependencies: ["SwiftGen"]
        ),
        
        /// Binary target that provides the built SwiftGen executables.
        .binaryTarget(
            name: "SwiftGen",
            url: "https://url/to/the/built/swiftgen-executables.zip",
            checksum: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ),
    ]
)
```

The package extension script implementing the `prebuild` capability might look like this:

```swift
import PackageExtension

// This example configures `swiftgen` to write to a "SwiftGenOutputs" directory.
let generatedSourcesDir = targetBuildContext.outputDir.appending("SwiftGenOutputs")
commandConstructor.addPrebuildGeneratedSourceDirectory(generatedSourcesDir)

// Create a command to run `swiftgen` as a prebuild command. It will be run before
// every build and generates source files into an output directory provided by the
// build context.
commandConstructor.addCommand(
    displayName: "Running SwiftGen",
    executable:
        try targetBuildContext.lookupTool(named: "swiftgen"),
    arguments: [
        "config", "run",
        "--config", "\(targetBuildContext.packageDir.appending("swiftgen.yml"))"
    ],
    environment: [
        "PROJECT_DIR": "\(targetBuildContext.packageDir)",
        "TARGET_NAME": "\(targetBuildContext.targetName)",
        "DERIVED_SOURCES_DIR": "\(generatedSourcesDir)",
    ]
)
```

An alternate use of `swiftgen` could instead invoke it once for each input file, passing it output files whose names are derived from the names of the input files. This might, however, make per-file configuration somewhat more difficult.

There is a trade-off here between implementing a `prebuild` extension or a `buildTool` extension.  Future improvements to SwiftPM's build system (and to those of any IDEs providing support for Swift packages) could let it support commands whose outputs aren't known until the command is run.

Possibly, the `swiftgen` tool itself could also be modified to provide a simplified way to invoke it, to take advantage of SwiftPM's new ability to dynamically provide the names of the input files in the target.

## Example 2: SwiftProtobuf

This example is a package that uses SwiftProtobuf to generate source files from `.proto` files. In addition to the package extension product, the package provides the runtime library that the generated Swift code uses.

Since `protoc` isn’t built using SwiftPM, it also has a binary target with a reference to a `zip` archive containing the executable.

### Client Package

This is the structure of an example package that uses Protobuf:

```
MyPackage
 ├ Package.swift
 └ Sources
    └ MyExe
        ├ messages.proto
        └ main.swift
```

The `messages.proto` source file needs to be processed using the `protoc` compiler to generate Swift source files that are then compiled. In addition, the `protoc` compiler needs to be passed the path of a source generator plug-in built by the SwiftProtobuf package.

The package manifest has a dependency on the SwiftProtobuf package, and references the hypothetical new `SwiftProtobufExtension` extension defined in it:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "MyPackage",
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.15.0")
    ]
    targets: [
        .executable(
            name: "MyExe",
            dependencies: [
                .extension(name: "SwiftProtobuf", package: "swift-protobuf")
                .product(name: "SwiftProtobufRuntimeLib", package: "swift-protobuf")
            ]
        )
    ]
)
```

As with the previous example, declaring a dependency on `SwiftProtobuf` applies that extension to the `MyExe` target.

In this initial version of the proposal, the client target must also list dependencies on any runtime libraries that will be needed, as this example shows with the hypothetical `SwiftProtobufRuntimeLib` library. A future improvement could extend the `PackageExtension` API to let the extension define additional dependencies that targets using the extension would automatically get.

This version of the initial proposal does not define a way to pass options to the extension through the manifest. Since the extension has read-only access to the package directory, it can define its own conventions for a configuration file in the package or target directory.  A future improvement to the proposal should allow a way for the extension to provide custom types that the client package manifest could use to set options to the extension.

### Extension Package

The structure of the hypothetical `SwiftProtobuf` target that provides the extension is:

```
SwiftProtobuf
 ├ Package.swift
 └ Sources
    └ SwiftProtobuf
       └ main.swift     
```

The package manifest is:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "SwiftProtobuf",
    targets: [
        /// Package extension that tells SwiftPM how to deal with `.proto` files.
        /// The client target specifies the name of this target in its `extension`
        /// dependency.
        .extension(
            name: "SwiftProtobuf",
            capability: .buildTool()
            dependencies: ["protoc", "protoc-gen-swift"]
        ),
                
        /// Binary target that provides the prebuilt `protoc` executable.
        .binaryTarget(
            name: "protoc"
            url: "https://url/to/the/built/protoc-executables.zip",
            checksum: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        ),
        
        /// Swift target that builds the plug-in executable that will be passed to
        /// the `protoc` compiler.
        .executableTarget(
            name: "protoc-gen-swift"
        ),

        /// Runtime library that clients will need to link against by specifying
        /// it as a dependency.
        .libraryTarget(
            name: "SwiftProtobufRuntimeLib"
        ),
    ]
)
```

The `protoc-gen-swift` target is a regular executable target that implements a source generation plug-in to the Protobuf compiler. This is particular to the Protobuf compiler, which in addition to the `protoc` executable uses separate source code generator plug-in tools specific to the emitted languages. The implementation of the hypothetical `SwiftProtobuf` extension generates the commands to invoke `protoc` passing it the `protoc-gen-swift` plug-in.

The package extension script might look like:

```swift
import PackageExtension

// In this case we generate an invocation of `protoc` for each input file, passing
// it the path of the `protoc-gen-swift` generator plug-in.
let protocPath = try targetBuildContext.lookupTool(named: "protoc")
let protocGenSwiftPath = try targetBuildContext.lookupTool(named: "protoc-gen-swift")

/// Construct the search paths for the .proto files, which can include any of the
/// targets in the dependency closure.  Here we assume that the public ones are in
/// a "protos" directory, but this can be made arbitrarily complex.
var protoSearchPaths = targetBuildContext.dependencies.map { target in
    target.targetDir.appending("protos")
}

// Add the search path to the system proto files. This sample implementation assumes
// that they are located relative to the `protoc` compiler provided by the binary
// target, but real implementation could be more sophisticated.
protoSearchPaths.append(protocPath.removingLastComponent().appending("system-protos"))

// Create a module mappings file. This is something that the Swift source generator
// `protoc` plug-in we are using requires. The details are not important for this
// proposal, except that it needs to be able to be constructed from the information
// in the target build context, and written out to the intermediates directory.
let moduleMappingsFilePath = targetBuildContext.outputDir.appending("module-mappings")
. . .
// (code to generate and write the module mappings file)
. . .

// Iterate over the .proto input files.
for inputPath in targetBuildContext.inputPaths.filter { $0.extension == "proto" } {
    // Construct the `protoc` arguments.
    var arguments = [
        "--plugin=protoc-gen-swift=\(protoGenSwiftPath)",
        "--swift_out=\(targetBuildContext.outputDir)",
        "--swift_opt=ProtoPathModuleMappings=\(moduleMappingFilePath)"
    ]
    arguments.append(contentsOf: protoSearchPaths.flatMap { ["-I", $0] })
    arguments.append(inputPath)
    
    // The name of the output file is based on the name of the input file, in a way
    // that's determined by the protoc source generator plug-in we're using.
    let outputName = inputPath.lastComponent.stem + ".swift"
    let outputPath = targetBuildContext.outputDir.appending(outputName)
    
    // Construct the command. Specifying the input and output paths lets the build
    // system know when to invoke the command.
    commandConstructor.addCommand(
        displayName: "Generating \(outputName) from \(inputPath.lastComponent)",
        executable: protocPath,
        arguments: arguments,
        inputs: [inputPath],
        outputs: [outputPath])
    
    // Register the generated source file so it will be compiled.            
    delegate.addGeneratedSourceFile(outputPath)
}
```

In this case, the script iterates over the input files that have a `.proto` suffix, creating a command to invoke the compiler for each one.

## Example 3: Source Analyzer

A third important use case is source generators that analyze Swift files and generate some additional sources based on the Swift definitions found in them. Tool authors may use a package such as [Sourcery](https://github.com/krzysztofzablocki/Sourcery), or parse the sources using [SwiftSyntax](https://github.com/apple/swift-syntax) to generate some boilerplate code, in order to avoid having to maintain it manually.

One could imagine a source generation tool called `GenSwifty` generating some additional “sugar” for existing definitions in a swift target. It would be configured like this by end users:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "MyPackage",
    dependencies: [
        .package(url: "https://github.com/example/gen-swifty", from: "1.0.0")
    ]
    targets: [
        .executable(
            name: "MyExe",
            dependencies: [
                .extension(name: "GenSwifty", package: "gen-swifty")
            ]
        )
    ]
)
```

The package manifest of the `gen-swifty` package would be as follows:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "gen-swifty",
    targets: [
        .extension(
            name: "GenSwifty",
            capability: .buildTool()
            dependencies: ["GenSwiftyTool"]
        ),
        .executable(
            name: "GenSwiftyTool",
            ...  // this is the target that builds the tool
                 // The tool can depend on swift-syntax or other tools
        ),
    ]
)
```

The implementation of the package extension would be similar to the previous examples, but with a somewhat differently formed command line.

## Example 4: Custom Source Generator

This example uses a custom source generator implemented in the same package as the target that uses it.

```
MyPackage
 ├ Package.swift
 └ Sources
    ├ MyExe
    │   │ file.dat
    │   └ main.swift
    ├ MySourceGenExt
    │   └ extension.swift
    └ MySourceGenTool
        └ main.swift
```

The manifest is:

```swift
// swift-tools-version: 999.0
import PackageDescription

let package = Package(
    name: "MyPackage",
    targets: [
        .executable(
            name: "MyExe",
            dependencies: [
                .extension(name: "MySourceGenExt")
            ]
        ),
        .extension(
            name: "MySourceGenExt",
            capability: .buildTool(),
            dependencies: ["MySourceGenTool"]
        ),
        .executableTarget(
            name: "MySourceGenTool"
        ),
    ]
)
```

In this case the `.extension()` in the `dependencies` parameter refers to an extension defined in the same package, so it does not have a `package` parameter and no product needs to be defined.

The implementation of the package extension would be similar to the previous examples, but with a somewhat differently formed command line to transform the `.dat` file into something else.

## Impact on existing packages

The new API and functionality will only be available to packages that specify a tools version equal to or later than the SwiftPM version in which this functionality is implemented, so there will be no impact on existing packages.

## Security

Package extensions will be run in a sandbox that prevents network access and writing to the file system except to intermediate directories (similar to package manifests). In addition, SwiftPM and IDEs that use libSwiftPM should run each command generated by an extension in a sandbox.

There is inherent risk in running build tools provided by other packages. This can possibly be mitigated by requiring the root package to list the approved package extensions. This requires further consideration.

## Future Directions

This proposal is intentionally fairly basic and leaves many improvements for the future. Among them are:

- the ability for package extensions to define new types that can be used to configure those extensions in package manifests
- the ability for a build tool to have depend on different packages than the clients of the extension that uses it
- the ability for extensions to have access to the full build graph at a detailed level
- the ability for prebuild actions to depend on tools built by SwiftPM
- the ability for package extension scripts to use libraries provided by other targets
- the ability for build commands to emit output files that feed back into the rule system to generate new work during the build (this requires support in SwiftPM's native build system as well as in the build systems of some IDEs that use libSwiftPM)
- the ability to provide per-target type-safe options to a use of an extension (details below)


### Type-safe Options

We are aware that many plugins will want to allow specific per-target configuration which would be best done in the package manifest of the project using the extension.

We are purposefully leaving options out of this initial proposal, and plan to revisit and add these in a future proposal.

In theory options, could just be done as a dictionary of string key/values, like this:

```swift
// NOT proposed
.extension(name: "Foo", options: ["Visibility": "Public"]) // not nice, not type-safe!
```

However, we believe that this results in a suboptimal user experience. It is hard to know what the available keys are, and what values are accepted. Is only `"Public"` correct in this example, or would `"public"` work too?

We would therefore prefer to exclude extension options from this proposal and explore a type-safe take on options in a future proposal.

We would especially like to let plugins define some form of `struct MyOptions: ExtensionOptions` type, where `ExtensionOptions` is also `Codable`, and SwiftPM would take care of serializing these options and providing them to the extension.

This would allow something like this:

```swift
.extension(name: "Foo", options: FooOptions(visibility: .public)) // yay, type-safe!
```

Such a design is difficult to implement well, because it would require the extension to add a type that is accessible to the package package manifest. It would also mean that the package manifest couldn't be parsed at all until the extension module providing the types has been compiled.

Designing such type safe options is out of scope for this initial proposal, as it involves many complexities with respect to how the types would be made available from the extension definition to the package manifest that needs them.

It is an area we are interested in exploring and improving in the near future, so rather than lock ourselves into supporting untyped dictionaries of strings, we suggest to introduce target specific, type safe extension options in a future Swift evolution proposal.

### Separate Dependency Graphs for Build Tools

This proposal uses the existing facilities that SwiftPM provides for declaring dependencies on packages that provide extensions and tools. This keeps the scope of the proposal bounded enough to allow it to be implemented in the near term, but it does mean that there cannot be any conflicts between the set of package dependencies that the build tool needs compared with those that the client package needs.

For example, a situation in which a build tool needs [Yams](https://github.com/jpsim/Yams) v3.x while a package client needs v4.x would not be supported by this proposal, even though it would pose no real problem at runtime. It would be very desirable to support this, but that would require significant work on SwiftPM to allow it to keep multiple independent package graphs.  It should be noted that if a package vends both a build tool and a runtime library that clients using the build tool must link against, then even this apparently simple case would get more complicated.  In this case the runtime library would have to use Yams v4.x in order to be usable by the client package, even if the tool itself used Yams v3.x.

It should also be noted that this is no different from a package that defines an executable and a library and would like to use a particular version of Yams without requiring the client of the library to use a compatible version. This is not support in SwiftPM today either, and it is in fact another manifestation of the same problem.

Solving this mixture of build-time and run-time package dependencies is possible but not without significant work in SwiftPM (and IDEs that use libSwiftPM).  We think that this proposal could be extended to support declaring such dependencies in the future, and that even with this restriction, this proposal provides useful functionality for packages.

## Alternatives Considered

A simpler approach would be to allow a package to contain shell scripts that are unconditionally invoked during the build. In order to support even moderately complex uses, however, there would still need to be some way for the script to get information about the target being built and its dependencies, and to know where to write output files.

This information would need to be passed to the script through some means, such as command line flags or environment variables, or through file system conventions. This seems a more subtle and less clear approach than providing a Swift API to access this information. If shell scripts are needed for some use cases, it would be fairly straightforward for a package author to write a custom extension to invoke that shell script and pass it inputs from the build context using either command line arguments or environment variables, as it sees fit.

Even with an approach based on shell scripts, there would still need to be some way of defining the names of the output files ahead of time in order for SwiftPM to hook them into its build graph (needing to know the names of outputs ahead of time is a limitation of the native build system that SwiftPM currently uses, as well as of some of the IDEs that are based on libSwiftPM — these build systems currently have no way to apply build rules to the output of commands that are run in the same build).

Defining these inputs and outputs using an API seems clearer than some approach based on naming conventions or requiring output files to be listed in the client package’s manifest.

Another approach would be to delay providing extensible build tools until the build systems of SwiftPM and of IDEs using it can be reworked to support arbitrary discovery of new work. This would, however, delay these improvements for the various kinds of build tools that *can* take advantage of the support proposed here.

We believe that the approach taken here — defining a common approach for specifying extensions that declare the capabilities they provide, and with a goal of defining more advanced capabilities over time — will provide some benefit now while still allowing more sophisticated behavior in the future.

## References

- https://github.com/aciidb0mb3r/swift-evolution/blob/extensible-tool/proposals/NNNN-package-manager-extensible-tools.md
- https://forums.swift.org/t/package-manager-extensible-build-tools/10900
