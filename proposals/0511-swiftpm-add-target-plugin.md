# SwiftPM Add Target Plugin Command

* Proposal: [SE-0511](0511-swiftpm-add-target-plugin.md)
* Authors: [Gage Halverson](https://github.com/hi2gage)
* Review Manager: [Mikaela Caron](https://github.com/mikaelacaron)
* Status: **Active Review (February 05...February 19, 2026)**
* Bug: [swiftlang/swift-package-manager#8169](https://github.com/swiftlang/swift-package-manager/issues/8169)
* Implementation: [swiftlang/swift-package-manager#8432](https://github.com/swiftlang/swift-package-manager/pull/8432)
* Review: ([Pitch](https://forums.swift.org/t/proposal-swift-package-add-target-plugin-command-to-swiftpm/77930)), ([Review](https://forums.swift.org/t/se-0511-swiftpm-add-target-plugin-command/84587))

## Introduction

This proposal introduces a new `swift package add-target-plugin` command that allows developers to add plugin usages to existing targets in their `Package.swift` manifest directly from the command line.

This builds upon the package editing commands introduced in [SE-0301](0301-package-editing-commands.md).

Swift-evolution thread: [Pitch: swift package add-target-plugin Command to SwiftPM](https://forums.swift.org/t/proposal-swift-package-add-target-plugin-command-to-swiftpm/77930)

## Motivation

SwiftPM already provides several commands for programmatically editing `Package.swift` manifests:

- `swift package add-dependency` - Add a package dependency
- `swift package add-target` - Add a new target
- `swift package add-target-dependency` - Add a dependency to a target
- `swift package add-product` - Add a new product

However, there is currently no command to add a plugin usage to an existing target. Developers must manually edit their `Package.swift` file to add plugins, which can be error-prone and requires knowledge of the exact syntax.

Build tool plugins like [swift-openapi-generator](https://github.com/apple/swift-openapi-generator) are becoming increasingly common in the Swift ecosystem. Providing a CLI command to add these plugins aligns with SwiftPM's goal of offering a complete set of manifest editing commands.

## Proposed solution

Add a new `swift package add-target-plugin` command that modifies the `Package.swift` manifest to add a plugin usage to an existing target.

### Usage

```
swift package add-target-plugin <plugin-name> <target-name> [--package <package>]
```

### Example

To add the OpenAPIGenerator plugin from swift-openapi-generator to a target named `MyTarget`:

```bash
swift package add-target-plugin OpenAPIGenerator MyTarget --package swift-openapi-generator
```

This will modify the manifest to include:

```swift
.target(
    name: "MyTarget",
    dependencies: [...],
    plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
    ]
)
```

For plugins defined within the same package (internal plugins), omit the `--package` option:

```bash
swift package add-target-plugin MyPlugin MyTarget
```

## Detailed design

### Command-line interface

```bash
$ swift package add-target-plugin --help
OVERVIEW: Add a plugin to an existing target in the manifest

USAGE: swift package add-target-plugin <plugin-name> <target-name> [--package <package>]

ARGUMENTS:
  <plugin-name>           The name of the new plugin
  <target-name>           The name of the target to update

OPTIONS:
  --package <package>     The package in which the plugin resides
  --version               Show the version.
  -h, -help, --help       Show help information.
```

### Behavior

1. **Validation**: The command validates that the specified target exists in the manifest.

2. **Idempotency**: If the plugin is already present in the target's plugins array, the command succeeds without making duplicate entries.

3. **Manifest modification**: The command parses and modifies the `Package.swift` file, preserving existing formatting and comments where possible.

4. **Output**: By default, the command prints the modifications made. Use `--quiet` to suppress output.

### Error handling

The command will fail with an appropriate error message if:
- The specified target does not exist in the manifest
- The `Package.swift` file cannot be found or parsed
- The manifest cannot be written

## Security

This proposal has minimal impact on the security of the package manager. Build tool plugins execute code during the build process, which carries inherent risk. However, this is no different than if the user manually edited the manifest to add the plugin.

## Impact on existing packages

This proposal has no impact on existing packages. It only adds a new command; no existing behavior is changed.

## Alternatives considered

### Extending `swift package add-target --type plugin`

One alternative considered was extending the existing `add-target` command with a `--type plugin` option. However, this conflates two different operations:

- `add-target` creates a new target definition
- `add-target-plugin` adds a plugin *usage* to an existing target

These are semantically different operations. The proposed approach is consistent with the existing `add-target-dependency` command, which similarly adds an item to an existing target rather than creating a new target.

### Adding plugins via `add-target-dependency`

Another option would be to extend `add-target-dependency` to handle plugins. However, dependencies and plugins serve different purposes and have different syntax in the manifest. Keeping them as separate commands maintains clarity.

