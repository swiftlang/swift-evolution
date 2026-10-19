# Merge local and global mirror configuration

* Proposal: [SE-NNNN](NNNN-merge-local-and-global-mirror-configuration.md)
* Authors: [Samuel Murray](https://github.com/samuelmurray)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

SPM has support for both local (per-project) and global (per-user) mirror configuration. However, any global configuration is ignored when a local configuration is present. With this proposal, the configuration is instead merged, so that both local and global configuration can be used for the same project.

Swift-evolution thread: [Discussion thread topic for that
proposal](https://forums.swift.org/)

## Motivation

Originally, mirrors could only be configured locally, per project, as described by the [original proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0219-package-manager-dependency-mirroring.md).
However, support for a global configuration file was added in a [later release](https://github.com/swiftlang/swift-package-manager/pull/3670), mirroring the design of package registries, which has supported local and global configuration since the start.
Global configuration files for mirrors and package registries are especially useful in enterprise environments, where certain packages will always be accessed from a custom URL. The usefulness of global configuration is increased even further with the [support for mirroring of binary targets](https://github.com/swiftlang/swift-package-manager/pull/9647).

However, the implementation of how the configuration for mirrors and packages registries is read differs. For package registries, if both local and global configuration is used, the result is a merged configuration, with the local configuration taking higher precedence in case of a conflict. For mirrors, on the other hand, the global configuration is ignored, and _only_ the local configuration is used. 

This causes issues in environment that want to have "global" mirror configuration, as well as "per-project" configuration. For example, you might have a global configuration with a lot of entries that is decided on by your organization, and want to temporarily use a local configuration to add or change one entry. Currently, you would need to either copy all of the global configuration to the local, or change the global one. The former is cumbersome and error-prone; the latter might not be an option since it would affect all other projects on the same machine, for that user.

Lastly, the current situation is somewhat confusing, with mirror and package registry configuration behaving differently. This is especially true when they are used in tandem, e.g. using a package registry for an SPM package, and a mirror for one of its binary targets.

## Proposed solution

This proposal changes the behavior so that _both_ local and global mirror configuration can be used, with local configuration taking precedence if both have entries for the same URL.

### Example

Content of local configuration:
```json
{
  "object": [
    {
      "mirror": "https://internal.com/file1.json",
      "original": "https://example.com/file1.json"
    },
    {
      "mirror": "https://internal.com/file2-override.json",
      "original": "https://example.com/file2.json"
    }
  ],
  "version": 1
}
```

Content of global configuration:
```json
{
  "object": [
    {
      "mirror": "https://internal.com/file2.json",
      "original": "https://example.com/file2.json"
    },
    {
      "mirror": "https://internal.com/file3.json",
      "original": "https://example.com/file3.json"
    }
  ],
  "version": 1
}
```

In this example, `https://example.com/file1.json` is mirrored to `https://internal.com/file1.json`, as it only exists in the local configuration.
`https://example.com/file2.json` exists in both the local and global configuration, and is mirrored to `https://internal.com/file2-override.json`, as the local configuration takes precedence.
`https://example.com/file3.json` exists only in the global configuration, and is mirrored to `https://internal.com/file3.json`.

## Detailed design

Commands that read the mirror configuration are changed to use both the local and global configurations, combining them into a _merged_ configuration. We say that entries from the local and global configuration _conflict_ if they both have the same `"original"` URL. For entries that do not conflict, (i.e. the `"original"` URL only exists in either the local or global configuration), that entry is included in the _merged_ configuration. For entries that do conflict, the one from the local configuration is used.
Note that two entries that have the same `"mirror"` URL do not conflict (unless they also have the same `"original"` URL).

This affects commands that download dependencies (e.g. `swift package resolve`), and commands for viewing the current mirror configuration (`swift package config get-mirror`).

In situations where only one of the configurations exists, or when explicitly using only the global configuration (e.g. `swift package config get-mirror --global`), the behavior is unchanged.

## Security

This proposal has minimal impact on security. If building a project on a shared/untrusted machine, the global configuration could be seen as a way to inject malicious configuration. However, since the global configuration is only ignored if there is a non-empty local configuration, this change in itself does not introduce the potential issue. Prevention of such attacks should rather be done with checksums, as in `Package.resolved` and `.binaryTarget`.

## Impact on existing packages

This proposal changes the behavior for any developer that currently uses both local and global configuration. It could break builds where a local configuration is explicitly used to ignore the content of a global configuration. However, this does not seem like an intended usage of local and global configuration - if this is a legitimate use-case it would be better to add some other mechanism to ignore the global configuration.

## Alternatives considered

_None_
