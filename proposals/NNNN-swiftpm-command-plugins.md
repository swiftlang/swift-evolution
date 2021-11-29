# Package Manager Command Plugins

* Proposal: [SE-NNNN](NNNN-swiftpm-command-plugins.md)
* Author: [Anders Bertelrud](https://github.com/abertelrud)
* Review Manager: TBD
* Status: **Pitch**

## Introduction

SE-0303 introduced the ability to define *build tool plugins* in SwiftPM, allowing custom tools to be automatically invoked during a build. This proposal extends that plugin support to allow the definition of custom *command plugins* — plugins that users can invoke directly from the SwiftPM CLI, or from an IDE that supports Swift Packages, in order to perform custom actions on their packages.

## Motivation

The *build tool plugins* that were introduced in SE-0303 are focused on code generation during the build of a package, for such purposes as generating Swift source files from `.proto` files or from other inputs. In order to allow build tools to be incorporated into the build graph and to run automatically in a safe manner, there are restrictions on what such plugins can do. For example, build tool plugins are prevented from modifying any files inside a package directory.

It would be useful to support a different kind of plugin that users can invoke directly, and that can be allowed to have more flexibility than a build tool that's invoked automatically during the build. Such custom command plugins could be used for documentation generation, source code reformatting, unit test report generation, build artifact post-processing, and other uses that don't fit the definition of a typical build tool. Rather than extending the build system, such plugins could extend and improve the workflow for package authors and users, whether or not those workflows have anything to do with the build system.

One key tension in this proposal is between providing rich functionality for plugins to use while still presenting that functionality in a way that's general enough to be implemented in both the SwiftPM CLI and in any IDE that supports packages. To that end, this proposal provides a minimal initial API, with the intention of adding more functionality in future proposals.

Separately to this proposal, it would also be useful to define custom actions that could run as a side effect of operations such as building and testing, and to be called in response to various events that can happen during a build or test run — but that is not what this proposal is about, and it would be the subject of a future proposal. Rather, this proposal focuses on the direct invocation of a custom command by a user, independently of whether the plugin that implements the command then decides to ask SwiftPM to perform a build as part of its implementation.

## Proposed Solution

This proposal defines a new plugin capability called `command` that allows packages to provide plugins for users to invoke directly. A command plugin specifies the semantic intent of the command — this might be a predefined intent such “documentation generation” or “source code formatting”, or it might be a custom intent with a specialized verb that allows the command to be invoked from the `swift` `package` CLI or from an IDE.  A command plugin can also specify any special permissions it needs (such as the permission to modify the package directory).

The command's intent declaration provides a way of grouping command plugins by their functional categories, so that SwiftPM — or an IDE that supports SwiftPM packages — can show the commands that are available for a particular purpose. For example, this supports having different command plugins for generating documentation for a package, while still allowing those different commands be grouped and discovered based on their intent.

As with build tool plugins, a package specifies the set of command plugins that are available to it by declaring dependencies on the packages that provide those plugins. Unlike build tool plugins, which are applied on a target-by-target basis through a declaration in the manifest of the package using the build tool, custom command plugins are not invoked automatically, but can instead be invoked directly by the user after the package graph has been resolved. This proposal adds options to the `swift` `package` CLI that allow users to invoke a plugin-provided command and to control the set of targets to which the command should apply.

Command plugins are implemented similarly to build tool plugins: each plugin is a Swift script that has access to API in the `PackagePlugin` module and that is invoked with parameters describing its inputs. The Swift script contains the logic to carry out the functionality of the plugin, usually by invoking other commands, but potentially also by asking the package manager to perform certain actions such as performing a build or a test run.

Unlike build tool plugins, which operate indirectly by defining build commands for SwiftPM to run at a later point in time (and only when needed), custom command plugins directly carry out the functionality of the plugin at the time they are invoked. This usually involves invoking tools that are in the toolchain or that are provided by dependencies, but it could also involve logic that is implemented completely inside the plugin itself (using Foundation APIs, for example). The plugin does not return until the command is complete.

Command plugins are provided with a read-only snapshot of the package, but they can also call into SwiftPM's build system to have it produce or update certain artifacts if it needs to. For example, a command that post-processes a release build can ask SwiftPM to build the release artifacts.

In this initial proposal there is a fairly modest set of build parameters that can be controlled by the plugin. The intent is to extend this over time, although it will only be possible to support functionality that is common enough to be available in the build systems of any IDE that supports SwiftPM command plugins (the "host" of the plugin).

As with all kinds of plugins, command plugins can emit diagnostics if it encounters any problems. Console output emitted by the command plugin is shown to users.

## Detailed Design

This proposal extends both the package manifest API and the package plugin API.

### Manifest API

This proposal defines a new `command` plugin capability in `PackageDescription`:

```swift
extension PluginCapability {
    /// Plugins that specify a `command` capability define commands that can be run
    /// using the SwiftPM CLI (`swift package <verb>`), or in an IDE that supports
    /// Swift Packages.
    public static func command(
        /// The semantic intent of the plugin (either one of the predefined intents,
        /// or a custom intent).
        intent: PluginCommandIntent,
        
        /// Any permissions needed by the command plugin. This affects what the
        /// sandbox in which the plugin is run allows. Some permissions may require
        /// approval by the user.
        permissions: [PluginPermission] = []
    ) -> PluginCapability
}
```

The plugin specifies the intent of the command as either one of a set of predefined intents or as a custom intent with an custom verb and help description.

In this proposal, the intent is expressed as an enum provided by SwiftPM in `PackageDescription`:

```swift
enum PluginCommandIntent {
    /// The intent of the command is to generate documentation, either by parsing the
    /// package contents directly or by using the build system support for generating
    /// symbol graphs. Invoked by a `generate-documentation` verb to `swift package`.
    case documentationGeneration
    
    /// The intent of the command is to modify the source code in the package based
    /// on a set of rules. Invoked by a `format-source-code` verb to `swift package`.
    case sourceCodeFormatting
        
    /// An intent that doesn't fit into any of the other categories, with a custom
    /// verb through which it can be invoked.
    case custom(verb: String, description: String)
}
```

Future versions of SwiftPM will almost certainly add to this set of possible intents, using availability annotations gated on the tools version.

If multiple command plugins in the dependency graph of a package specify the same intent, or specify a custom intent with the same verb, then the user will need to specify which plugin to invoke by qualifying the verb with the name of the plugin target followed by a `:` character, e.g. `MyPlugin:do-something`.  Because plugin names are target names, they are already known to be unique within the package graph, so the combination of plugin name and verb is known to be unique.

A command plugin can also specify the permissions it needs, which affect the ways in which the plugin can access external resources such as the file system or network. By default, command plugins have only read-only access to the file system (except for temporary-files locations) and cannot access the network.

A command plugin that wants to modify the package source code (as for example a source code formatter might want to) needs to request the `writeToPackageDirectory` permission. This modifies the sandbox in which the plugin is invoked to let it write inside the package directory in the file system, after notifying the user about what is going to happen and getting approval in a way that is appropriate for the IDE in question.

The permissions needed by the command are expressed as an enum in `PackageDescription`:

```swift
enum PluginPermission {
    /// The command plugin wants permission to modify the files under the package
    /// directory. The `reason` string is shown to the user at the time of request
    /// for approval, explaining why the plugin is requesting this access.
    case writeToPackageDirectory(reason: String)
    
    /// It is likely that future proposals will want to provide some kind of network
    /// access. In the interest of keeping this proposal bounded, we just note that
    /// as a possible future need here but do not initially allow any network access.
    
    /// Any future enum cases should use @available()
}
```

### Plugin API

This proposal extends the PackagePlugin API to:

* define a new kind of plugin entry point specific to command plugins
* allow the plugin to ask the Swift Package Manager to perform actions such as building or testing
* allow the plugin to ask the Swift Package Manager for specialized information such as Swift symbol graphs


#### Plugin Entry Point

This proposal extends `PluginAPI` with an entry point for command plugins:

```swift
/// Defines functionality for all plugins that have a `command` capability.
public protocol CommandPlugin: Plugin {
    /// Invoked by SwiftPM to perform the custom actions of the command.
    func performCommand(
        /// The context in which the plugin is invoked. This is the same for all
        /// kinds of plugins, and provides access to the package graph, to cache
        /// directories, etc.
        context: PluginContext,
        
        /// The targets to which the command should be applied. If the invoker of
        /// the command has not specified particular targets, this will be a list
        /// of all the targets in the package to which the command is applied.
        targets: [Target],
        
        /// Any literal arguments passed after the verb in the command invocation.
        arguments: [String],
    ) async throws
    
    /// A proxy to the Swift Package Manager or IDE hosting the package plugin,
    /// through which the plugin can ask for specialized information or actions.
    var packageManager: PackageManager { get }
}
```

This defines a basic entry point for a command plugin, passing it information about the context in which the plugin is invoked (including information about the package graph), the set of targets on which the command should operate, and the arguments passed by the user after the verb in the `package` `package` invocation.

The `context` parameter provides access to the package to which the user applies the plugin, including any dependencies, and it also provides access to a working directory that the plugin can use for any purposes, as well as a way to look up command line tools with a given name. This is the same as the support that is available to all plugins via SE-0325.

An opaque reference to a proxy for the Package Manager services in SwiftPM or the host IDE is also made available to the plugin, for use in accessing derived information and for carrying out more specialized actions. This is described in more detail below.

Many command plugins will invoke other tools to do the actual work. A plugin can use Foundation’s `Process` API to invoke executables, using the `PluginContext.tool(named:)` API to obtain the full path of the command line tool in the local file system (even if it originally came from a binary target or is provided by the Swift toolchain, etc).

Plugins can also use Foundation APIs for reading and writing files, encoding and decoding JSON, and other actions.

#### Accessing Package Manager Services

In addition to invoking arbitrary command line tools and using Foundation APIs, plugins can use the `packageManager` property to obtain more specialized information and to invoke certain SwiftPM services. This is a proxy to SwiftPM or to the IDE that is hosting the plugin, providing access to some of its functionality. The set of services provided in this API is expected to grow over time.

```swift
/// Provides specialized information and services from the Swift Package Manager or
/// an IDE that supports Swift Packages. Different plugin hosts will implement this
/// functionality in whatever way is appropriate for them, but should preserve the
/// same semantics described here.
public struct PackageManager {
    //
    //  Building
    //
    
    /// Performs a build of all or a subset of products and targets in a package.
    /// Any errors encountered during the build are reported in the build result.
    /// The SwiftPM CLI or any IDE supporting packages may show the progress of
    /// the build as it happens.
    public func build(
        _ subset: BuildSubset,
        parameters: BuildParameters
    ) async throws -> BuildResult
    
    /// Specifies what subset of products and targets of a package to build.
    public enum BuildSubset {
        /// Represents the subset consisting of all products and either all targets
        /// or, if `includingTests` is false, just the non-test targets.
        case all(includingTests: Bool)

        /// Represents a specific product.
        case product(String)

        /// Represents a specific target.
        case target(String)
    }
    
    /// Parameters and options to apply during the build.
    public struct BuildParameters {
        /// Whether to build for debug or release.
        public var configuration: BuildConfiguration
        
        /// Controls the amount of detail in the log. 
        public var logging: BuildLogVerbosity
        
        // More parameters would almost certainly be added in future proposals.
    }
    
    /// Represents an overall purpose of the build, which affects such things as
    /// optimization and generation of debug symbols.
    public enum BuildConfiguration {
        case debug
        case release
    }
    
    /// Represents the amount of detail in a log.
    public enum BuildLogVerbosity {
        case concise
        case verbose
        case debug
    }
    
    /// Represents the results of running a build.
    public struct BuildResult {
        /// Whether the build succeeded or failed.
        public var succeeded: Bool
        
        /// Log output (the verbatim text in the initial proposal).
        public var logText: String
        
        /// The artifacts built from the products in the package. Intermediates
        /// such as object files produced from individual targets are not listed.
        public var builtArtifacts: [BuiltArtifact]
        
        /// Represents a single artifact produced during a build.
        public struct BuiltArtifact {
            /// Full path of the built artifact in the local file system.
            public var path: Path
            
            /// The kind of artifact that was built.
            public var kind: Kind
            
            /// Represents the kind of artifact that was built. The specific file
            /// formats may vary from platform to platform — for example, on macOS
            /// a dynamic library may in fact be built as a framework.
            public enum Kind {
                case executable
                case dynamicLibrary
                case staticLibrary
            }
        }
    }
    
    //
    //  Testing
    //
    
    /// Runs all or a specified subset of the unit tests of the package, after
    /// doing an incremental build if necessary.
    public func test(
        _ subset: TestSubset,
        parameters: TestParameters
    ) async throws -> TestResult
        
    /// Specifies what tests in a package to run.
    public enum TestSubset {
        /// Represents all tests in the package.
        case all

        /// Represents one or more tests filtered by regular expression, with the
        /// format <test-target>.<test-case> or <test-target>.<test-case>/<test>.
        /// This is the same as the `--filter` option of `swift test`.
        case filtered([String])
    }
    
    /// Parameters that control how the test is run.
    public struct TestParameters {
        /// Whether to enable code coverage collection while running the tests.
        public var enableCodeCoverage: Bool
        
        /// There are likely other parameters we would want to add here.
    }
    
    /// Represents the result of running tests.
    public struct TestResult {
        /// Path of the code coverage JSON file, if code coverage was requested.
        public var codeCoveragePath: Path?
        
        /// Results for all the test targets that were run (filtered based on
        /// the input subset passed when running the test).
        public var testTargets: [UnitTestTarget]
        
        /// Represents the results of running some or all of the tests in a
        /// single test target.
        public struct TestTarget {
            public var name: String
            public var testCases: [TestCase]
            
            /// Represents the results of running some or all of the tests in
            /// a single test case.
            public struct TestCase {
                public var name: String
                public var tests: [Test]

                /// Represents the results of running a single test.
                public struct Test {
                    public var name: String
                    public var outcome: Outcome
                    public var duration: Double
                    
                    /// Represents the outcome of running a single test.
                    public enum Outcome {
                        case succeeded, skipped, failed
                    }
                }
            }
        }
    }
    
    //
    //  Accessing Specialized Information
    //
        
    /// Return a directory containing symbol graph files for the given target
    /// and options. If the symbol graphs need to be created or updated first,
    /// they will be. SwiftPM or an IDE may generate these symbol graph files
    /// in any way it sees fit.
    public func getSymbolGraph(
        for target: Target,
        options: SymbolGraphOptions
    ) async throws -> SymbolGraphResult

    /// Represents options for symbol graph generation. These options are taken
    /// into account when determining whether generated information is already
    /// up-to-date.
    public struct SymbolGraphOptions {
        /// The symbol graph will include symbols at this access level and higher.
        public var minimumAccessLevel: AccessLevel = .public
      
        /// Represents a Swift access level.
        public enum AccessLevel {
            case `private`, `fileprivate`, `internal`, `public`, `open`
        }
        
        /// Whether to include synthesized members.
        public var includeSynthesized: Bool = false
        
        /// Whether to include symbols marked as SPI.
        public var includeSPI: Bool = false
    }

    /// Represents the result of symbol graph generation.
    public struct SymbolGraphResult {
        /// The directory that contains the symbol graph files for the target.
        public var directoryPath: Path
    }
}
```

### Permissions

Like other plugins, command plugins are run in a sandbox on platforms that support it. By default this sandbox does not allow the plugin to modify the file system (except in special temporary-files paths) and blocks any network access.

Some commands, such as source code formatters, might need to modify the file system in order to be useful. Such plugins can specify the permissions they need, and this will cause:

* the user to be notified about the need for the additional permission and provided with some way to approve it
* the sandbox to be modified in an appropriate manner (if the user approves)

The exact form of the notification and approval will depend on the CLI or IDE that runs the plugin. SwiftPM’s CLI is expected to ask the user for permission if connected to a TTY, while an IDE might present user interface allowing the choice. In order to avoid having to request permission every time, some kind of caching of the response could be implemented as an implementation detail.

### Invoking Command Plugins

In the SwiftPM CLI, command plugins provided by the package or its dependencies are available as verbs that can be specified in a `swift` `package` invocation. For example, if the root package defines a command plugin with a `do-something` verb — or if it has a dependency on a package that defines such a plugin — a user can run it using the invocation:

```shell
❯ swift package do-something
```

This will invoke the plugin and only return when it completes. Since no other options were provided, this will pass all the targets in the package to the plugin.

To pass a subset of the targets to the plugin, one or more `--target` options can be used in the invocation:

```shell
❯ swift package --target Foo --target Bar do-something
```

This will pass the `Foo` and `Bar` targets to the plugin (assuming those are names of regular targets defined in the package).

The user can also provide additional parameters that are passed directly to the plugin. In the following example, the plugin will receive the parameters `aParam` and `-aFlag`, in addition to the targets named `Foo` and `Bar`.

```shell
❯ swift package --target Foo --target Bar do-something aParam -aFlag
```

Arguments are currently passed to the plugin exactly as they are written after the command’s verb. A future proposal could allow the plugin to define parameters (using SwiftArgumentParser) that SwiftPM could interpret and that would integrate better with SwiftPM’s own command line arguments.

As mentioned in the *Permissions* section, command plugins are by default blocked from modifying the files inside the package directory on platforms that support sandboxing. If a command plugin that requires file system writability is invoked, `swift` `package` will ask for approval — this is done using console input if stdin is connected to a TTY, or if not, an error will be reported without invoking the plugin. An `--allow-writing-to-package-directory` option can be used to bypass the request to approve the file system access, which is useful in CI and other automation.

```shell
❯ swift package --allow-writing-to-package-directory do-something
```

Asking for permission from the user helps to prevent unexpected modification of the package by command plugins.

In IDEs that support Swift packages, command plugins could be provided through context menus or other user interface affordances that allow the commands to be invoked on a package or possibly on a selection of targets in a package. A plugin itself does not need to know how or in what context it is being invoked.

If a future proposal introduces a way of declaring parameters in a manner similar to SwiftArgumentParser, then an IDE could possibly also show a more targeted user interface for those parameters, since the types and optionality will be known.

## Example 1:  Generating Documentation

Here's a brief example of a hypothetical command plugin that uses `docc` to generate documentation for one or more targets in a package. This example calls back to the plugin host (SwiftPM or an IDE) to generate symbol graphs.

The package manifest contains the `.plugin()` declaration:

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "MyDocCPlugin",
    products: [
        // Declaring the plugin product vends the plugin to clients of the package.
        .plugin(
            name: "MyDocCPlugin",
            targets: ["MyDocCPlugin"]
        ),
    ],
    targets: [
        // This is the actual target that implements the command plugin.
        .plugin(
            name: "MyDocCPlugin",
            capability: .command(
                intent: .documentationGeneration
            )
        )
    ]
)
```

The implementation of the package plugin itself:

```swift
import PackagePlugin

