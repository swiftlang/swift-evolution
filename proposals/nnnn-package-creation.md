# Package Creation

* Proposal: [SE-NNNN](https://github.com/apple/swift-evolution/blob/main/proposal-templates/NNNN-filename.md)
* Authors: [Miguel Perez](https://github.com/miggs597/)
* Review Manager: TBD
* Status: Awaiting implementation

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

To create a new package using `swift package init` users perform the following steps:

```
$ mkdir MyLib
$ cd MyLib
$ swift package init
```

Resulting in the following structure:

```
.
├── Package.swift
├── README.md
├── Sources
│   └── MyLib
│       └── MyLib.swift
└── Tests
    └── MyLibTests
        └── MyLibTests.swift
```

Note that the user has to first make the MyLib directory and then navigate into it. 

By default, `swift package init` will use the directory name to define the package name, which can be changed by using the `--name` option.

By default, `swift package init` will set the package type to a library , which can be changed by using the `—type` v.


### Transforming an existing directory of sources into a package 

To transform an existing directory of sources into a package using `swift package init` users perform the following steps:

```
$ cd MySources
$ swift package init
```

Resulting in the following structure:

```
.
├── Package.swift
├── README.md
├── Sources
│   └── MySources
│       └── MySources.swift
└── Tests
    └── MySourcesTests
        └── MySourcesTests.swift
```

In this case, SwiftPM will only “fill the gap”, or in other words only add `Source`, `Tests`, and the other files if they are missing.

By default, `swift package init` will use the directory name to define the package name, which can be changed by using the` —name` option.

By default, `swift package init` will set the package type to a library , which can be changed by using the `—type` option.


## Problem Definition

`swift package init` is a utility to get started quickly, and is especially important to new users. The current behavior as described above can often achieve the opposite given its ambiguity and reliance on prior knowledge. Specifically, the default behavior of `swift package init` is geared towards transforming existing source directory to packages, while most new users are interested in creating new programs from scratch so they can experiment with the language. 

A secondary issue is that `swift package init` uses a directory structure template which cannot be customized by the users. Given that SwiftPM is fairly flexible about the package’s directory structure, allowing users to define their own directory structure templates could be a good improvement for those that prefer a different default directory structure.


# Proposed Solution

The identified problems could be solved by the introduction of a new command `swift package create`. This new command would live alongside of `swift package init.`

 `swift package create` would be used to create a new package from scratch.

 `swift package init` would be used to transform pre-existing source material to a package.

Both commands will gain the capability to use a templating system such that the directory structure used is customizable by the end user.


# Detailed Design

## New command: `swift package create`

Following, is the behavior of the new command:

```
$ swift package create MyApp
```

Will create a new package with the following directory structure:

```
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

```
$ cd MyApp
$ swift run ## or omit cd, and use swift run --package-path MyExe
[3/3] Linking MyApp
Hello, world!
```


### Customizing the package type

The `--type` option is used to customize the type of package created. Available options include: `library`, `system-module`, or `executable`. For example

```
$ swift package create MyLib --type library
```

Will create a library package with the the following directory structure

```
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

```
$ swift package create SysMod --type system-module
Creating system-module package: SysMod
Creating Package.swift
Creating module.modulemap
```


## User defined directory structure templates

By default, `swift package create` uses the following directory structure:

```
.
├── Package.swift
├── Sources
│   └── <Module>
│       └── <Module>.swift
└── Tests
    └──<Module>Tests
        └── <Module>Tests.swift
```

To support use cases in which individuals or corporates prefer a different directory structure that they can use consistently in their projects, the proposal includes a new configuration option named “templates”.

Templates are defined by adding a configuration file to SwiftPM’s configuration directory `~/.swiftpm/configuration/templates/new-package/<template-name>.json`

The template is a JSON file that guides SwiftPM on the directory structure when creating the new package. The configuration includes the following options: 

```json
{
  "directories": {
    "sources": "<path>" // location for sources
    "tests": "<path>" // location for tests, can be null for no tests
    "nestedModule": true/false // add a subdirectory for a module 
  }
  "type": "executable" | "library | ..." // the default package type
  "dependencies": [...] // array of default depedencies to include in Package.swift
}
```

Selecting a template to use while creating the new packages is done using the `--template` option, for example:

Given the template located in `~/.swiftpm/configuration/templates/new-package/my-template.json` with the following content: 

```json
{
  "directories": {
    "sources": "./src"
    "tests": "./test",
    "nestedModule": false
  }
  "type": "executable"
  "dependencies": [...]
}
```

Running the following command:

```
$ swift package create MyApp --template my-template
```

Will create an executable package with the the following directory structure:

```
.
├── Package.swift
├── src
│   └── MyApp.swift
└── test
    └──MyAppTests.swift
```


**Example 2**

```json
{
  "directories": {
    "sources": "./src"
    "tests": null,
    "nestedModule": false
  }
  "type": "executable"
  "dependencies": [...]
}
```

Will create the following directory structure: 

```
.
├── Package.swift
├── src
    └── <Module>.swift
```


**Example 3**

```json
{
  "directories": {
    "sources": "./src"
    "tests": null,
    "nestedModule": false
  }
  "type": "executable"
  "dependencies": [
     { url: "https://github.com/apple/swift-nio.git", version: "1.0.0" },
    { url: "https://github.com/apple/swift-crypto.git", version: "1.0.0" },
  ]
}
```

Will create the following `Package.swift`:

```swift
import PackageDescription

let package = Package(
    name: "MyApp",
    dependencies: [        
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            sources: "src",
            dependencies: []),
    ]
)
```

Note that target’s sources location maps to the directories/sources location specified in the template, this is a behavior `swift package create` will need to apply if/when they template defines a custom sources location.


**Defining the default template**

To customize the default template (i.e. when `swift package create` is invoked with the explicit `--template `argument), user should define a template named “default”, i.e.:

 `~/.swiftpm/configuration/templates/new-package/default.json`


**Impact on SwiftPM**

To support the template system, SwiftPM will define a new struct 

```swift
struct PackageTemplate {
  let sourcesDirectory: RelativePath
  let testsDirectory: RelativePath?
  let createSubDirectoryForModule: Bool
  let packageType: PackageType
  let dependencies: [PackageDependency]
}
```

This struct will be used to guide the creation / initialization of the package, instead of the hard coded structure used today (e.g. by `InitPackage` in the case of `swift package init)`

When processing `swift package create` or `swift package init`, SwiftPM will do the following

1. If a template is specified with `—template` option: try to load the template and decode it into `PackageTemplate` above, exiting with an error if such template was not found or ran into parsing error.
2. When no template is specified with `—template` option:
    1. Check if a default template is defined in `~/.swiftpm/configuration/templates/new-package/default.json. `If one is defined, use it as described in #1 above
    2. If no default template is defined, construct a default `PackageTemplate` based on the `--type` flag if one is passed or the default type when such is not passed.


## Changes to `swift package init`

 `swift package init` will be slightly updated to reflect it’s renewed focus on transforming sources to packages:

1. `swift package init` will no longer add a `README.md`, and .`gitignore` files, reducing its impact on the existing sources directory.
2. When `swift package init` is used in an empty directory, it will create a new package as it does today but emit a diagnostics message encouraging the user to use `swift package create` in the future, to help transition to the more appropriate command.
3. `swift package init` will accept the new `--template` option and apply it ad described above.


# Security

No impact.


# Impact on existing packages

No impact.


# Alternatives considered

The main alternative is to modify the behavior of `swift package init` such that it better caters to the creation of new packages from scratch. The advantage of this alternative is that it maintains the API surface area. The disadvantages are that any changes to make it better for package creation are likely to make it confusing for transforming existing sources to package. More importantly, changes to the existing command may cause impact on users that have automation tied to the current behavior. 

For templates, the main alternative is to have the template be a full package directory that is copied instead of a configuration driven. The advantage of such alternative is that it would allow more flexibility in what the template may include, with the disadvantage is that it is more complex to implement given that it would require a mechanism for dealing with the variation across the different package types.

# Future Iterations

In order to provide greater flexibility than what JSON can provide, a future version of SwiftPM could allow packages to be created in a procedural manner. SwiftPM could introduce new APIs that provide a toolbox of functionality for creating and configuration various aspects of packages, and could invoke Swift scripts that create new packages using those APIs. Such scripts could make decisions about what content to create based on input options or other external conditions. These APIs would also function when creating a Swift package from scratch, and or transforming existing sources into a Swift Package.