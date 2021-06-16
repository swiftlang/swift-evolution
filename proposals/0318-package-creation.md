# Package Creation

* Proposal: [SE-0318](0318-package-creation.md)
* Author: [Miguel Perez](https://github.com/miggs597)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Status: **Active review (June 15 - June 29 2021)**
* Implementation: [apple/swift-package-manager#3514](https://github.com/apple/swift-package-manager/pull/3514)

# Introduction

In order to clearly separate the roles of transforming an existing directory of source files into a Swift package, from creating a new package from scratch we propose adding a new command `swift package create`. `swift package init` will continue to exist as is, but will be updated to focus on the former, while the new `swift package create` will focus on the latter. 


# Motivation

Currently `swift package init` handle two distinct use cases:

1. Transforming an existing directory with sources into a Swift package
2. Creating a new package from scratch.

This one-size-fits-all approach can be confusing and counter-productive, especially for users that are focused on the second use case. It assumes prior knowledge about the command behavior, and specifically about the need to create an empty directory upfront and naming the package after the directory name.

We feel that separating the two concerns into separate commands, will allow SwiftPM to have better default behavior which is more aligned with the users expectations.


## Current Behavior

### Creating new package 

To create a new package users perform the following steps:

```console
$ mkdir MyLib
$ cd MyLib
$ swift package init
```

Resulting in the following structure:

```console
.
├── .gitignore
├── Package.swift
├── README.md
├── Sources
│   └── MyLib
│       └── MyLib.swift
└── Tests
    └── MyLibTests
        └── MyLibTests.swift
```

Note that the user has to first make the `MyLib` directory and then navigate into it. 

By default, `swift package init` will use the directory name to define the package name, which can be changed by using the `--name` option.

By default, `swift package init` will set the package type to a library , which can be changed by using the `—type` option.


### Transforming an existing directory of sources into a package 

To transform an existing directory of sources into a package using `swift package init` users perform the following steps:

```console
$ cd MySources
$ swift package init
```

Resulting in the following structure:

```console
.
├── .gitignore
├── Package.swift
├── README.md
├── Sources
│   └── MySources
│       └── MySources.swift
└── Tests
    └── MySourcesTests
        └── MySourcesTests.swift
```

In this case, SwiftPM will only “fill the gaps”, or in other words only add `Source`, `Tests`, and the other files if they are missing.

By default, `swift package init` will use the directory name to define the package name, which can be changed by using the` —name` option.

By default, `swift package init` will set the package type to a library , which can be changed by using the `—type` option.


## Problem Definition

`swift package init` is a utility to get started quickly, and is especially important to new users. The current behavior as described above can often achieve the opposite given its ambiguity and reliance on prior knowledge. Specifically, the default behavior of `swift package init` is geared towards transforming existing source directory to packages, while most new users are interested in creating new programs from scratch so they can experiment with the language. 

A secondary issue is that `swift package init` uses a directory structure template which cannot be customized by the users. Given that SwiftPM is fairly flexible about the package’s directory structure, allowing users to define their own directory structure templates could be a good improvement for those that prefer a different default directory structure.


# Proposed Solution

The identified problems could be solved by the introduction of a new command `swift package create`. This new command would live alongside of `swift package init.`

 `swift package create` would be used to create a new package from scratch.

 `swift package init` would be used to transform pre-existing source directory to a package.

Both commands will gain the capability to use a templating system such that the directory structure used is customizable by the end user.


# Detailed Design

## New command: `swift package create`

Following, is the behavior of the new command:

```console
$ swift package create MyApp
```

Will create a new package with the following directory structure:

```console
.
├── Package.swift
├── Sources
│   └── MyApp
│       └── MyApp.swift
└── Tests
    └── MyAppTests
        └── MyAppTests.swift
```

Note that `swift package create` makes an executable package by default, which is important for new users trying to get their first Swift program up and running. Such users can immediately run the new package:

```console
$ cd MyApp
$ swift run ## or omit cd, and use swift run --package-path MyApp
[3/3] Linking MyApp
Hello, world!
```


### Customizing the package type

The `--type` option is used to customize the type of package created. Available options include: `library`, `system-module`, or `executable`. For example

```
$ swift package create MyLib --type library
```

Will create a library package with the the following directory structure

```console
.
├── Package.swift
├── Sources
│   └── MyLib
│       └── MyLib.swift
└── Tests
    └── MyLibTests
        └── MyLibTests.swift
```

Or, an example of creating a `system-module` package.

```console
$ swift package create SysMod --type system-module
```

Will create a library package with the the following directory structure

```console
.
├── Package.swift
└── module.modulemap
```


## User defined templates

By default, `swift package create` and `swift package init` uses the following directory structure:

```console
.
├── Package.swift
├── Sources
│   └── <Module>
│       └── <Module>.swift
└── Tests
    └──<Module>Tests
        └── <Module>Tests.swift
```

To support use cases in which individuals or teams prefer a different directory structure that they can use consistently in their projects, the proposal introduces a new configuration option named “template”.

Templates are defined by adding a directory to SwiftPM’s configuration directory, e.g. `~/.swiftpm/configuration/templates/new-package/<template-name>`

The template is a Swift package directory that SwiftPM copies and performs transformations on to create the new package. SwiftPM performs the following steps when creating a package from a template:

1. Copy the template directory to the target location.
2. Substitute string placeholders with values that are derived from the new package request or context.
3. Strip git information from the template location. 


For example, given a `test` template located in `~/.swiftpm/configuration/templates/new-package/test` with the directory structure:

```console
.
├── .git
├── .gitignore
├── Package.swift
├── README.md
├── LICENSE.md
└── src
    └── MyApp.swift
```

The following `Package.swift`:

```swift
import PackageDescription

let package = Package(
    name: "___NAME___",
    dependencies: [        
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),        
    ],
    targets: [
        .executableTarget(
            name: "___NAME_AS_C99___",
            sources: "src",
            dependencies: [
              .product(name: "NIO", pacakge: "swift-nio"),
              .product(name: "`Crypto`", pacakge: "swift-crypto")
            ]
        ),
    ]
)
```

And the following `README.md`:

```markdown
### ___NAME___

This is the ___NAME___ package!
```

Running `swift package init --template test --name HelloWorld`

Will result with the following directory structure:

```console
.
├── Package.swift
├── .gitignore
├── README.md
├── LICENSE.md
└── src
    └── MyApp.swift
```

The following `Package.swift`:

```swift
import PackageDescription

let package = Package(
    name: "HelloWorld",
    dependencies: [        
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),        
    ],
    targets: [
        .executableTarget(
            name: "HelloWorld",
            sources: "src",
            dependencies: [
              .product(name: "NIO", pacakge: "swift-nio"),
              .product(name: "Crypto", pacakge: "swift-crypto")
            ]
        ),
    ]
)
```

And the following `README.md`:

```markdown
### HelloWorld

This is the HelloWorld package!
```

When the `--name` option is omitted, the name of the target directory will be used as the package name.

### Substitutions

While transforming the template directory into a package, SwiftPM performs string substitutions on all text files, using the following metadata fields:

1. `___NAME___`: The name provided by the user using the `--name` flag
2. `___NAME_AS_C99___`: The name provided by the user using the `--name` flag, transformed to be C99 compliant 

Future iterations of this feature will include additional metadata fields that can be used in this context.


### Defining the default template

To customize the default template (i.e. when `swift package create` is invoked with the explicit `--template `argument), user define a template named “default”, i.e. `~/.swiftpm/configuration/templates/new-package/default`


### Adding and updating templates

Templates are designed to be shared as git repositories. The following commands will be added to SwiftPM to facilitate adding and updating templates:

`swift package add-template <url> [--name <name>]`

Performs `git clone` of the provided URL into  `~/.swiftpm/configuration/templates/new-package/,` making the template available to use immediately. The optional `--name` option can be used to set a different name from the one automatically given via the `git clone` operation. 

`swift package update-template <name>`

Performs a `git update` on the template found at  `~/.swiftpm/configuration/templates/new-package/<name>`.


## Impact on SwiftPM

When processing `swift package create` or `swift package init`, SwiftPM will do the following

1. If a template is specified with `--template` option: try to load the template and use it as described above, exiting with an error if such template was not found or ran into parsing errors.
2. When no template is specified with `--template` option:
    1. Check if a default template is defined in `~/.swiftpm/configuration/templates/new-package/default.` If one is defined, use it as described in #1 above
    2. If no default template is defined, construct a default `PackageTemplate` based on the `--type` option when provided, or the default type when such is not.


## Changes to `swift package init`

`swift package init` will be slightly updated to reflect it’s focus on transforming existing source directories to packages:

1. `swift package init` will no longer add a `README.md`, and .`gitignore` files by default, reducing its impact on the existing sources directory.
2. When `swift package init` is used in an empty directory, it will create a new package as it does today but emit a diagnostics message encouraging the user to use `swift package create` in the future, to help transition to the more appropriate command.
3. `swift package init` will accept the new `--template` option and apply it as described above.


# Security

No impact.


# Impact on existing packages

No impact.


# Alternatives considered

The main alternative is to modify the behavior of `swift package init` such that it better caters to the creation of new packages from scratch. The advantage of this alternative is that it maintains the  API surface area. The disadvantages are that any changes to make it better for package creation are likely to make it confusing for transforming existing sources to package. More importantly, changes to the existing command may cause impact on users that have automation tied to the current behavior. 

For templates, the main alternative is to use a data file (e.g. JSON) that describes how the package should be constructed. This would hone in the implementation as it defines a finite set of capabilities driven by configuraiton. This was not selected in order to provide a better user experience, and greater flexibility with respect to including other files in a template.

# Future Iterations

In order to provide greater flexibility than what copying a Swift package directory can provide, a future version of SwiftPM could allow packages to be created in a procedural manner. SwiftPM could introduce new APIs that provide a toolbox of functionality for creating and configuration various aspects of packages, and could invoke Swift scripts that create new packages using those APIs. Such scripts could make decisions about what content to create based on input options or other external conditions. These APIs would also function when creating a Swift package from scratch, and or transforming existing sources into a Swift Package.