@main
struct MyDocCPlugin: CommandPlugin {
    func performCommand(
        context: PluginContext,
        targets: [Target],
        arguments: [String]
    ) async throws {
        // We'll be creating commands that invoke `docc`, so start by locating it.
        let doccTool = try context.tool(named: "docc")
        
        // Construct the path of the directory in which to emit documentation.
        let outputDir = context.pluginWorkDirectory.appending("Outputs")
        
        // Iterate over the targets we were given.
        for target in targets {
            // Only consider kinds of targets that can have source files.
            guard let target = target as? SourceModuleTarget else { continue }
            
            // Find the first DocC catalog in the target, if there is one (a more
            // robust example would handle the presence of multiple catalogs).
            let doccCatalog = target.sourceFiles.first { $0.path.extension == "docc" }
                        
            // Ask SwiftPM to generate or update symbol graph files for the target.
            let symbolGraphInfo = try packageManager.getSymbolGraph(for: target,
                options: .init(
                    minimumAccessLevel: .public,
                    includeSynthesized: false,
                    includeSPI: false))
            
            // Invoke `docc` with arguments and the optional catalog.
            var doccArgs = ["convert"]
            if let doccCatalog = doccCatalog {
                doccArgs += ["\(doccCatalog.path)"]
            }
            doccArgs += [
                "--fallback-display-name", target.name,
                "--fallback-bundle-identifier", target.name,
                "--fallback-bundle-version", "0",
                "--additional-symbol-graph-dir", "\(symbolGraphInfo.directoryPath)",
                "--output-dir", "\(outputDir)",
            ]
            let (exitcode, stdout, stderr) = try doccTool.run(arguments: doccArgs)

            // We should also report non-zero exit codes here.
            
            print("Generated documentation at \(outputDir).")
        }
    }
}
```

In order to use this plugin from another package, a dependency would be used on the package that declares the plugin:

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "MyLibrary",
    dependencies: [
        .package(url: "https://url/of/docc/plugin/package", from: "1.0.0"),
    ],
    targets: [
        .target(name: "MyLibrary")
    ]
)
```

