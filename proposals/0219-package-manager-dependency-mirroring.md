# Package Manager Dependency Mirroring

* Proposal: [SE-0219](0219-package-manager-dependency-mirroring.md)
* Authors: [Ankit Aggarwal](https://github.com/aciidb0mb3r)
* Review Manager: [Boris Bügling](https://github.com/neonichu)
* Status: **Implemented (Swift 5)**
* Implementation: [apple/swift-package-manager#1776](https://github.com/apple/swift-package-manager/pull/1776)
* Bug: [apple/swift-package-manager#4767](https://github.com/apple/swift-package-manager/issues/4767)

## Introduction

A dependency mirror refers to an alternate source location which exactly replicates the contents of the original source. This is a proposal for adding support for dependency mirroring in SwiftPM.

## Motivation

Dependency mirroring is useful for several reasons:

- **Availability**: Mirrors can ensure that a dependency can be always fetched, in case the original source is unavailable or even deleted.
- **Cache**: Access to the original source location could be slow or forbidden in the current environment.
- **Validation**: Mirrors can help with screening the upstream updates before making them available internally within a company.

## Proposed solution

We propose to introduce a "package configuration" file to store per-dependency mirroring information that SwiftPM can use as additional input.

We propose to allow registering a mirror using the following command:

```sh
$ swift package config set-mirror \
    --package-url <original URL> \
    --mirror-url <mirror URL>

# Example:

$ swift package config set-mirror \
    --package-url https://github.com/Core/libCore.git \
    --mirror-url https://mygithub.com/myOrg/libCore.git
```

A dependency's mirror URL will be used instead of its original URL to perform all relevant git operations, such as fetching and updating the dependency. It will be possible to mirror both direct and transitive dependencies of a package.

## Detailed design

### Package Configuration File

The package configuration file will be expected at this location:

    <package-root>/.swiftpm/config

Similar to the `Package.resolved` file, the configuration file of a dependency will not affect a top-level package.

This file will be managed through SwiftPM commands and users are not expected to edit it by hand. The format of this file is an implementation detail but it will be JSON in practice.

The configuration file can be expanded to add other information if it makes sense to add it there. Other tools and IDEs written on top of SwiftPM, can also use the `.swiftpm` directory to store their auxiliary files.

### Dependency Mirroring

In addition to the `set-mirror` command described above, SwiftPM will provide a command to unset mirror URLs:

```sh
$ swift package config unset-mirror \
    (--mirror-url | --package-url | --all) <url>

# Examples:

$ swift package config unset-mirror --package-url https://github.com/Core/libCore.git
$ swift package config unset-mirror --mirror-url https://mygithub.com/myOrg/libCore.git
$ swift package config unset-mirror --all
```

A dependency can have only one mirror URL at a time; `set-mirror` command will replace any previous mirror URL for that dependency.

SwiftPM will allow overriding the path of the configuration file using the environment variable `SWIFTPM_MIRROR_CONFIG`. This allows using mirrors on arbitrary packages that don't have a config file or require different configurations in different environments. Note that the file at this variable will override only the mirror configuration, if in future we have other configuration stored in the configuration file.

The `Package.resolved` file will contain the mirror URLs that were used during dependency resolution.

## Security

There is no security impact since mirrors only work for the top-level package, and dependencies can't add mirrors on downstream packages. There is a potential privacy concern in case someone accidentally commits their private mirror configuration file in a public package.

## Impact on existing packages

This is an additive feature and doesn't impact existing packages.

## Alternatives considered

We considered using a dedicated file for storing mirror information. However, there is no good reason to have a new file specifically for mirrors. A generic file gives us flexibility if we discover the need to store more configuration.

We considered adding a global configuration file for storing the mirror information. A global file could be convenient for some users, but it can also cause "gotcha" moments if the file is used when it shouldn't be used and vice versa. Users who understand this risk can export the `SWIFTPM_MIRROR_CONFIG` in their shell to achieve a similar effect.

We considered storing the mirroring information in the `Package.swift` manifest file but that doesn't fit well with several of the use-cases of mirrors. The manifest file is also fundamentally different from the configuration file. The manifest file defines how a package is configured and built, whereas the mirror configuration provides overrides for fetching the package dependencies. For e.g., different users would want to use different mirror files depending on their environment, or a user may want to use a mirror on a package they don't have permission to edit. 
