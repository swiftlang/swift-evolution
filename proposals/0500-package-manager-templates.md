# Improving package creation with custom templates: SwiftPM Template Initialization

* Proposal: [SE-0500](0500-package-manager-templates.md)
* Authors: [John Bute](https://github.com/johnbute)
* Review Manager: [Franz Busch](https://github.com/FranzBusch)
* Status: **Accepted**
* Implementation: [apple/swift-package-manager#04956](https://github.com/swiftlang/swift-package-manager/pull/9211)
* Review: ([pitch](https://forums.swift.org/t/pitch-improving-package-creation-with-custom-templates-swiftpm-template-initialization/81525) ) ([review](https://forums.swift.org/t/se-0500-improving-package-creation-with-custom-templates/83321)) ([acceptance](https://forums.swift.org/t/accepted-with-modifications-se-0500-improving-package-creation-with-custom-templates/84129))

## Introduction

This proposal introduces a system that enables Swift packages to declare reusable templates with customizable logic for generating package code tailored to a user's specific use case. These templates can be distributed like any other Swift package and instantiated in a standardized, first-class manner using an enhanced `swift package init` command.

## Motivation

Currently, SwiftPM supports a handful of hardcoded templates that act as a starting point for user projects. These built-in templates, accessible via `swift package init`, allow users to initialize basic packages such as libraries, tools, executables, and macros. While `swift package init` remains valuable for initializing simple packages, many Swift developers face more complex requirements when starting a new project, whether that may be initializing an HTTPS server or creating a package that implements an OpenAPI specification. These more complex package initializations have to be achieved through third-party command-line tools or custom scripts, many of which operate outside the SwiftPM ecosystem. This disconnect increases the complexity and makes it harder for users to discover, share, or customize initialization workflows.

## Proposed solution

This proposal suggests extending the `swift package init` command to allow developers to easily get started with a new package based on a specific use case, by allowing the invocation of custom, user-defined templates that are:

* Fully integrated with SwiftPM
* Customizable through arguments and logic
* Shareable just like standard Swift packages
* Flexible enough for a wide range of use-cases.

The improved `swift package init` command enables users to easily generate a package based on predefined templates. The init command currently allows users to select a template bundled within SwiftPM via the `--type` option. However, this functionality will now be extended to support selecting a template from an external package located either on local disk, in a git repository, or in a package registry, by specifying the template’s location using the `--path`, `--url`, or `--package-id` options along with any necessary versioning requirements. SwiftPM will then generate the package based on the selected template:

```
% swift package init --type PartsService --package-id author.template-example
...
Build of product 'PartsService' complete! (7.15s)

Add a starting database  migration routine: [y/N] y

Add a README.md file with an introduction and tour of the code: [y/N] y

Choose from the following:

• Name: include-database
About: Add full database support to your package.
• Name: exclude-database
About: Create the package without database integration
include-database

Pick a database system for part storage and retrieval. [sqlite3, postgresql] (default: sqlite3):
sqlite3

Building for debugging...
[1/1] Write swift-version.txt
Build of product 'PartsService' complete! (0.42s)
```

After the project is generated, the user is left with a scaffolded package and is ready to start coding.

```
.
├── Package.swift
├── Scripts
│   └── create-db.sh
├── README.md
├── Sources
│   ├── Models
│   │   └── Part.swift
│   │  
│   └── App
│       └── main.swift
│ 
└── Tests
    └── PartsServiceTests
        └── PartsServiceTests.swift
```

Below is the new output of `swift package init --help`

```
% swift package init --help
OVERVIEW: Initialize a new package.

USAGE: swift package init [<options>] [<args> ...]

ARGUMENTS:
<args>                  Template arguments to auto-fill prompts and skip input.

OPTIONS:
--type <type>           Specifies the package type or template.
Valid values include:

library           - A package with a library.
executable        - A package with an executable.
tool              - A package with an executable that uses
Swift Argument Parser. Use this template if you
plan to have a rich set of command-line arguments.
build-tool-plugin - A package that vends a build tool plugin.
command-plugin    - A package that vends a command plugin.
macro             - A package that vends a macro.
empty             - An empty package with a Package.swift manifest.
custom            - When used with --path, --url, or --package-id,
this resolves to a template from the specified 
package or location.
--name <name>           Provide custom package name.
--path <path>           Path to the package containing a template.
--url <url>             The git URL of the package containing a template.
--package-id <package-id>
The package identifier of the package containing a template.
--exact <exact>         The exact package version to depend on.
--revision <revision>   The specific package revision to depend on.
--branch <branch>       The branch of the package to depend on.
--from <from>           The package version to depend on (up to the next major version).
--up-to-next-minor-from <up-to-next-minor-from>
The package version to depend on (up to the next minor version).
--to <to>               Specify upper bound on the package version range (exclusive).
--validate-package      Run 'swift build' after package generation to validate the template output.
--version               Show the version.
-h, -help, --help       Show help information.
```

To encourage community reuse and sharing, templates are intended to be distributed using the same mechanism as Swift packages themselves. This ensures that developers can rely on familiar distribution workflows:

* Git repositories
* Swift package registry entries
* Local paths

SwiftPM will resolve these sources similarly to how it handles regular dependencies. This change opens the door to an ecosystem of templates maintained by framework authors as well as enterprise-internal scaffolds tailored to a company's needs.

## Detailed design

### New Package Description API

#### TemplateTarget

Consumers must be aware of templates, their purpose, and the permissions they require to run. As such, this proposal introduces a new `templateTarget` type to the `PackageDescription` API. The new `templateTarget` type abstracts the declaration of two types of modules:

* a template `executableTarget` that performs the file generation and project setup
* a command-line `pluginTarget` that safely invokes the executable

The command-line plugin allows the template executable to run in a separate process, and (on platforms that support sandboxing) it is wrapped in a sandbox that prevents network access as well as attempts to write to arbitrary locations in the file system. Command-line plugins also have access to the package model through the `context` variable of the `PackagePlugin` API. This model can be used by the template to understand the current package's structure in order to infer sensible defaults or validate user inputs against existing package data.

The executable allows authors to define user-facing interfaces which gather important consumer input needed by the template to run, using Swift Argument Parser for a rich command-line experience with subcommands, options, and flags.
In order for a consumer to initialize a package based on a template, authors must declare the `templateTarget` type within their package's manifest:

```
let package = Package(
    name: "TemplateExample",
    products: .template(name: "Template1"),
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from "1.3.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0")
    ],
    targets: 
        .template(
        name: "Template1",
        dependencies: [
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "AsyncHTTPClient", package: "async-http-client")
        ],
        initialPackageType: .executable,
        description: "A simple template that requires network access",
        templatePermissions: [
            .allowNetworkConnections(scope: .none, reason: "Need network access to help generate a template")
        ]
    )
)
public extension [Target] {
    @available(_PackageDescription, introduced: 6.3.0)
    static func template(
        name: String,
        dependencies: [Target.Dependency] = [],
        path: String? = nil,
        exclude: [String] = [],
        sources: [String]? = nil,
        resources: [Resource]? = nil,
        publicHeadersPath: String? = nil,
        packageAccess: Bool = true,
        cSettings: [CSetting]? = nil,
        cxxSettings: [CXXSetting]? = nil,
        swiftSettings: [SwiftSetting]? = nil,
        linkerSettings: [LinkerSetting]? = nil,
        plugins: [Target.PluginUsage]? = nil,
        initialPackageType: Target.TemplateType = .empty,
        templatePermissions: [TemplatePermissions]? = nil,
        description: String
    ) -> [Target]
}
```

The `templateTarget` declares the name and capability of the template, along with its dependencies. The `initialPackageType` specifies the base package structure that SwiftPM will set up before invoking the template — this can be `.library`, `.executable`, `.tool`, `.buildToolPlugin`, `.commandPlugin`, `.macro`, or `.empty`.
The dependency array of the new `.template()` API allows the author to specify the packages that will be available for use by the template executable when generating a consumer's package. These dependencies can be utilized by the author as utilities for file generation, string processing, or network requests if needed.

Meanwhile, the permissions array is focused on specifying security requirements and access scopes needed by the package. Whenever a permission is required, the template will prompt the user just as plugins do. This process helps ensure that users understand why certain permissions are required when executing an author's template, ensuring transparency and establishing trust between users and authors.

The Swift script files that implement the logic of the template are expected to be in a directory of the same as the template, located under the `Templates` subdirectory of the package. The template also expects Swift script files in a directory of the same name as the template, alongside a `Plugin` suffix, located under the `Plugins` subdirectory of the package.

Below is an example of the directory structure of an author's package:

```
.
├── Package.swift
│
├── Templates
│   └── Template1
│       └── Template1.swift
├── Plugins
│   └── Template1Plugin
│       └── Template1Plugin.swift
│
└── Tests
    └── FooTests
        └── FooTests.swift
```

#### TemplateProduct

This proposal also introduces the new `templateProduct` type to the `PackageDescription` API.

```
public extension [Product] {
    @available(_PackageDescription, introduced: 6.3.0)
    static func template(
        name: String,
    ) -> [Product]
}
```

Templates must be declared as products by their authors; otherwise, a manifest compilation error will occur. This requirement exists because initializing a package from a template involves attaching the author's package as a dependency to the consumer's base package. Since templates are compiled artifacts consumed by other packages, explicitly declaring them as products ensures their role is clearly defined and properly integrated during package initialization.

### Authoring a template's command-line plugin

When declaring a `templateTarget` type, the author must create Swift file that invoke the template’s executable. These scripts should be placed in a directory named after the template, with the `Plugin` suffix, located under the Plugins subdirectory of the package. This structure is essential because it enables the Swift Package Manager to invoke the template’s executable in a sandboxed, permission-aware manner whenever possible.

Writing a template’s command-line plugin is similar to writing a standard command-line plugin, with the key difference being that the plugin invokes the template’s executable.

For examples on ways to write a template's command-line plugin, refer to the template-example-repository.

### Authoring a template's executable

Maintaining templates over time, especially those with big decision trees, can be challenging for authors. Ensuring that a template behaves as expected across different configurations is crucial to its reliability and long-term usability. As such, the template-authoring experience centers around two facets:

* Flexibility
* Testability

Template authors should have the flexibility to design their templates however they prefer, whether that preference may be using templating engines, string interpolation or another approach. It should be up to the template author to choose the style that brings them comfort and familiarity.
At the same time, this flexibility requires a reliable way for templates to communicate with SwiftPM and vice-versa. In order to allow this communication, template authors, when authoring executables, must define information required by the template as command-line arguments:


>The following excerpt how to author a template with swift-argument-parser.

```
@Flag(help: "Add a README.md file with an introduction and tour of the code")
var readme: Bool = false

@Option(help: "Pick a database system for part storage and retrieval.")
var database: Database = .sqlite3

@Flag(help: "Add a starting database migration routine.")
var migration: Bool = false
```

The reasoning behind this decision is to leverage Swift’s powerful JSON parsing capabilities alongside `--experimental-dump-help`, which produces a JSON representation of a command-line interface, in order to prompt the consumer for their choices.

However, a template is not simply a list of options, flags, and arguments. It is a branching decision tree, where specific choices influence which options are available next. To model these branching paths, authors can organize them into subcommands, which help users navigate complex template structures more naturally.


>The following excerpt how to author a template with swift-argument-parser. If a different argument parsing technology is chosen, the output and schema may differ. However, any tool aiming to integrate with the template ecosystem should be able to respond to the `--experimental-dump-help` flag and emit compatible JSON

```
@main
struct ServerGenerator: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "server-generator",
        abstract: "This template gets you started with starting to experiment with servers in swift.",
        subcommands: [
            CRUD.self,
            Bare.self
        ],
    )

    @OptionGroup(visibility: .hidden)
    var packageOptions: PkgDir

    @Option(help: "Add a README.md file with an introduction and tour of the code")
    var readMe: Bool = false

    mutating func run() throws {
        ...   
    }
}

struct Bare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bare",
        abstract: "Generate a bare server"
    )

    @OptionGroup
    var serverOptions: SharedOptionsServers

    @ParentCommand var serverGenerator: ServerGenerator

    func run() throws {
        serverGenerator.run()
        
        guard let pkgDir = serverGenerator.packageOptions.packageDir else {
            throw ValidationError("No --pkg-dir was provided.")
        }
        
        try? FileManager.default.removeItem(atPath: pkgDir.appending("Package.swift"))
        try packageSwift(serverType: .bare).write(toFile: pkgDir.appending("Package.swift"))
    }
}

public struct CRUD: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "crud",
        abstract: "Generate CRUD server",
    )

    @Option(help: "Set the logging level.")
    var logLevel: LogLevel = .debug

    @ParentCommand var serverGenerator: ServerGenerator

    @OptionGroup
    var serverOptions: SharedOptionsServers

    public func run() throws {
        serverGenerator.run()

        guard let pkgDir = serverGenerator.packageOptions.pkgDir else {
            throw ValidationError("No --pkg-dir was provided.")
        }

        try? FileManager.default.removeItem(atPath: pkgDir.appending("Package.swift"))
        try packageSwift(serverType: .crud).write(toFile: pkgDir.appending("Package.swift")
    }
}

struct PkgDir: ParsableArguments {
    @Option(help: .hidden)
     var packageDir: AbsolutePath?
}
```

>Note: The `@ParentCommand` property wrapper is a new feature in swift-argument-parser that allows subcommands to access shared logic and state of their respective parent command. This enables a clean seperation of logic between the different layers of commands, while still allowing sequential execution and reuse of common configuration or setup code at higher levels.


The example code provided demonstrates how a template with multiple decision branches might be structured to generate files, but the actual approach to templating, including how source code is generated, organized, or customized, is entirely up to the template author. Swift Package Manager simply provides the mechanism to invoke templates; the template author defines the logic, content, and structure of the generated code according to their needs.

Below is what the consumer might see when initializing a project based on the template above:

```
% swift package init --type ServerTemplate --path <path/to/template>
...
Choose from the following:

• Name: crud
About: Generate CRUD server

• Name: bare
About: Generate a bare server

Type the name of the option:
crud

Set the logging level. [trace, debug, info, notice, warning, error, critical] (default: debug):
notice

Building for debugging...
[1/1] Write swift-version.txt
Build of product 'ServerTemplate' complete! (0.42s)
```

For more examples on ways to write a template's executable, refer to the template-example-repository.

### Contract Between Templates and SwiftPM

SwiftPM communicates with templates through a defined contract. This ensures that SwiftPM can discover, prompt for, and pass arguments to template generators in a consistent and automated way.

When a template package is first discovered, SwiftPM invokes its executable using the `experimental-dump-help` flag.

This flag allows the template generator to output all of its command-line interface help information as JSON to standard output. SwiftPM then parses this JSON to learn:

* The subcommands the template provides
* What arguments, options, and flags are supported by the template
* Which inputs are required or optional
* How each argument should be parsed and displayed to the user

This allows for SwiftPM, IDEs and other higher-level tools to utilize the JSON metadata to generate interactive prompts and validate user input when creating projects from templates. The format can also be transmitted over wire protocols and published for broader integration.

suggestion: It's not SwiftPM that can use this metadata, but also higher-level tools too, such as IDE's. The format is sendable over wire protocols and publishable too.

Any argument parser wishing to support SwiftPM templates must implement the `--experimental-dump-help` flag alongside the following schema:

#### Top-Level Structure

|Property    |Type    |Description    |IsRequired    |
|---    |---    |---    |---    |
|serializationVersion    |`Integer`    |The version number of the JSON schema    |✓    |
|command    |`CommandInfoV0`    |Command Information    |    |

#### CommandInformationV0

|Property    |Type    |Description    |IsRequired    |
|---    |---    |---    |---    |
|commandName    |`String`    |Name used to invoke the command    |✓    |
|superCommands    |`[String]?`    |Array of parent command names in hierarchy    |    |
|shouldDisplay    |`Bool`    |Whether the command appears in help    |✓    |
|abstract    |`String`    |Short description of command functionality    |    |
|discussion    |`String?`    |Extended description of command functionality    |    |
|defaultSubcommand    |`String?`    |Name of default subcommand    |    |
|subcommands    |`[CommandInfoV0]?`    |Array of nested subcommands    |    |
|arguments    |`[ArgumentInfoV0?]`    |Array of supported arguments/options/flags    |    |

####  Argument Information (ArgumentInfoV0)

|Property    |Type    |Description    |IsRequired    |
|---    |---    |---    |---    |
|kind    |`KindV0`    |"positional", "option", or "flag    |✓    |
|shouldDisplay    |`Bool`    |Whether argument appears in help    |✓    |
|sectionTitle    |`String?`    |Custom section name for grouping    |    |
|isOptional    |`Bool`    |Whether argument can be omitted    |✓    |
|isRepeating    |`Bool`    |Whether argument can be specified multiple times    |✓    |
|parsingStrategy    |`String`    |How the argument is parsed    |✓    |
|names    |`[NameInfoV0]?`    |All names/flags for the argument    |    |
|preferredName    |`NameInfoV0`    |Best name for help displays    |    |
|valueName    |`String?`    |Name of argument's value in help    |    |
|defaultValue    |`String?`    |Default value if none specified    |    |
|allValues    |`[String]?`    |List of all valid values (for enums)    |    |
|allValuesDescriptions    |`{String: String}?`    |Mapping of values to descriptions    |    |
|completionKind    |`CompletionKindV0?`    |Type of shell completion    |    |
|abstract    |`String?`    |Short description of argument    |    |
|discussion    |`String?`    |Extended description of argument    |    |

####  Name Information (NameInfoV0)

|Property    |Type    |Description    |IsRequired    |
|---    |---    |---    |---    |
|Kind    |`KindV0`    |"long", which is a multi-character name preceded by two dashes, "short" which is a single character name preceded by a single dash, or "longWithSingleDash" which is a multi-character name preceded by a single dash.    |✓    |
|Name    |`String`    |Single or multi-character name of the argument.    |✓    |

####  Parsing Strategy Values

```
- "default" - Expect next element to be a value
 - "scanningForValue" - Parse next value element
 - "unconditional" - Parse next element regardless of type
 - "upToNextOption" - Parse multiple values until next option
 - "allRemainingInput" - Parse all remaining elements
 - "postTerminator" - Collect elements after --
 - "allUnrecognized" - Collect unused inputs
```


Once SwiftPM ingests the JSON representation, it prompts the user for any required inputs, before forming a full command-line invocation from those responses. 

```
my-template generate --name AnExample --host *8080* 
```

SwiftPM passes this command line

Swift Argument Parser implements all of the above, and is the recommended and supported way for template generators to integrate with SwiftPM.


>Note: Further details regarding the long-term vision for stabilizing the interface between SwiftPM, IDEs, and template generators are discussed in Future Directions

### Workflow of initializing a package based off a template

When a user executes `swift package init` with template options, SwiftPM follows this workflow:

#### Command Parsing and Template Source Resolution

Whenever a consumer declares one of three command-line arguments associated to the location of a package containing a template, SwiftPM will resolve the source type (local, git, registry). Next, SwiftPM will validate if the source location is syntaxically valid (a local path that exists, valid package-id format, etc.) Afterwards, SwiftPM will extract versioning constraints declared by the consumer and collect the consumer's predefined arguments for validation, which will happen in the prompting phase.

#### Version Requirements Resolution

Based on the template's source, SwiftPM will resolve versioning requirements declared by the user differently:

* Local: No version resolution needed
* Git: Creates SourceControl.Requirement base on version flags/options such as `revision`, `branch`, and `from`. A versioning requirement must be declared by a user when consuming a template from git.
* Registry: Creates Registry.Requirement based on version flags/options. If a user omits versioning requirements, SwiftPM fetches the package's latest release.

#### Template Path Resolution

The TemplatePathResolver obtains the template package and determines its absolute path. For Git-based templates, SwiftPM clones the repository to a temporary location using the specified version or branch. For registry-based templates, SwiftPM downloads and extracts the specified version. This step is essential because SwiftPM must parse the template package's manifest in order to infer the base package that should be initialized and attach the author's package as a dependency.

#### Temporary Workspace Creation

SwiftPM creates a temporary directory structure during project generation to manage intermediate files and cleanup tasks:

```
/tmp/swift-pm-<UUID>/
├── generated-package/
└── clean-up/             # Final cleanup area before copying to destination
```

The generated-package directory is where SwiftPM executes the template’s artifact and generates the user’s project. Once generation is complete, SwiftPM copies the generated package into the clean-up directory and removes any build artifacts before copying the cleaned package to the final destination.

#### Template Metadata Parsing

To determine the type of base package to initialize (`macro`, `library`, `executable`...), SwiftPM first loads the manifest of the author's package and identifies the targets using the `templateInitializationOptions` field. If the consumer has not specified a template name, SwiftPM will automatically resolve the template only if there is exactly one template in the package. If multiple templates are present, and no name is provided, an error is thrown. Finally, SwiftPM parses the JSON output of the author package's manifest and locates the correct `templateTarget` and its `initialPackageType`.

#### Base Package Structure Creation and Build

SwiftPM begins by generating the initial package structure in a staging directory, creating the standard Swift package layout. It then attaches the template's package as a dependency, which may be sourced locally, via Git, or from a registry, depending on the template's origin. Once the structure is in place, SwiftPM proceeds to build the base package along with all of its dependencies, including the template package. This involves resolving and downloading any additional dependencies, compiling the template's executable and plugin components, and making sure that all build products are available for execution by the consumer’s package.

#### Interactive Template Execution

The execution of a template generator involves several steps:

1. Argument Schema Discovery

Firstly, SwiftPM prompts for any permissions before executing the template with a special flag to get the JSON representation of the template executable's argument tree.

1.  User Interaction Flow

SwiftPM proceeds to parse the JSON representation of the template executable's decision tree, prompting for required arguments not provided via command-line, present subcommand choices if the template has multiple execution paths, validate user inputs against argument constriants, and build the final argument list for template execution.

1.  Sandboxed Template Execution

After building the final argument list, SwiftPM will execute the template's executable via plugin in a sandboxed environment (where supported), passing resolved arguments and package context. During execution, the author's template will generate source files based on user inputs, modify or rewrite the consumer's manifest file, create additional resources, scripts, or configuration files, and apply user customization throughout the package structure. Once the template's execution is finished, the consumer is left with a fully generated package, and is ready to start coding.

#### Build Artifact Cleanup

SwiftPM ensures to remove any remnant build artifacts (./build/, Package.resolved) left from the package generation process by copying the generated package from the staging to the cleanup directory and running swift package clean.

#### Final Package Assembly + Optional Package Validation

After completing all previous steps, SwiftPM copies the cleaned package contents to the user’s target directory. If the --validate-package flag is specified, it automatically runs `swift build` in the target directory and reports the results. SwiftPM then removes any temporary workspace directories, including downloaded templates from Git or registry sources. If an error occurs at any stage, SwiftPM cleans up all temporary resources created up to that point. Any cleanup failures are logged as warnings, and the original error is preserved to aid in debugging. This process ensures a secure, reliable, and user-friendly package generation experience. It combines sandboxing for safety with comprehensive error handling for robustness.

### Testing Templates

Templates, like any other shippable software, should be testable. The flexibility of creating a template allows authors to write various types of tests, including unit tests, and integration tests. Authors should strive to deliver high-quality templates while minimizing unnecessary risk, complexity, and rework. Therefore, authors are strongly encouraged to write focused tests that ensure reliability and maintainability.

Below is an example of a simple unit test, verifying whether a file generation function correctly interpolates configuration values into an output file and reflects logging-related settings in the generated code:

```
import Testing
import Foundation
@testable import ServerTemplate

struct CrudServerFilesTests {
    @Test
    func testGenTelemetryFileContainsLoggingConfig() {
        
        let generated = CrudServerFiles.genTelemetryFile(
            logLevel: .info,
            logFormat: .json,
            logBufferSize: 2048
        )

        #expect(generated.contains("let logBufferSize: Int = 2048"))
        #expect(generated.contains("Logger.Level.info"))
        #expect(generated.contains("LogFormat.json"))
    }
}
```

To support end-to-end testing of templates, Swift Package Manager introduces a new subcommand: swift test template. This subcommand allows authors to verify if a given template can successfully generate a package and that a generated package builds correctly. By specifying both a template and an output directory, SwiftPM performs the following actions:

* Reads the package, locates the template, and extracts all available options, flags, arguments, and subcommands,
* Prompts for all required inputs (options, flags, and arguments).
* Generates each possible path in the decision tree, from the root command to the leaf subcommands, using the user’s given inputs.
* Validates that each variant is created successfully and builds without error.
* Logs any errors to a file located within the generated package directory.

```
% swift test template --template-name ServerTemplate --output-path <output/directory/path>
...
Build of product 'ServerTemplate' complete! (3.37s)

Set logging buffer size (in bytes). (default: 1024):
2048

Server Port (default: 8080):
80

Set the logging format. [json, keyValue] (default: json):
keyValue

Set the logging level. [trace, debug, info, notice, warning, error, critical] (default: debug):
critical

Add a README.md file with an introduction to the server + configuration?: [y/N] y

Generating server-generator-crud

Generating server-generator-bare

Argument Branch           Gen Success Gen Time(s) Build Success Build Time(s) Log File
server-generator-crud-mtls    true      11.17         true         92.09         -
server-generator-crud-no-mtls true      11.53         true         91.65         -
```

Each variant is written to a subdirectory within the output path. Directory names follow the structure `<command>-<subcommand>-...`, reflecting the decision tree. This makes it easy for authors to:

* Review generated output,
* Test specific branches,
* Increase confidence in correctness and reliability.

To test a specific branch only or test predefined arguments, authors can use command-line arguments offered by `swift test template` to narrow the decision tree scope. End-to-end testing ensures templates behave as expected across all decision branches, giving authors greater confidence in their stability and correctness.

## Impact on existing packages

This is an additive feature. Existing packages will not be affected by this change. It adds the ability to define and invoke templates as part of a Swift Package.

## Future Directions

* Enable package enhancement using a selected template.
* Extending Swift registries to support template metadata, making templates more searchable and discoverable.
* Providing an API to simplify modifications to Package.swift, allowing users to add dependencies, targets, target-dependencies, and products without rewriting the file or syntaxically writing them in.
* Offer a library for programmatic template testing, enabling more controlled and comprehensive end-to-end testing
* Transform `--experimental-dump-help` into a stable equivalent flag. Learn more about it here: ([pitch](https://forums.swift.org/t/dropping-the-experimental-from-dump-help/82099)) ([PR](https://github.com/apple/swift-argument-parser/pull/817))
* Support and actively contribute to the [OpenCLI](https://opencli.org/) initiative, prompting a standardize JSON format for broader parser interoperability.

### Stablization and Evolution of Template Interface

A big part of templates is the contract shared between packages containing templates and SwiftPM. 

Currently, SwiftPM utilize the `--experimental-dump-help` flag alongside Swift Argument Parser’s `ToolInfoV0` JSON schema to input consumers about the arguments and subcommands required by templates. 

The use of an experimental flag and the dependency on Swift Argument Parser’s internal schema are not ideal for long-term stability. However, there are several active directions to address these issues:


* **Stabilization of the tool info interface**: Transform `--experimental-dump-help` into a stable equivalent flag, paired with a stable JSON schema (`ToolInfoV1`) that formally describes an executable’s command tree. Learn more about this work in [[Pitch](https://forums.swift.org/t/dropping-the-experimental-from-dump-help/82099)/[PR](https://github.com/apple/swift-argument-parser/pull/817)].
* **Broader parser interoperability**: Support and contribute to the OpenCLI initiative, which aims to define a standardized JSON representation for command-line tool metadata across ecosystems. To support and contribute the OpenCLI initiative, please visit [OpenCLI](https://opencli.org/).

#### ToolInfo Versions and Future evolution

At present, there are two versions of the ToolInfo schema in play:

* `ToolInfoV0`, the experimental version used by —experimental-dump-help
* `ToolInfoV1`, the stable successor used by the new —help-dump-tool-info-v1 flag

Functionally, these two versions are identical excpet for the declared serailization version, ensuring backward compatibility and providing the base for a stable interface. This alignment allows existing template generators to continue operating without modification, while offering a clear migration path to the stable `v1` API.

To support multiple tool info versions over time, SwiftPM will implement a negotiation mechanism when invoking templates, relying on special flags or options that indicate the desired ToolInfo version.

For example, SwiftPM may first attempt `--help-dump-tool-info-v2`. If the executable does not recognize the flag or fails to respond with a valid JSON schema, SwiftPM will gracefully fall back to an earlier version such as `--help-dump-tool-info-v1`, then `--experimental-dump-help`. SwiftPM will iterate through its list of known versions, starting from the newest until it receives a valid JSON schema. This ensures forward compatibility with future schema revisions and allows template executables to adopt new versions at their own pace while maintaining interoperability with older SwiftPM releases.

Looking forward, there is also the possibility of integrating an OpenCLI-compliant version. This would extend beyond Swift-specific tooling, allowing parsers to describe a language-agnostic CLI interface. The goal is to reduce dependency on Swift Argument internals and make template discovery interoperable across different argument parsers.