Note, that, unlike with built tool plugins, there is no `plugins` clause for command plugins — this is because they are applied explicitly by user action and not implicitly when building targets.

Users can then invoke this custom command using the `swift` `package` invocation:

```shell
❯ swift package generate-documentation
```

Since no `--target` options are provided, SwiftPM passes all the package’s targets to the plugin (in this simple example, just `MyLibraryTarget`).

The plugin should emit the path at which it generated the documentation.

## Example 2: Formatting Source Code

This example uses `swift-format` to reformat the code in a package, which requires the plugin to have `.writeToPackageDirectory` permission.

Note that this package depends on the executable provided by the *swift-format* package.

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "MyFormatterPlugin",
    dependencies: [
        .package(url: "https://github.com/apple/swift-format.git", from: "0.50500.0"),
    ],
    targets: [
        .plugin(
            "MyFormatterPlugin",
            capability: .command(
                verb: "format-my-code",
                description: "Uses swift-format to modify the Swift code in the package"),
                permissions: [
                    .writeToPackageDirectory(reason: "This command reformats source files")
                ]
            ),
            dependencies: [
                .product(name: "swift-format", package: "swift-format"),
            ]
        )
    ]
)
```

The implementation of the package plugin itself:

```swift
import PackagePlugin

@main
struct MyFormatterPlugin: CommandPlugin {
    
