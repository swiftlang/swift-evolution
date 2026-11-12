# Auditing Package Dependencies for Known Vulnerabilities

* Proposal: [SE-NNNN](NNNN-swiftpm-package-audit.md)
* Authors: [Daiki Matsudate](https://github.com/d-date)
* Review Manager: TBD
* Status: **Awaiting review**
* Implementation: [swiftlang/swift-package-manager#10806](https://github.com/swiftlang/swift-package-manager/pull/10806)
* Review: ([pitch](https://forums.swift.org/t/pitch-auditing-package-dependencies-for-known-vulnerabilities/90686))

## Introduction

This proposal adds a `swift package audit` subcommand that checks the resolved
dependencies of a package against known security advisories, and a
`swift package audit fix` subcommand that upgrades vulnerable dependencies to
patched versions. Advisories are retrieved in the [OSV format][OSV] from an
OSV-compatible database (by default [osv.dev], which aggregates the
[GitHub Advisory Database][GHSA]) for source control dependencies, and from the
package registry for registry dependencies, through a new optional endpoint of
the [package registry API][SE-0292].

## Motivation

Security advisories for Swift packages already exist. The GitHub Advisory
Database publishes reviewed advisories for the Swift ecosystem, and the OSV
schema has defined a [`SwiftURL` ecosystem][OSV-SwiftURL] since 2023, so these
advisories are available in a vendor-neutral, machine-readable format.

However, there is no uniform way for a Swift developer to answer the question
*"Does my package depend on a version with a known vulnerability?"*:

* Dependabot alerts read `Package.resolved`, but only for repositories hosted
  on GitHub, only after the change has been pushed, and not on a developer's
  machine or in other CI systems.
* Third-party scanners each implement their own parsing of `Package.resolved`,
  their own mapping between SwiftPM package identities and advisory
  databases, and their own output formats.
* Developers of packages consumed through a [package registry][SE-0292] have no
  way to receive advisories from the registry at all.

Most other package ecosystems ship this capability in their package manager
(`npm audit`, `cargo audit`, `pip-audit`, `dotnet list package --vulnerable`),
which makes vulnerability checking a default part of the development and CI
workflow rather than an opt-in third-party integration.

SwiftPM has already taken steps in this direction.
[SE-0292][SE-0292] listed a `swift package audit` subcommand as a future
direction ("Security audits"), and [SE-0509] added SBOM generation with the
explicit motivation of "determining whether a dependency that's being used has
a vulnerability". This proposal provides that determination directly.

## Proposed solution

Add two subcommands:

```console
$ swift package audit
High      GHSA-xxxx-xxxx-xxxx (CVE-2026-12345)
          Regular expression denial of service in RegEx
Package   https://github.com/example/RegEx 1.4.2
Path      MyApp > PatternMatcher > RegEx
Fixed in  1.4.3
Fix       Run `swift package audit fix` (within current requirements)
More info https://osv.dev/vulnerability/GHSA-xxxx-xxxx-xxxx

Moderate  GHSA-yyyy-yyyy-yyyy
          Improper certificate validation in NetKit
Package   mona.NetKit 2.8.0 (registry)
Path      MyApp > NetKit
Fixed in  3.0.0
Fix       Requires changing the requirement in Package.swift (major version)
More info https://registry.example.com/advisories/yyyy

Found 2 vulnerabilities (1 moderate, 1 high) in 14 scanned packages.
1 package could not be checked; run with --verbose for details.
```

```console
$ swift package audit fix --dry-run
Would update https://github.com/example/RegEx 1.4.2 -> 1.4.3 (Package.resolved)
Cannot fix mona.NetKit 2.8.0: the patched version 3.0.0 is outside the
  requirement in Package.swift; re-run with --allow-manifest-changes
  --allow-major-upgrades to update it.
```

The commands read the resolved dependency graph, look up advisories for each
resolved package version, and report findings with enough information to act
on them: severity, identifiers and aliases, the dependency path, the patched
versions, and whether updating within the current requirements is sufficient.

## Detailed design

### Input

`swift package audit` operates on the resolved package graph of the root
package, i.e. the pins in `Package.resolved`. If dependencies have not been
resolved yet, the command resolves them first, as other `swift package`
subcommands do. It does not build anything.

The graph is loaded with all traits enabled (as with `--enable-all-traits`), and
platform conditions are not evaluated, so packages that are only reachable in
another configuration are audited too: a vulnerability may affect a
configuration other than the one used locally. Dependency paths and
requirements are taken from this graph.

Auditing never changes an existing `Package.resolved`. A dependency that is
only reachable through a trait that is not enabled is therefore audited only
if it is already pinned (for example after
`swift package resolve --enable-all-traits`). Otherwise the command audits the
graph for the enabled traits and prints a warning that such dependencies were
not audited.

Each pin is classified by how it was resolved:

| Pin kind | Audited via |
| --- | --- |
| Source control, version-based | OSV-compatible database (`SwiftURL` ecosystem) |
| Registry (`scope.name`) | The registry that provided it, and the OSV-compatible database through its repository URLs |
| Source control, branch- or revision-based | OSV-compatible database by commit, when supported; otherwise reported as *unchecked* |
| Local (path) dependency | Not audited; reported as *unchecked* |

### Advisory sources

All advisories are represented in the [OSV schema][OSV] regardless of their
source. This gives the command a single data model for version ranges,
severity, identifiers and aliases.

#### OSV-compatible database

For source control dependencies, SwiftPM queries an OSV-compatible API using the
`SwiftURL` ecosystem. The package name is the dependency's URL normalized in the
same way the GitHub Advisory Database names Swift packages: the scheme, any
user information, and a trailing `.git` are removed (for example,
`https://github.com/apple/swift-nio.git` becomes `github.com/apple/swift-nio`).

Records in public databases do not use this name consistently: some
GHSA-derived `SwiftURL` records name the package by its bare repository name
(for example `swift-nio-http2` rather than `github.com/apple/swift-nio-http2`).
To find those records, SwiftPM also queries the bare repository name for each
version-pinned dependency. Because that name is not unique across hosts and
owners, a record found this way is only reported when one of its `references`
points into the dependency's repository (for example
`https://github.com/apple/swift-nio-http2/security/advisories/...`); otherwise
it is assumed to describe a different package with the same name. Commit
queries match by commit and do not need the bare name.

The default database is `https://api.osv.dev`. It can be changed with
`--advisory-database <url>`, which accepts:

* an `https` URL of a server implementing the [OSV API][OSV-API]
  (`POST /v1/querybatch` and `GET /v1/vulns/{id}`), such as an internal mirror;
* a `file` URL of a local directory or ZIP archive of OSV records, such as the
  [ecosystem export][OSV-export] published by osv.dev, for offline use. In this
  case SwiftPM evaluates the `SEMVER` ranges and explicit `versions` of the
  records itself. `GIT` ranges require commit ancestry and are only evaluated
  by a server, so branch- and revision-based pins are reported as *unchecked*
  when a local database is used.

The setting can also be persisted with `swift package config`, at the package or
user level, in the same way as registry configuration.

#### Package registry

For registry dependencies, SwiftPM queries the registry that the package was
resolved from, using a new optional endpoint added to the
[registry service specification][Registry.md]:

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/{scope}/{name}/advisories{?version}` | List security advisories for a package |

The request uses the same `Accept: application/vnd.swift.registry.v1+json`
header, authentication, and error format as the other registry endpoints. A
successful response has the following body:

```jsonc
{
  "advisories": [
    {
      // An OSV record.
      "id": "GHSA-yyyy-yyyy-yyyy",
      "aliases": ["CVE-2026-23456"],
      "summary": "Improper certificate validation in NetKit",
      "affected": [{
        "ranges": [{
          "type": "SEMVER",
          "events": [{ "introduced": "0" }, { "fixed": "3.0.0" }]
        }]
      }],
      "severity": [{ "type": "CVSS_V3", "score": "CVSS:3.1/AV:N/..." }],
      "references": [{ "type": "ADVISORY", "url": "https://..." }]
    }
  ]
}
```

Because the endpoint is already scoped to one package, the client does not
require `affected[].package` to be present in records returned by a registry,
and evaluates only the `ranges` and `versions` fields. When the `version` query
parameter is given, the registry may return only the advisories that affect
that version.

A registry that does not implement the endpoint responds with `404 Not Found`
or `501 Not Implemented`. Because the path has the same shape as
`/{scope}/{name}/{version}`, an existing registry may instead reject
`advisories` as an invalid version with `400 Bad Request` or
`405 Method Not Allowed`; clients treat these responses the same way. In that case the package is not silently treated as
safe; it is checked through the OSV-compatible database (see below) and, if that
is not possible either, it is reported as *unchecked*.

Advisories are authored and maintained by the registry operator. SwiftPM only
consumes them; this proposal does not define how a registry obtains them.

#### Combining sources

For a registry dependency, SwiftPM also obtains the `repositoryURLs` from the
release metadata ([SE-0391]) and queries the OSV-compatible database with them,
so that advisories published upstream are found even when the registry does not
provide advisories.

Findings from all sources are merged. Two advisories are considered the same
if their `id`s match or one appears in the other's `aliases`; the record from
the registry takes precedence when they differ. Registry advisories can be
disabled with `--no-registry-advisories`, and OSV database queries with
`--no-advisory-database`; disabling both is an error.

### Severity

Each advisory is assigned one of `low`, `moderate`, `high`, `critical`, or
`unknown`:

1. If `database_specific.severity` is one of the four levels
   (case-insensitively, treating `medium` as `moderate`), it is used. The GitHub
   Advisory Database provides this field for every reviewed advisory.
2. Otherwise, if the record has a `CVSS_V3` `severity` entry, its base score is
   computed from the vector and mapped using the CVSS qualitative scale
   (0.1–3.9 low, 4.0–6.9 moderate, 7.0–8.9 high, 9.0–10.0 critical).
3. Otherwise the severity is `unknown`.

Computing CVSS v4 scores requires a large lookup table and is left as a future
improvement; records that only carry a CVSS v4 vector and no
`database_specific.severity` are treated as `unknown`.

### `swift package audit`

```
USAGE: swift package audit [<options>]

OPTIONS:
  --severity-threshold <low|moderate|high|critical>
                          Lowest severity that causes a failing exit status
                          (default: low).
  --format <text|json>    Output format (default: text).
  --ignore <id>           Ignore an advisory by ID or alias. Can be repeated.
  --fail-on-unchecked     Fail if any package could not be checked.
  --advisory-database <url>
                          OSV-compatible database to query.
  --no-advisory-database  Do not query an OSV-compatible database.
  --no-registry-advisories
                          Do not query package registries for advisories.
```

For each finding, the text output shows the severity, the advisory ID and its
CVE and GHSA aliases (the JSON output contains all aliases), the summary, the package identity and resolved version, every
dependency path from the root package to the vulnerable package, the patched
versions, a link to the advisory, and a *fix classification*:

* **update**: updating the package within the current requirements, as
  `swift package update <package>` would, yields a non-vulnerable version, so
  `swift package audit fix` (or `swift package update`) is sufficient. This is
  determined by running the dependency resolver in dry-run mode, not by
  comparing requirements statically, so the classification and the result of
  `fix` always agree.
* **manifest**: the package is a direct dependency and a patched version exists,
  but outside the requirement declared in the root `Package.swift`.
* **upstream**: a patched version exists, but it is excluded by the requirement
  of an intermediate dependency. The output names that dependency.
* **none**: no patched version is known.

For a branch- or revision-based pin, the patched versions of the advisory are
still reported; such a finding is classified as **manifest** for a direct
dependency (it needs a version-based requirement) and **upstream** otherwise.

Determining the classification runs the dependency resolver, so, like
`swift package update --dry-run`, it may fetch from the dependencies'
repositories or registries. If that is not possible (for example, offline),
the classification is omitted and a warning is printed; the findings and the
exit status are unaffected, so `swift package audit` with a local
`--advisory-database` remains usable in air-gapped environments.

#### Exit status

| Status | Meaning |
| --- | --- |
| 0 | No findings at or above the threshold, and (with `--fail-on-unchecked`) every package was checked |
| 1 | The command failed, for example because of a network error or an invalid configuration (SwiftPM's usual failure status) |
| 2 | Findings at or above the threshold, or unchecked packages with `--fail-on-unchecked` |

Invalid command-line arguments exit with the usual usage-error status, as for
every other `swift package` subcommand.

Advisories with `unknown` severity count as meeting any threshold, so that a
missing severity never hides a finding. Ignored advisories never affect the
exit status.

#### JSON output

With `--format json`, the command writes a single JSON object to standard
output:

```jsonc
{
  "version": 1,
  "scannedPackages": 14,
  "findings": [{
    "package": { "identity": "regex", "location": "https://github.com/example/RegEx", "kind": "remoteSourceControl", "version": "1.4.2" },
    "advisory": { /* the OSV record */ },
    "severity": "high",
    "sources": ["https://api.osv.dev"],
    "paths": [["MyApp", "PatternMatcher", "RegEx"]],
    "fixClassification": "update",
    "fixedVersions": ["1.4.3"],
    "ignored": false
  }],
  "unchecked": [{
    "package": { "identity": "localkit", "location": "../LocalKit", "kind": "fileSystem" },
    "reason": "local dependency"
  }]
}
```

The `version` field allows the format to evolve compatibly.

### `swift package audit fix`

```
USAGE: swift package audit fix [<options>]

OPTIONS:
  --dry-run               Show the planned changes without applying them.
  --allow-manifest-changes
                          Allow changing dependency requirements in the root
                          Package.swift.
  --allow-major-upgrades  With --allow-manifest-changes, allow requirement
                          changes that cross a major version.
  (all options of `swift package audit`)
```

The command first performs an audit, then handles each finding at or above the
threshold according to its fix classification:

1. **update**: the vulnerable packages are updated within their current
   requirements, with the same semantics as `swift package update <package>`:
   each is moved to the newest version the requirements allow, and other pins
   move only when the resolver requires it. Only `Package.resolved` changes.
2. **manifest**: only with `--allow-manifest-changes`, the requirement in the
   root `Package.swift` is changed so that its lower bound is the lowest patched
   version, keeping the kind of requirement (`from:`, `.upToNextMinor(from:)`,
   `exact:`, or a range). The manifest is edited with the same syntax-based
   machinery as the [package editing commands][SE-0301]. If the change crosses a
   major version, `--allow-major-upgrades` is also required. If the requirement
   cannot be edited safely (for example, it is computed rather than written as a
   literal), the finding is reported and left unchanged.
3. **upstream** and **none**: nothing is changed; the command explains what
   blocks the fix.

After applying changes, the command re-resolves the graph and audits it again.
It reports the changes made and the remaining findings, and its exit status
follows the same rules as `swift package audit`, based on the remaining
findings. A resolution failure leaves `Package.resolved` and `Package.swift`
unchanged.

With `--dry-run`, nothing is written and the planned changes are printed.

## Security

This feature exists to improve the security of Swift packages, but it has
several implications of its own.

* **Information disclosure.** Auditing sends the URLs (or registry identifiers)
  and versions of dependencies to the advisory sources. For private
  dependencies, this can reveal their names and repository locations to a third
  party. SwiftPM never contacts an advisory source except when one of the
  `audit` subcommands is run explicitly; the default database is documented;
  and organizations can use `--advisory-database` with an internal mirror or a
  local file to keep this information in-house. Registry queries go only to the
  registry that already serves the package, with its configured credentials.
* **Trust in advisory data.** A malicious or compromised advisory source can
  cause false negatives (hiding a vulnerability) or false positives. The
  sources are queried over HTTPS only (except `file` URLs). `audit fix` can
  only change versions within the requirements already declared, unless the
  user explicitly passes `--allow-manifest-changes`, and it never adds new
  dependencies.
* **False sense of security.** A clean audit means only that no *known*
  advisory matched. The output reports *unchecked* packages instead of
  omitting them, so users can tell which packages were not covered.

## Impact on existing packages

None. The subcommands are new, do not change the behavior of any existing
command, and do not depend on the tools version of the manifest. The new
registry endpoint is optional; existing registries remain conforming.

## Alternatives considered

### Only supporting OSV databases

Registry dependencies could be audited only through their `repositoryURLs`.
However, a registry may host packages that have no public repository, and a
registry operator (for example, within a company) is in the best position to
publish advisories for the packages it serves. SE-0292 already anticipated the
registry as an advisory source.

### Only supporting registries

Most Swift packages today are consumed from source control, and the existing
Swift advisories are published in OSV-compatible databases. A registry-only
design would cover very few real dependencies.

### A registry-specific advisory format

SE-0292 sketched a custom `advisories` format. Using OSV instead lets a single
data model serve both kinds of sources, lets registry operators reuse existing
tooling, and avoids defining yet another advisory schema.

### Checking advisories during `swift package resolve` or `update`

Warning automatically whenever dependencies are resolved would surface problems
earlier, but it would make every resolution depend on network access to an
additional service and send dependency information to it implicitly. An
explicit command keeps that behavior opt-in. Integration into resolution can
be revisited as a future direction.

### Auditing an SBOM instead of the package graph

The command could consume a CycloneDX or SPDX SBOM produced by [SE-0509]. Using
the package graph directly avoids requiring a build, and the fix
classification needs the dependency requirements, which SBOMs do not record.

### Naming

SwiftPM already has an `experimental-audit-binary-artifact` subcommand, which
checks a static library artifact for undefined symbols. That command audits the
*contents* of a single artifact, whereas `audit` audits the *dependency graph*
against security advisories. The name `audit` follows SE-0292 and the
established meaning in other package managers (`npm audit`, `cargo audit`).

## Future directions

* **Shared ignore configuration.** A file checked into the package that records
  ignored advisories with a reason and an expiry date, so that a team shares
  the same decisions in local and CI runs.
* **SARIF output** for integration with code scanning services.
* **Per-product auditing** that reuses the product-level dependency analysis
  of SE-0509 to audit only what a given product links.
* **Auditing Xcode projects** by accepting the path of a `Package.resolved`
  file that is not next to a `Package.swift`.
* **Advisory warnings during resolution**, opt-in through configuration.
* **An OSV ecosystem for registry identifiers**, so that advisories for
  registry packages can also be published to and queried from OSV databases
  by their `scope.name` identity.

## Open questions

* Should the default advisory database be `osv.dev`, or should SwiftPM require
  the user to configure a database before the first run?
* Should advisories for registry packages be published in OSV databases under
  a new ecosystem (for example `SwiftRegistry`), and if so, should this
  proposal define it?
* Is a dedicated exit status for findings (2) preferable to reusing SwiftPM's
  general failure status (1)?

[OSV]: https://ossf.github.io/osv-schema/
[OSV-SwiftURL]: https://github.com/ossf/osv-schema/pull/188
[OSV-API]: https://google.github.io/osv.dev/api/
[OSV-export]: https://google.github.io/osv.dev/data/#data-dumps
[osv.dev]: https://osv.dev
[GHSA]: https://github.com/advisories
[SE-0292]: 0292-package-registry-service.md
[SE-0301]: 0301-package-editing-commands.md
[SE-0391]: 0391-package-registry-publish.md
[SE-0509]: 0509-swift-sboms-via-swiftpm.md
[Registry.md]: https://github.com/swiftlang/swift-package-manager/blob/main/Documentation/PackageRegistry/Registry.md
