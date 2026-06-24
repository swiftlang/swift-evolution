# Add CLI for editing global mirrors configuration

* Proposal: [SE-NNNN](NNNN-global-mirrors-configuration-cli.md)
* Authors: [Samuel Murray](https://github.com/samuelmurray)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [swiftlang/swift-package-manager#9950](https://github.com/swiftlang/swift-package-manager/pull/9950)

## Introduction

SPM has support for both local (per-project) and shared (per-user) mirrors configuration, though the CLI only allows for editing the local configuration file. This proposal adds an optional `--global` flag to the existing CLI for editing the global configuration.

Swift-evolution thread: [Pitch: Add CLI to edit global configuration of mirrors](https://forums.swift.org/t/pitch-add-cli-to-edit-global-configuration-of-mirrors/86091)

## Motivation

Originally, mirrors could only be configured locally, per project, as described by the [original proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0219-package-manager-dependency-mirroring.md).
However, support for a global configuration file was added in a [later release](https://github.com/swiftlang/swift-package-manager/pull/3670), mirroring the design of package registries, which has supported local and global configuration since the start. Global configuration files for mirrors and package registries are especially useful in enterprise environments, where certain packages will always be accessed from a custom URL. The usefulness of global configuration is increased even further with the upcoming [support for mirroring of binary targets](https://github.com/swiftlang/swift-package-manager/pull/9647).

However, there is currently no easy way to edit and view the global mirrors configuration. The only option is to manually create and edit the configuration file. Providing a CLI for this aligns the feature with global package registries, while also increasing the discoverability of global mirrors configuration.

## Proposed solution

The CLI for interacting with the local configuration file is

* `swift package config set-mirror`
* `swift package config unset-mirror`
* `swift package config get-mirror`

This proposal adds an optional `--global` flag to each of these commands.

### Example

To add global configuration for a mirror of `https://example.com/file.json`:

```bash
$ swift package config set-mirror --global --original https://example.com/file.json --mirror https://internal.com/file.json
```

This adds the following to `~/.swiftpm/configuration/mirrors.json` (creating the file if it doesn't exist):

```json
{
  "object" : [
    {
      "mirror" : "https://internal.com/file.json",
      "original" : "https://example.com/file.json"
    }
    // ...
  ],
  "version" : 1
}
```

To view this configuration:

```bash
$ swift package config get-mirror --global --original https://example.com/file.json
https://internal.com/file.json
```

To unset the configuration:

```bash
$ swift package config unset-mirror --global --original https://example.com/file.json
```

Taking inspiration from the CLI for package registries, I suggest that we add a `--global` flag for each of these commands, e.g. `swift package config set-mirror --global [...]`. All of these commands, when used with this flag, will only consider the global configuration file. By using this flag, the command can be run in any directory, unlike the current (unflagged) command which fails if the current directory (or any of its parents) does not contain a Package.swift file.
The current behaviour of swift package config get-mirror is that if the local configuration files is empty, or doesn't exist, then the global configuration file is read. I propose to leave this behaviour unchanged. To me, it would make more sense if the local and global configuration was merged (with local having higher priority) rather than ignoring all global configuration if any local configuration exists. However, I think such a changed is somewhat unrelated, and could be made as a follow-up proposal to this one.

## Detailed design

All of the commands, when used with the `--global` flag, can be used in any directory. That is, the current directory (or any parent directories) is not required to contain a `Package.swift` file.

When used without the `--global` flag, the behaviour of all commands are unchanged.

### set-mirror

```bash
$ swift package config set-mirror --help
OVERVIEW: Set a mirror for a dependency.

USAGE: swift package config set-mirror [--global] [--original <original>] [--mirror <mirror>]

OPTIONS:
  --global                Apply settings to all projects for this user.
  --original <original>   The original url or identity.
  --mirror <mirror>       The mirror url or identity.
  --version               Show the version.
  -h, -help, --help       Show help information.
```

Running this command appends the mirror configuration to `~/.swiftpm/configuration/mirrors.json`, or create the file if it does not exist.

### unset-mirror

```bash
$ swift package config unset-mirror --help
OVERVIEW: Remove an existing mirror.

USAGE: swift package config unset-mirror [--original <original>] [--mirror <mirror>]

OPTIONS:
  --global                Apply settings to all projects for this user.
  --original <original>   The original url or identity.
  --mirror <mirror>       The mirror url or identity.
  --version               Show the version.
  -h, -help, --help       Show help information.
```

Running this command removes the matching mirror configuration from `~/.swiftpm/configuration/mirrors.json`. If no matching entry is found, or the file does not exist, display an error message.

### get-mirror

```bash
OVERVIEW: Print mirror configuration for the given package dependency.

USAGE: swift package config get-mirror [--original <original>]

OPTIONS:
  --global                Only read settings applied to all projects for this user.
  --original <original>   The original url or identity.
  --version               Show the version.
  -h, -help, --help       Show help information.
```

Running this command retrieves the matching mirror configuration from `~/.swiftpm/configuration/mirrors.json`. If no matching entry is found, or the file does not exist, display an error message.

## Security

This proposal has minimal impact on security. It modifies (or reads from) a file in the user's home directory. In the [original proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0219-package-manager-dependency-mirroring.md) for mirrors, it was argued that a global configuration risk causing "gotcha moments". However, since support for global mirrors configuration has since been added to SPM, adding this CLI introduces no new issues.

## Impact on existing packages

This proposal has no impact on existing packages. It only adds a new CLI flag; no existing behavior is changed.

## Alternatives considered

_None_