    func performCommand(
       context: PluginContext,
       targets: [Target],
       arguments: [String]
    ) throws {
        // We'll be invoking `swift-format`, so start by locating it.
        let swiftFormatTool = try context.tool(named: "swift-format")
  
        // Iterate over the targets we've been asked to format.
        for target in targets {
            // Skip any type of target that doesn't have source files.
            // Note: We could choose to instead emit a warning or error here.
            guard let target = target as? SourceModuleTarget else { continue }
 
            // Invoke `swift-format` on the target directory, passing a configuration
            // file from the package directory.
            let (exitcode, stdout, stderr) = try swiftFormatTool.run(arguments: [
                "-m", "format",
                "--configuration", "\(context.package.directory.appending(".swift-format.yml"))",
                "--in-place",
                "--recursive",
                "\(target.directory)"
            ])
 
            // We should report non-zero exit codes here.
        }
    }
}
```

Users can then invoke this custom command using the `swift` `package` invocation:

```shell
❯ swift package format-my-code
```

Since `--allow-writing-to-package-directory` is not passed, `swift` `package` will ask the user for permission if its stdin is attached to a TTY, or will fail with an error if not. If `--allow-writing-to-package-directory` were passed, it would just allow the plugin to run (with package directory writability allowed by the sandbox profile) without asking for permission.

## Example 3: Building Deployment Artifacts

The final example of a command plugin uses the `PackageManager` service provider’s build functionality to do a release build of a hypothetical product and then to create a distribution archive from it.

This example shows use of a local plugin target, so no package dependency is needed. This is mostly appropriate for custom commands that are unlikely to be useful outside the package.

```swift
// swift-tools-version: 5.6
import PackageDescription

