# Package Registry Service

* Proposal: [SE-0292](0292-package-registry-service.md)
* Authors: [Bryan Clark](https://github.com/clarkbw),
           [Whitney Imura](https://github.com/whitneyimura),
           [Mattt Zmuda](https://github.com/mattt)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Status: **Active review (December 8...December 17)**
* Implementation: [apple/swift-package-manager#3023](https://github.com/apple/swift-package-manager/pull/3023)
* Review: [Review](https://forums.swift.org/t/se-0292-package-registry-service/)

## Introduction

Swift Package Manager downloads dependencies using Git.
Our proposal defines a standard web service interface
that it can also use to download dependencies from package registries.

## Motivation

A package dependency is specified by a URL for its source repository.
When a project is built for the first time,
Swift Package Manager clones the Git repository for each dependency
and attempts to resolve the version requirements from the available tags.

Although Git is a capable version-control system,
it's not well-suited to this kind of workflow for the following reasons:

* **Reproducibility**:
  A version tag in the Git repository for a dependency
  can be reassigned to another commit at any time.
  This can cause the same source code to produce different build results
  depending on when it was built.
* **Availability**:
  The Git repository for a dependency can be moved or deleted,
  which can cause subsequent builds to fail.
* **Efficiency**:
  Cloning the Git repository for a dependency
  downloads all versions of a package when only one is used at a time.
* **Speed**:
  Cloning a Git repository for a dependency can be slow
  for repositories with large histories.

Many language ecosystems have a <dfn>package registry</dfn>, including
[RubyGems] for Ruby,
[PyPI] for Python,
[npm] for JavaScript, and
[crates.io] for Rust.
In fact,
many Swift developers develop apps today using
[CocoaPods] and its index of libraries.

A package registry can offer faster and more reliable dependency resolution
than downloading dependencies using Git.
It can also support other useful functionality,
such as:

* **Advisories**:
  Vulnerabilities can be communicated directly to package consumers
  in a timely manner.
* **Discoverability**
  Package maintainers can annotate their releases with project metadata,
  including its authors, license, and other information.
* **Search**
  A registry can provide a standard interface for searching available packages,
  or provide the information necessary for others to create a search index.
* **Flexibility**
  Swift Package Manager requires an external dependency to be
  hosted in a Git repository with a package manifest located in its root,
  which may be a barrier to adoption for some projects.
  A package registry imposes no requirements on
  version control software or project structure.

## Proposed solution

This proposal defines a standard interface for package registry services
and describes how Swift Package Manager can integrate with them
to download dependencies.

The goal of this proposal is to make dependency resolution
more available and reproducible.
We believe our proposed solution
can meet or exceed the current performance of dependency resolution
and will allow for new functionality to be built in the future.

## Detailed design

### Package registry service

A package registry service implements REST API endpoints
for listing releases for a package,
fetching information about a release,
and downloading the source archive for a release.

| Method | Path                                                 | Description                                      |
| ------ | ---------------------------------------------------- | ------------------------------------------------ |
| `GET`  | `/{package}`                                         | List package releases                            |
| `GET`  | `/{package}/{version}`                               | Fetch metadata for a package release             |
| `GET`  | `/{package}/{version}/Package.swift{?swift-version}` | Fetch manifest for a package release             |
| `GET`  | `/{package}/{version}.zip`                           | Download source archive for a package release    |

A formal specification for the package registry interface
is provided alongside this proposal.
In addition,
an OpenAPI (v3) document,
a reference implementation written in Swift,
and a benchmarking harness
are provided for the convenience of developers interested
in building their own package registry.

### Changes to Swift Package Manager

#### Package identity

Currently, the identity of a package is computed from
the last path component of its effective URL
(which can be changed with dependency mirroring and forking).
However, this approach can lead to conflation of
distinct packages with similar names
as well as duplication of the same package under different names.

We propose to instead use a normalized form of
a package dependency's declared location
as that package's canonical identity.
Not only would this resolve the aforementioned naming ambiguities,
but it would allow for package registries to be adopted by package consumers
with minimal changes to their code.

For the purposes of package resolution,
package identities are
case-insensitive
(for example, `mona` ≍ `MONA`)
and normalization-insensitive
(for example, `n` + `◌̃` ≍ `ñ`).
In addition,
the following operations are performed
to mitigate insignificant variations in how
a dependency may be declared in a package manifest:

* Removing the scheme component, if present:
  ```
  https:///example.com/mona/LinkedList → example.com/mona/LinkedList
  ```
* Removing the userinfo component (preceded by `@`), if present:
  ```
  git@example.com/mona/LinkedList → example.com/mona/LinkedList
  ```
* Removing the port subcomponent, if present:
  ```
  example.com:443/mona/LinkedList → example.com/mona/LinkedList
  ```
* Replacing the colon (`:`) preceding the path component in "`scp`-style" URLs:
  ```
  git@example.com:mona/LinkedList.git → example.com/mona/LinkedList
  ```
* Expanding the tilde (`~`) to the provided user, if applicable:
  ```
  ssh://mona@example.com/~/LinkedList.git → example.com/~mona/LinkedList
  ```
* Removing percent-encoding from the path component, if applicable:
  ```
  example.com/mona/%F0%9F%94%97List → example.com/mona/🔗List
  ```
* Removing the `.git` file extension from the path component, if present:
  ```
  example.com/mona/LinkedList.git → example.com/mona/LinkedList
  ```
* Removing the trailing slash (`/`) in the path component, if present:
  ```
  example.com/mona/LinkedList/ → example.com/mona/LinkedList
  ```
* Removing the fragment component (preceded by `#`), if present:
  ```
  example.com/mona/LinkedList#installation → example.com/mona/LinkedList
  ```
* Removing the query component (preceded by `?`), if present:
  ```
  example.com/mona/LinkedList?utm_source=forums.swift.org → example.com/mona/LinkedList
  ```
* Adding a leading slash (`/`) for `file://` URLs and absolute file paths:
  ```
  file:///Users/mona/LinkedList → /Users/mona/LinkedList
  ```

For example,
consider a package that declares two external dependencies.
The first external dependency itself has a dependency on a package at the URL
`https:///example.com/mona/LinkedList`.
The second depends on the same package,
but specifies a slightly different URL in its declaration:
`git@example.com:mona/linkedlist.git`.
Under the proposed scheme,
both transitive dependencies resolve to the same package,
identified with the URI `example.com/mona/linkedlist`.

#### Dependency graph resolution

In its `PackageGraph` module, Swift Package Manager defines
the `PackageContainer` protocol as the top-level unit of package resolution.
Conforming types are responsible for
determining the available tags for a package
and its contents at a particular revision.
A `PackageContainerProvider` protocol adds a level of indirection
for resolving package containers.

There are currently two concrete implementations of `PackageContainer`:
`LocalPackageContainer` and `RepositoryPackageContainer`.
This proposal adds a new `RegistryPackageContainer` type
that adopts `PackageContainer`
and performs equivalent operations with HTTP requests to a registry service.
These client-server interactions are facilitated by
a new `RegistryManager` type.

This proposal also adds a new `CompositeRepositoryProvider` type
that conforms to `RepositoryPackageContainerProvider`
and attempts to use the package registry interface when available
for qualifying remote packages.

The following table lists the
tasks performed by Swift Package Manager during dependency resolution
alongside the Git operations used
and their corresponding package registry API calls.

| Task                                  | Git operation               | Registry request                         |
| ------------------------------------- | --------------------------- | ---------------------------------------- |
| Fetch the contents of a package       | `git clone && git checkout` | `GET /{package}/{version}.zip`           |
| List the available tags for a package | `git tag`                   | `GET /{package}`                         |
| Fetch a package manifest              | `git clone`                 | `GET /{package}/{version}/Package.swift` |

A dependency qualifies for resolution through a package registry
if it satisfies all of the following criteria:

* The package has a url with an `https` scheme.
* The last path component of the package url has no file extension.
* The dependency specifies an exact version or range of versions.

For example,
here are a list of dependencies that do and do not qualify:

```swift
// ✅ These dependencies qualify for resolution with package registry
.package(url: "https://example.com/mona/LinkedList", from: "1.1.0")
.package(url: "https://example.com/mona/LinkedList", .exact("1.1.0"))
.package(url: "https://example.com/mona/LinkedList", .upToNextMajor(from: "1.1.0"))
.package(url: "https://example.com/mona/LinkedList", .upToNextMinor(from: "1.1.0"))

// ❌ These dependencies can only be resolved using Git
.package(url: "git@example.com:mona/LinkedList.git", from: "1.1.0") // No https scheme
.package(url: "https://example.com/mona/LinkedList.git", from: "1.1.0") // .git file extension
.package(url: "https://example.com/mona/LinkedList", .branch("master")) // No version
.package(url: "https://example.com/mona/LinkedList", .revision("d6ca4e56219a8a5f0237d6dcdd8b975ec7e24c89")) // No version
.package(path: "../LinkedList") // No https scheme or version
```

Package registries support
[version-specific _manifest_ selection][version-specific-manifest-selection]
by providing a list of versioned manifest files for a package
(for example, `Package@swift-5.3.swift`)
in its response to `GET /{package}/{version}/Package.swift`.
However, package registries won't support
[version-specific _tag_ selection][version-specific-tag-selection],
and instead rely on [Semantic Versioning][SemVer]
to accommodate different versions of Swift
(for example,
by using major release versions
or build metadata like `1.0.0+swift-5_3`).

#### Command-line interface

Initially,
Swift Package Manager will use a package registry to resolve dependencies
only when the user passes the `--enable-package-registries` command-line flag.

```terminal
$ swift build --enable-package-registries
```

When package registries are enabled,
Swift Package Manager will first attempt to use package registry API calls
to resolve qualifying dependencies,
falling back to Git operations if those API calls fail.
To disable this fallback behavior,
the user can pass the `--disable-repository-fallback` command-line flag.

```terminal
$ swift build --enable-package-registries --disable-repository-fallback
```

> **Note**:
> A dependency may be available only through the package registry interface,
> without a corresponding source repository.

These options may be changed or removed in a future release.

### Changes to `Package.resolved`

Swift package registry releases are archived as Zip files.

When an external package dependency is downloaded through a registry,
Swift Package Manager compares the integrity checksum provided by the server
against any existing checksum for that release in `Package.resolved`
as well as the integrity checksum reported by the `compute-checksum` subcommand:

```terminal
$ swift package compute-checksum LinkedList-1.2.0.zip
1feec3d8d144814e99e694cd1d785928878d8d6892c4e59d12569e179252c535
```

If no prior checksum exists,
it's saved to `Package.resolved`.

```json
{
    "object": {
        "pins": [
            {
                "package": "LinkedList",
                "url": "https://github.com/mona/LinkedList",
                "state": {
                    "checksum": "ed008d5af44c1d0ea0e3668033cae9b695235f18b1a99240b7cf0f3d9559a30d",
                    "version": "1.2.0"
                }
            }
        ]
    },
    "version": 1
}
```

If the checksum reported by the server is different from the existing checksum
(or the checksum of the downloaded artifact is different from either of them),
that's an indication that a package's contents may have changed at some point.
Swift Package Manager will refuse to download dependencies
if there's a mismatch in integrity checksums.

```terminal
$ swift build
error: checksum of downloaded source archive of dependency 'LinkedList' (c2b934fe66e55747d912f1cfd03150883c4f037370c40ca2ad4203805db79457) does not match checksum specified by the manifest (ed008d5af44c1d0ea0e3668033cae9b695235f18b1a99240b7cf0f3d9559a30d)
```

Once the correct checksum is determined,
the user can update `Package.resolved` with the correct value
and try again.

### Archive-source subcommand

An anecdotal look at other package managers suggests that
a checksum mismatch is more likely to be a
disagreement in how to create the archive and/or calculate the checksum
than, say, a forged or corrupted package.

This proposal adds a new `swift package archive-source` subcommand
to provide a standard way to create source archives for package releases.

```manpage
SYNOPSIS
	swift package archive-source [--output=<file>]

OPTIONS
	-o <file>, --output=<file>
		Write the archive to <file>.
		If unspecified, the package is written to `\(PackageName).zip`.
```

Run the `swift package archive-source` subcommand
in the root directory of a package
to generate a source archive for the current working tree.
For example:

```terminal
$ tree -a -L 1
LinkedList
├── .git
├── Package.swift
├── README.md
├── Sources
└── Tests

$ head -n 5 Package.swift
// swift-tools-version:5.3
import PackageDescription

let package = Package(
name: "LinkedList",

$ swift package archive-source
Created LinkedList.zip
```

By default,
the filename of the generated archive is
the name of the package with a `.zip` extension
(for example, "LinkedList.zip").
This can be configured with the `--output` option:

```terminal
$ git checkout 1.2.0
$ swift package archive-source --output="LinkedList-1.2.0.zip"
# Created LinkedList-1.2.0.zip
```

The `archive-source` subcommand has the equivalent behavior of
[`git-archive(1)`] using the `zip` format at its default compression level.
Therefore, the following command produces
equivalent output to the previous example:

```terminal
$ git archive --format zip --output LinkedList-1.2.0.zip 1.2.0
```

If desired, this behavior may be changed in future tool versions.

> **Note:**
> `git-archive` ignores files with the `export-ignore` Git attribute.
> By default, this ignores hidden files and directories,
> including`.git` and `.build`.

## Security

Adding external dependencies to a project
increases the attack surface area of your software.
However, much of the associated risk can be mitigated,
and a package registry can offer stronger guarantees for safety and security
compared to downloading dependencies using Git.

Core security measures,
such as use of HTTPS and integrity checksums,
are required by the registry service specification.
Additional decisions about security
are delegated to to the registries themselves.
For example,
registries are encouraged to adopt a
scoped, revocable authorization framework like [OAuth 2.0][RFC 6749],
but this isn't a strict requirement.
Package maintainers and consumers should
consider a registry's security posture alongside its other features
when deciding where to host and fetch packages.

To better understand the security implications of this proposal —
and Swift dependency management more broadly —
we employ the
<abbr title="Spoofing, Tampering, Repudiation, Information disclosure, Denial of Service, Escalation of privilege">
[STRIDE]
</abbr> mnemonic below:

### Spoofing

An attacker could interpose a proxy between the client and the package registry
to intercept credentials for that host
and use them to impersonate the user in subsequent requests.

The impact of this attack is potentially high,
depending on the scope and level of privilege associated with these credentials.
However, the use of secure connections over HTTPS
goes a long way to mitigate the overall risk.

Swift Package Manager could further mitigate this risk
by taking the following measures:

* Enforcing HTTPS for all dependency URLs
* Resolving dependency URLs using DNS over HTTPS (DoH)
* Requiring dependency URLs with Internationalized Domain Names (IDNs)
  to be represented as Punycode
* Normalizing package names to use an ASCII-compatible subset of characters

### Tampering

An attacker could interpose a proxy between the client and the package registry
to construct and send Zip files containing malicious code.

Although the impact of such an attack is potentially high,
the risk is largely mitigated by the use of cryptographic checksums
to verify the integrity of downloaded source archives.

```terminal
$ echo "$(swift package compute-checksum LinkedList-1.2.0.zip) *LinkedList-1.2.0.zip" | \
    shasum -a 256 -c -
LinkedList-1.2.0.zip: OK
```

Integrity checks alone can't guarantee
that a package isn't a forgery;
an attacker could compromise the website of the host
and provide a valid checksum for a malicious package.

`Package.resolved` provides a [Trust on first use (TOFU)][TOFU] security model
that can offer strong guarantees about the integrity of dependencies over time.
A registry can further improve on this model
by implementing a [transparent log] or some comparable,
tamper-proof system for associating artifacts with valid checksums.

### Repudiation

A compromised host could serve a malicious package with a valid checksum
and be unable to deny its involvement in constructing the forgery.

This threat is unique and specific to binary and source artifacts;
Git repositories can have their histories audited,
and individual commits may be cryptographically signed by authors.
Unless you can establish a direct connection between
an artifact and a commit in a source tree,
there's no way to determine the provenance of that artifact.
However,
a [transparent log] of checksums or the use of digital signatures
can provide similar non-repudiation guarantees.

### Information disclosure

An attacker could scrape public code repositories
for `Package.swift` files that use hardcoded credentials in dependency URLs,
and attempt to reuse those credentials to impersonate the user.

```swift
dependencies: [
  .package(name: "TopSecret",
           url: "https://<token>:x-oauth-basic@github.com/mona/TopSecret",
           checksum: "2c4a4ce92225fb766447c1757abb916e13f68eba0459f1287ee62e4941d89bbf")
]
```

This kind of attack can be mitigated on an individual basis
by using an unauthenticated URL and setting a mirror.

```terminal
$ swift package config set-mirror \
    --original-url https://github.com/mona/TopSecret \
    --mirror-url https://<token>:x-oauth-basic@github.com/mona/TopSecret
```

The risk could be mitigated for all users
if Swift Package Manager forbids the use of hardcoded credentials
in `Package.swift` files.

### Denial of service

An attacker could scrape public code repositories
for `Package.swift` files that declare dependencies
and launch a denial-of-service attack
in an attempt to reduce the availability of those resources.

The likelihood of this attack is generally low
but could be used in a targeted way
against resources known to be important or expensive to distribute.

This threat can be mitigated by obfuscating dependency URLs,
such that they can't be pattern matched from source code.

```swift
func rot13(_ string: String) -> String {
    String(string.unicodeScalars.map { unicodeScalar in
        var value = unicodeScalar.value
        switch unicodeScalar {
        case "A"..."M", "a"..."m": value += 13
        case "N"..."Z", "n"..."z": value -= 13
        default: break
        }

        return Character(Unicode.Scalar(value)!)
    })
}

dependencies: [
  .archive(name: "TopSecret",
           url: rot13("uggcf://tvguho.pbz/zban/GbcFrperg"),
           //       ^ "https://github.com/mona/TopSecret"
           checksum: "2c4a4ce92225fb766447c1757abb916e13f68eba0459f1287ee62e4941d89bbf")
]
```

> **Important**:
> Never store credentials in code —
> _even if they're obfuscated_.

### Escalation of privilege

Even authentic packages from trusted creators can contain malicious code.

Code analysis tools can help to some degree,
as can system permissions and other OS-level security features.
But developers are ultimately the ones responsible
for the code they ship to users.

## Impact on existing packages

Current packages won't be affected by this change,
as they'll continue to be able to download dependencies directly through Git.

HTTP content negotiation can be used to migrate existing package dependencies
to take advantage of Swift package registries
without changing their specification.

For example,
consider the following `Package.swift` manifest for a package
that includes `LinkedList` as a dependency:

```swift
// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "Example",
    dependencies: [
         .package(url: "https://github.com/mona/LinkedList", from: "1.1.0"),
    ],
    targets: [
        .target(name: "Example", dependencies: ["LinkedList"])
    ]
)
```

Currently,
Swift package manager uses the provided URL
to request the Git repository for the LinkedList dependency.
A future version of Swift Package Manager
could specify `application/vnd.swift.registry.v1+json` in its `Accept` header
(or set a versioned `User-Agent` header)
to opt-in to package registry APIs when available.

## Alternatives considered

### Use of alternative naming schemes

Some systems use [reverse domain name notation] to identify software components
(for example, `org.swift.swift-package-manager`),
including [Uniform Type Identifiers][UTI] on Apple platforms,
apps on the Android operating system,
and dependencies in [Maven].

We considered these and other schemes for identifying packages,
but ultimately rejected them in favor of URLs.

`Package.swift` manifests have always declared external dependencies using URLs,
so this step represents a formalization of long-standing tradition
rather than a departure from existing behavior.
Adopting an alternative scheme for package identity would require us
to invent new solutions to problems that are currently solved, including:

- **Naming authority**:
  Control of package namespaces are a function of DNS resolution,
  which is controlled by [ICANN] and domain registrars.
  Migrating away from DNS would entail creating a new, separate body
  for adjudicating claims and disputes of ownership.
- **Addressability**:
  You can navigate to the package URL
  `example.com/mona/LinkedList`
  from a browser or other networking clients.
  But that's not true of a reverse-DNS identifier like
  `com.example.mona.linkedlist`.
- **Compatibility**:
  If an alternative naming scheme were used for registry packages,
  a developer would need to migrate all direct and transitive dependencies
  to these new identifiers to benefit from the benefits of package registries.
  Identifying packages by URL allow registries to be adopted incrementally.

We believe that using URLs as package identifiers is
intuitive and familiar for developers,
and will best solve the immediate and future needs of this project.

### Use of `tar` or other archive formats

Swift Package Manager currently uses Zip archives for binary dependencies,
which is reason enough to use it again here.

We briefly considered `tar` as an archive format
but concluded that its behavior of preserving symbolic links and executable bits
served no useful purpose in the context of package management,
and instead raised concerns about portability and security.

> As an aside,
> Zip files are also a convenient format for package registries,
> because they support the access of individual files within an archive.
> This allows a registry to satisfy
> the package manifest endpoint (`GET /{package}/{version}/Package.swift`)
> without storing anything separately from the archive used for the
> package archive endpoint (`GET /{package}/{version}.zip`).

### Addition of an `unarchive-source` subcommand

This proposal adds an `archive-source` subcommand
as a standard way for developers and registries
to create source archives for packages.
Having a canonical tool for creating source archives
avoids any confusion when attempting to verify the integrity of
Zip files sent from a registry
with the source code for that package.

We considered including a complementary `unarchive-source` subcommand
but ultimately decided against it,
reason being that unarchiving a Zip archive
is unambiguous and well-supported on most platforms.

### Use of digital signatures

[SE-0272] includes discussion about
the use of digital signatures for binary dependencies,
concluding that they were unsuitable
because of complexity around transitive dependencies.
However, it's unclear what specific objections were raised in this proposal.
We didn't see any inherent tension with the example provided,
and no further explanation was given.

Without understanding the context of this decision,
we decided it was best to abide by their determination
and instead consider adding this functionality in a future proposal.
For the reasons outlined in the preceding Security section,
we believe that digital signatures may offer additional guarantees
of authenticity and non-repudiation beyond what's possible with checksums alone.

## Future directions

Defining a standard interface for package registries
lays the groundwork for several useful features.

### Package publishing

A package registry is responsible for determining
which package releases are made available to a consumer.
This proposal sets no policies for how
package releases are published to a registry.

Many package managers —
including the ones mentioned above —
and artifact repository services, such as
[Docker Hub],
[JFrog Artifactory],
and [AWS CodeArtifact]
follow what we describe as a <dfn>"push"</dfn> model of publication:
When a package owner wants to releases a new version of their software,
they produce a build locally and push the resulting artifact to a server.
This model has the benefit of operational simplicity and flexibility.
For example,
maintainers have an opportunity to digitally sign artifacts
before uploading them to the server.

Alternatively,
a system might incorporate build automation techniques like
continuous integration (CI) and continuous delivery (CD)
into what we describe as a "pull" model:
When a package owner wants to release a new version of their software,
their sole responsibility is to notify the package registry;
the server does all the work of downloading the source code
and packaging it up for distribution.
This model can provide strong guarantees about
reproducibility, quality assurance, and software traceability.

We intend to work with industry stakeholders
to develop standards for publishing Swift packages
in a future, optional extension to the registry specification.

### Package removal

There are several reasons why a package release may be removed, including:

* The package maintainer publishing a release by mistake
* A security vulnerability being discovered in a release
* The registry being compelled by law enforcement to remove a release

However, removing a package release has the potential to
break any packages that depend on it.
Many package management systems have their own processes for
how removal works (or whether it's supported in the first place).

It's unclear whether or to what extent such policies should be
informed by registry specification itself.
For now,
a registry is free to exercise its own discretion
about how to respond to out-of-band removal requests.

We plan to consider these questions
as part of the future, optional extension to the specification
described in the previous section.

### Binary framework distribution

The package registry specification could be amended
to support distributing packages as [XCFramework] bundles.

```http
GET /github.com/mona/LinkedList/1.1.1.xcframework HTTP/1.1
Host: packages.example.com
Accept: application/vnd.swift.registry.v1+xcframework
```

Swift Package Manager could then use XCFramework archives as
[binary dependencies][SE-0272]
or as part of a future binary artifact distribution mechanism.

```swift
let package = Package(
    name: "SomePackage",
    /* ... */
    targets: [
        .binaryTarget(
            name: "LinkedList",
            url: "https://packages.example.com/github.com/mona/LinkedList/1.1.1.xcframework",
            checksum: "ed04a550c2c7537f2a02ab44dd329f9e74f9f4d3e773eb883132e0aa51438b37"
        ),
    ]
)
```

### Intermediate registry proxies

By default,
the identity of the package is the same as its location.
Whether a package is declared with a URL of
`https:///example.com/mona/linkedlist` or
`git@example.com:mona/linkedlist.git`,
Swift Package Manager will — unless configured otherwise —
attempt to fetch that dependency by consulting `example.com`,
which may respond with a Git repository or a source archive
(or perhaps `404 Not Found`).

A user can currently specify an alternate location for a package
by setting a [dependency mirror][SE-0219] for that package's URL.

```terminal
$ swift package config set-mirror \
    --original-url https:///example.com/mona/linkedlist \
    --mirror-url https:///example.net/octocorp/swiftlinkedlist
```

Dependency mirroring allows for package dependencies to be rerouted
on an individual basis.
However, this approach doesn't scale well for large numbers of dependencies.

Swift Package Manager could implement a complementary feature
that allows users to specify one or more registry proxy URLs
that would be consulted (in order)
when resolving dependencies through the package registry interface.

For example,
a build server that doesn't allow external network connections
may specify an internal registry URL to manage all package dependency requests.

```terminal
$ swift package config set-registry-proxy https://internal.example.com/
```

When one or more proxy URLs are configured in this way,
resolving a package dependency with the URL
`https:///example.com/mona/linkedlist`
results in a `GET` request to
`https://internal.example.com/example.com/mona/linkedlist`.

A registry proxy decouples package identity from package location entirely,
which could unlock a variety of compelling use cases:

- **Geographic colocation**:
  Developers working under adverse networking conditions can
  host a mirror of official package sources on a nearby network.
- **Policy enforcement**:
  A corporate network can enforce quality or licensing standards,
  so that only approved packages are available.
- **Auditing**:
  A registry may analyze or meter access to packages
  for the purposes of ranking popularity or charging licensing fees.

### Offline cache

Swift Package Manager could implement an [offline cache]
that would allow it to work without network access.
While this is technically possible today,
a package registry makes for a simpler and more secure implementation
than would otherwise be possible with Git repositories alone.

### Security auditing

The response for listing package releases could be updated to include
information about security advisories.

```jsonc
{
    "releases": { /* ... */ },
    "advisories": [{
        "cve": "CVE-20XX-12345",
        "cwe": "CWE-400",
        "package_name": "github.com/mona/LinkedList",
        "vulnerable_versions": "<=1.0.0",
        "patched_versions": ">1.0.0",
        "severity": "moderate",
        "recommendation": "Update to version 1.0.1 or later.",
        /* additional fields */
    }]
}
```

Swift Package Manager could communicate this information to users
when installing or updating dependencies
or as part of a new `swift package audit` subcommand.

```terminal
$ swift package audit
┌───────────────┬──────────────────────────────────────────────────────────────┐
│ High          │ Regular Expression Denial of Service                         │
├───────────────┼──────────────────────────────────────────────────────────────┤
│ Package       │ RegEx                                                        │
├───────────────┼──────────────────────────────────────────────────────────────┤
│ Dependency of │ PatternMatcher                                               │
├───────────────┼──────────────────────────────────────────────────────────────┤
│ Path          │ SomePackage > PatternMatcher > RegEx                         │
├───────────────┼──────────────────────────────────────────────────────────────┤
│ More info     │ https://example.com/advisories/526                           │
└───────────────┴──────────────────────────────────────────────────────────────┘

Found 3 vulnerability (1 low, 1 moderate, 1 high) in 12 scanned packages.
  Run `swift package audit fix` to fix 3 of them.
```

### Package search

The package registry API could be extended to add a search endpoint
to allow users to search for packages by name, keywords, or other criteria.
This endpoint could be used by clients like Swift Package Manager.

```terminal
$ swift package search LinkedList
LinkedList (github.com/mona/LinkedList) - One thing links to another.

$ swift package search --author "Mona Lisa Octocat"
LinkedList (github.com/mona/LinkedList) - One thing links to another.
RegEx (github.com/mona/RegEx) - Expressions on the reg.
```

### Package installation from the command-line

Swift Package Manager could be extended with an `install` subcommand
that adds a dependency by its URL.

```terminal
$ swift package install github.com/mona/LinkedList
# Installed LinkedList 1.2.0
```

This functionality could be implemented separately from this proposal
but is included here as a complement to the search subcommand described above.

[BCP 13]: https://tools.ietf.org/html/rfc6838 "Media Type Specifications and Registration Procedures"
[RFC 2119]: https://tools.ietf.org/html/rfc2119 "Key words for use in RFCs to Indicate Requirement Levels"
[RFC 3230]: https://tools.ietf.org/html/rfc5843 "Instance Digests in HTTP"
[RFC 3492]: https://tools.ietf.org/html/rfc3492 "Punycode: A Bootstring encoding of Unicode for Internationalized Domain Names in Applications (IDNA)"
[RFC 3986]: https://tools.ietf.org/html/rfc3986 "Uniform Resource Identifier (URI): Generic Syntax"
[RFC 3987]: https://tools.ietf.org/html/rfc3987 "Internationalized Resource Identifiers (IRIs)"
[RFC 5234]: https://tools.ietf.org/html/rfc5234 "Augmented BNF for Syntax Specifications: ABNF"
[RFC 5843]: https://tools.ietf.org/html/rfc5843 "Additional Hash Algorithms for HTTP Instance Digests"
[RFC 6249]: https://tools.ietf.org/html/rfc6249 "Metalink/HTTP: Mirrors and Hashes"
[RFC 6570]: https://tools.ietf.org/html/rfc6570 "URI Template"
[RFC 6749]: https://tools.ietf.org/html/rfc6749 "The OAuth 2.0 Authorization Framework"
[RFC 7230]: https://tools.ietf.org/html/rfc7230 "Hypertext Transfer Protocol (HTTP/1.1): Message Syntax and Routing"
[RFC 7231]: https://tools.ietf.org/html/rfc7231 "Hypertext Transfer Protocol (HTTP/1.1): Semantics and Content"
[RFC 7233]: https://tools.ietf.org/html/rfc7233 "Hypertext Transfer Protocol (HTTP/1.1): Range Requests"
[RFC 7234]: https://tools.ietf.org/html/rfc7234 "Hypertext Transfer Protocol (HTTP/1.1): Caching"
[RFC 7807]: https://tools.ietf.org/html/rfc7807 "Problem Details for HTTP APIs"
[RFC 8288]: https://tools.ietf.org/html/rfc8288 "Web Linking"
[RFC 8446]: https://tools.ietf.org/html/rfc8446 "The Transport Layer Security (TLS) Protocol Version 1.3"
[TR36]: http://www.unicode.org/reports/tr36/ "Unicode Technical Report #36: Unicode Security Considerations"
[IANA Link Relations]: https://www.iana.org/assignments/link-relations/link-relations.xhtml
[JSON-LD]: https://w3c.github.io/json-ld-syntax/ "JSON-LD 1.1: A JSON-based Serialization for Linked Data"
[SemVer]: https://semver.org/ "Semantic Versioning"
[Schema.org]: https://schema.org/
[SoftwareSourceCode]: https://schema.org/SoftwareSourceCode
[DUST]: https://doi.org/10.1145/1462148.1462151 "Bar-Yossef, Ziv, et al. Do Not Crawl in the DUST: Different URLs with Similar Text. Association for Computing Machinery, 17 Jan. 2009. January 2009"

[GitHub / Swift Package Management Service]: https://forums.swift.org/t/github-swift-package-management-service/30406

[RubyGems]: https://rubygems.org "RubyGems: The Ruby community’s gem hosting service"
[PyPI]: https://pypi.org "PyPI: The Python Package Index"
[npm]: https://www.npmjs.com "The npm Registry"
[crates.io]: https://crates.io "crates.io: The Rust community’s crate registry"
[CocoaPods]: https://cocoapods.org "A dependency manager for Swift and Objective-C Cocoa projects"
[reverse domain name notation]: https://en.wikipedia.org/wiki/Reverse_domain_name_notation
[UTI]: https://en.wikipedia.org/wiki/Uniform_Type_Identifier
[Maven]: https://maven.apache.org
[Docker Hub]: https://hub.docker.com
[JFrog Artifactory]: https://jfrog.com/artifactory/
[AWS CodeArtifact]: https://aws.amazon.com/codeartifact/
[ICANN]: https://www.icann.org
[thundering herd effect]: https://en.wikipedia.org/wiki/Thundering_herd_problem "Thundering herd problem"
[offline cache]: https://yarnpkg.com/features/offline-cache "Offline Cache | Yarn - Package Manager"
[XCFramework]: https://developer.apple.com/videos/play/wwdc2019/416/ "WWDC 2019 Session 416: Binary Frameworks in Swift"
[SE-0272]: https://github.com/apple/swift-evolution/blob/master/proposals/0272-swiftpm-binary-dependencies.md "Package Manager Binary Dependencies"
[transparent log]: https://research.swtch.com/tlog
[TOFU]: https://en.wikipedia.org/wiki/Trust_on_first_use "Trust on First Use"
[version-specific-tag-selection]: https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-tag-selection "Swift Package Manager - Version-specific Tag Selection"
[version-specific-manifest-selection]: https://github.com/apple/swift-package-manager/blob/master/Documentation/Usage.md#version-specific-manifest-selection "Swift Package Manager - Version-specific Manifest Selection"
[STRIDE]: https://en.wikipedia.org/wiki/STRIDE_(security) "STRIDE (security)"
[SE-0219]: https://github.com/apple/swift-evolution/blob/master/proposals/0219-package-manager-dependency-mirroring.md "Package Manager Dependency Mirroring"