let package = Package(
    name: "MyExecutable",
    products: [
        .executable(name: "MyExec", targets: ["MyExec"])
    ],
    targets: [
        // This is the hypothetical executable we want to distribute.
        .executableTarget(
            "MyExec"
        ),
        // This is the plugin that defines a custom command to distribute the executable.
        .plugin(
            "MyDistributionArchiveCreator",
            capability: .command(
                intent: .custom(
                    verb: "create-distribution-archive",
                    description: "Creates a .tar file containing release binaries"
                )
            ),
        )
    ]
)
```

The implementation of the package plugin itself:

```swift
import PackagePlugin
import Foundation

@main
struct MyDistributionArchiveCreator: CommandPlugin {
    
    func performCommand(
       context: PluginContext,
       targets: [Target],
       arguments: [String]
    ) async throws {
        // Check that we were given the name of a product as the first argument
        // and the name of an archive as the second.
        guard arguments.count == 2 else {
           throw Error("Expected two arguments: product name and archive name")
        }
        let productName = arguments[0]
        let archiveName = arguments[1]
        
        // Ask the plugin host (SwiftPM or an IDE) to build our product.
        let result = await packageManager.build(
            .product(productName),
            parameters: .init(configuration: .release, logging: .concise)
        )
        
        // Check the result. Ideally this would report more details.
        guard result.succeeded else { throw Error("couldn't build product") }
        
        // Decide on the output path for the archive.
        let outputPath = context.pluginWorkDirectory.appending("\(archiveName).tar")
    
        // Use Foundation to run `tar`. The exact details of using the Foundation
        // API aren't relevant; the point is that the built artifacts can be used
        // by the script.
        let tarTool = try context.tool(named: "tar")
        let tarArgs = ["-czf", outputPath.string, result.buildArtifacts.first{ $0.kind == .executable }.path.string]
        let process = Process.run(URL(fileURLWithPath: tarTool.path.string), arguments: tarArgs)
        process.waitUntilExit()
        
        // We should also report errors from the creation of the archive.
        
        print("Created archive at \(outputPath).")
    }
}
```

Users can then invoke this custom command using the `swift` `package` invocation:

```shell
❯ swift package create-distribution-archive MyExec MyDistributionArchive-1.0
```

This example does not need to ask for permission to write to the package directory since it only writes to the temporary directory provided by the context. A future proposal could allow the plugin to also get permission to write to output directories provided by the user.

## Security Considerations

As with other plugins, custom command plugins are sandboxed in a way that restricts their access to certain system resources. By default, plugins are prevented from writing to the file system (other than to temporary directories and cache directories), and are prevented from accessing the network.

Custom command plugins that need special permissions — such as writing to the package source directory — can specify a requirement for this permission in the declaration of the plugin. This may cause user interaction to approve the plugin’s request, and if granted, the sandbox is modified to allow this access.

The form that this request for approval will take depends on whether the plugin is invoked from the SwiftPM CLI or from an IDE that supports Swift Packages. The CLI may implement an option that needs to be passed at the time the plugin is invoked, while an IDE should ideally cache the response in some way that prevents the user from being prompted every time they invoke the plugin.

## Alternatives Considered

### Package Manager services

Most of the alternatives that were considered for this proposal center around what kind of services the Package Manager provides to plugins. This proposal chooses to expose to the plugin some of the most common actions, such as building and testing, that are also available in the SwiftPM CLI commands such as `swift` `build` and `swift` `test`. There was an intentional choice to initially limit the set of options provided in order to keep this proposal bounded.

### Declaring prerequisites in the manifest

An alternative to having the plugin call back to the host (through the `PackageManager` type) for specialized information and for asking it to perform builds or run tests, would be to declare these prerequisites in the manifest of the package that provides the plugin. Under such an approach, SwiftPM would first make sure that the prerequisites are satisfied before invoking the plugin.

The big problem with such an approach is that it’s difficult to express conditional dependencies in the manifest without adding greatly to the complexity of the manifest API, and any approach relying on such up-front prerequisites would necessarily be less flexible than letting the plugin perform package actions if and when it needs them. It would also be contrary to the goal of keeping the package manifest as clear and simple as possible. The implementation of the plugin seems like a much more appropriate place for any non-trivial logic regarding plugin prerequisites.

## Future Directions

### Better support for plugin options

In this initial proposal, the user command plugin is passed all the command line options that the user provided after the custom command verb in the `swift` `package` invocation. A future direction might be to have the plugin use SwiftArgumentParser to declare supported set of input parameters. This could allow SwiftPM (or possibly an IDE) to present an interface for those plugin options — IDEs, in particular, could construct user interfaces for well-defined options (possibly in the manner of the archaic MPW `Commando` tool).

### Additional access to Package Manager services

The API in the `PackageManager` type that this proposal defines is just a start. The idea is to, over time, offer plugins a variety of functionality and derivable information that they can request and then further process.

Currently, the only specialized information that a user command plugin can request from SwiftPM is the directory of symbol graph files for a particular target. The intent is to provide a menu of useful information that might or might not require computation in order to provide, and to allow the plugin to request this information from SwiftPM whenever it needs it.

### Providing access to build and test progress and structured results

The initial proposed API for having plugins run builds and tests is fairly minimal. In particular, the build log is returned at the end of the build as a single text string, and the plugin has no way to cancel the build. Future proposals should extend this, ideally to the point at which `swift` `build` and `swift` `test` could themselves be implemented using the same API as for custom commands.