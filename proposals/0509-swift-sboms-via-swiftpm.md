# Software Bill of Materials (SBOM) Generation for Swift Package Manager

* Proposal: [SE-0509](0509-swift-sboms-via-swiftpm.md)
* Authors: [Ev Cheng](https://github.com/echeng3805)
* Review Manager: [Franz Busch](https://github.com/FranzBusch)
* Status: **Active review (February 02...February 16, 2026)**
* Implementation: [swiftlang/swift-package-manager#9633](https://github.com/swiftlang/swift-package-manager/pull/9633)
* Review: ([pitch](https://forums.swift.org/t/pitch-software-bill-of-materials-sbom-generation-for-swift-package-manager/83499)) ([review](https://forums.swift.org/t/se-0509-software-bill-of-materials-sbom-generation-for-swift-package-manager/84516))

## Introduction

An SBOM (Software Bill of Materials) provides a detailed inventory of software components included in an artifact. SBOMs allow developers to improve and analyze the software supply chain security profile for their Swift projects (for example, determining whether a dependency that's being used has a vulnerability). Also, some companies, governments, and other regulatory bodies require SBOMs to be produced for auditing purposes.

There are two common formats for SBOMs: [CycloneDX](https://cyclonedx.org) and [SPDX](https://spdx.dev).

## Motivation

Currently, Swift Package Manager lacks built-in support for generating SBOMs. Instead, developers have to rely on external or third-party tools to create SBOMs. External and third-party tools usually analyze the `Package.swift` and `Package.resolved` files for package dependencies, so information about what **product** uses which dependencies is missing.

## Proposed solution

This proposal describes adding CycloneDX and SPDX SBOM generation capabilities to Swift Package Manager as part of the build command and as a separate package subcommand.

### Integrated Build Command

`swift build` will take an optional flag `--sbom-spec` that triggers CycloneDX and/or SPDX SBOM generation as part of the build command. SwiftPM will analyze the resolved package graph and optionally the SwiftBuild build system’s dependency graph, and produce SBOMs for the root package or product.

Re-running the command will not overwrite previously generated SBOMs; timestamps will be appended to SBOMs. This is to address the case when the same product or package is intentionally built multiple times with different flags; all SBOMs (not just the most recent) are relevant to the user.

If SBOM generation fails, the build will return an error.

### Traits and Conditions

Dependencies affected by traits are taken into consideration during package resolution. SwiftPM’s resolved package graph will already reflect the impact of traits on dependencies.

Conditions (e.g., OS-specific dependencies) are evaluated at build-time. SwiftPM’s package graph does not reflect conditions. Instead, the SBOM command will look at SwiftBuild build system’s computed dependency graph to determine which dependencies from the package graph should be included or excluded in the final SBOMs.

### Incremental Builds

SBOM generation occurs after the build completes successfully. If the build is incremental  (no recompilation needed), SBOMs are still generated based on the current package graph  and build graph state.

SBOM generation does not affect whether an artifact build will be full or incremental.

#### CLI Examples

A user can run the following commands:

```bash
# To generate CycloneDX SBOM file for a package using both package graph and build graph
$ swift build --build-system swiftbuild --sbom-spec cyclonedx

# To generate SPDX SBOM file for a package using both package graph and build graph
$ swift build --build-system swiftbuild --sbom-spec spdx

# To generate CycloneDX and SPDX SBOM files for a package using only the package graph
$ swift build --sbom-spec cyclonedx --sbom-spec spdx

# To generate a CycloneDX or SPDX SBOM file for a single product using both package graph and build graph
$ swift build --build-system swiftbuild --product MyProduct1 --sbom-spec cyclonedx
$ swift build --build-system swiftbuild --product MyProduct2 --sbom-spec spdx

# To generate SBOM files into a specific directory
$ swift build --build-system swiftbuild --sbom-spec cyclonedx --sbom-spec spdx --sbom-output-dir /MyDirectory
```

### Optional Flags

`--sbom-spec` will trigger SBOM generation when a build is run. Either `cyclonedx` or `spdx` or both (passing `--sbom-spec` flag twice in the same build command) can be passed to indicate what kind of SBOMs to generate.

`--sbom-spec` can only be used with one of the following:

* without `--product` and without `--target` flags (i.e., a SBOM for the entire package), or
* with `--product` flag (i.e., a SBOM for a specific product)

The build will error if `--sbom-spec` is used with the `--target` flag.

If `--build-system swiftbuild` is not specified, a warning will be emitted that only the package graph is being used for SBOM generation. (The build dependency graph is only available through SwiftBuild.) The warning will be emitted as the last line of the command.

`cyclonedx` and `spdx` flags will always point to the most recently SwiftPM-supported major versions, but users have the option to specify the major version they'd like.

```
OPTIONS:
  --sbom-spec <spec>           Set the SBOM specification.
        cyclonedx         - Most recent major version of CycloneDX supported by SwiftPM (currently: 1.7)
        spdx              - Most recent major version of SPDX supported by SwiftPM (currently: 3.0)
        cyclonedx1        - Most recent minor version of CycloneDX v1 supported by SwiftPM  (currently: 1.7)
        spdx3             - Most recent minor version of SPDX v3 supported by SwiftPM  (currently: 3.0)
        # Future: cyclonedx2...
        # Future: spdx4...
```

Additionally, users can specify the following optional flags (which must appear with `--sbom-spec`):

```
--sbom-output-dir <sbom-output-dir>  The absolute or relative directory path to generate the SBOM(s) in.
--sbom-filter <filter> Filter the SBOM components and dependencies by products and/or packages.
        all               - Include all entities in the SBOM (default)
        package           - Only include package information and package dependencies
        product           - Only include product information and product dependencies
--sbom-warning-only  When set, SBOM generation failure will emit a warning instead of failing the build
```

#### SBOM Filters

SBOM filters help address the following use cases:

- **All packages and products**: The SBOM is an exhaustive inventory of packages and products for a root product or root package. Developers who need to know what products are used and also what packages the products come from (e.g., provenance information) can use these comprehesive SBOMs, since they provide more information.
- **Package-only**: Some CVE vulnerabilities are disclosed at a package-level. For developers who are trying to remediate vulnerabilities, the package-only SBOM is advantageous because it's less noisy. Also, packages are the unit that are updated, so SBOMs can help developers plan which packages need to be updated. 
- **Product-only**: Product-only SBOMs help developers understand what products an application depends on at runtime; they can see which specific products from dependent packages are built and shipped with their own applications. 

#### Configuration

Sometimes the developers cannot change the `swift build` command to trigger SBOM generation. For example, infrastructure or security developers who own their organizations' CI systems might want to create SBOMs for all Swift projects, but cannot modify other teams' `swift build` commands.

In these cases, environment variables can be used instead to trigger SBOM generation.

* `SWIFTPM_BUILD_SBOM_OUTPUT_DIR`: specifies which directory the SBOMs should be generated in. If `--sbom-output-dir` is passed to swift build, `--sbom-output-dir` will take precedence.
* `SWIFTPM_BUILD_SBOM_FILTER` (default: `all`): specifies which filter to apply, defaults to all. If `--sbom-filter` is passed to `swift build`, `--sbom-filter` will take precedence.
* `SWIFTPM_BUILD_SBOM_SPEC`: builds SBOMs automatically for CycloneDX and SPDX specs (can take values `spdx`, `cyclonedx` or `cyclonedx,spdx`). If `--sbom-spec` is passed to `swift build`, `--sbom-spec` takes precedence.
* `SWIFTPM_BUILD_SBOM_WARNING_ONLY` (default: `false`): if SBOM build fails, emit a warning only. If `--sbom-warning-only` is passed, `--sbom-warning-only` takes precedence.


The last two environment variables addresses the use case where an external party (e.g., infrastructure or security teams) wants to generate SBOMs for all Swift projects under their purview without interfering with build results.

### Package Subcommand

SBOM generation will also be added as a separate subcommand `swift package generate-sbom`. It will share the same SBOM flags as SBOM generation for `swift build`. Unlike SBOM generation in `swift build`, `swift package generate-sbom` will **not** call the build or use the `SwiftBuild` build dependency graph.

This subcommand is to address use cases where an SBOM might need to be created after a build (for example, in a CICD pipeline or using a different version of the toolchain), but calling `swift build` again is undesirable or impossible.

The subcommand will always emit a warning that the SBOM may not be fully accurate because it only uses the package graph. This warning will be emitted as the last line in the command.

```
warning: "`generate-sbom` subcommand creates SBOM(s) based on modules graph only"
```

The user will have the option to pass `--disable-automatic-resolution` to force SBOM generation to fail if the `Package.resolved` is not up-to-date.
 
Note: Using the package subcommand without `--disable-automatic-resolution` can result in dependency resolution timing issues. There is an edge case where an artifact is built, the dependency graph changes, and then the SBOM is generated. In that case, the SBOM will not accurately reflect the built artifact’s components and dependencies. 

#### CLI Examples

A user can run the following commands:

```bash
# To generate CycloneDX SBOM file for a package using the package graph
$ swift package generate-sbom --sbom-spec cyclonedx

# To generate SPDX SBOM file for a package using the package graph
$ swift package generate-sbom --sbom-spec spdx

# To generate CycloneDX and SPDX SBOM files for a package using the package graph
$ swift package generate-sbom --sbom-spec cyclonedx --sbom-spec spdx

# To generate a CycloneDX or SPDX SBOM file for a single product using the package graph
$ swift package generate-sbom --product MyProduct1 --sbom-spec cyclonedx
$ swift package generate-sbom --product MyProduct2 --sbom-spec spdx

# To generate SBOM files into a specific directory
$ swift package generate-sbom --sbom-spec cyclonedx --sbom-spec spdx --sbom-output-dir /MyDirectory
```

## Detailed design

The SBOM generation will have three layers:

1. **Extractor Layer** (`SBOMExtractor`): Reads information from the package graph (modules graph) and optionally the build dependency graph, storing it in internal data structures
2. **Converter Layer** (`CycloneDXConverter`, `SPDXConverter`): Converts internal data structures into spec-specific formats (CycloneDX 1.7 JSON, SPDX 3.0.1 JSON)
3. **Validator Layer** (`SBOMValidator`): Validates generated SBOMs against embedded JSON schemas

### SBOM Content

#### Specs

Only the most recent minor version of each major version SBOM spec will be supported, starting from CycloneDX 1 and SPDX 3. Currently, that means CycloneDX 1.7 (minor version 1.7 of v1) and SPDX 3.0 (minor version 3.0 of v3). CycloneDX 2 and SPDX 4 are yet to be released.

When minor versions are released of CycloneDX or SPDX, the previous minor version is no longer supported. For example, when CycloneDX 1.8 or SPDX 3.1 are released, CycloneDX 1.7 and SPDX 3.0 will no longer be supported. This is to keep maintenance of the SBOM feature feasible and scoped.

SwiftPM will only support SBOMs in JSON format. JSON is a common file format supported by both CycloneDX and SPDX. JSON is the preferred format for CycloneDX and becoming more common in SPDX.

Generated SBOMs will include:

#### Components

If `SwiftBuild` is specified and the build dependency graph is used, then only used components will be included. Otherwise, all components in the resolved package graph will be included.

**Components**
* Component CycloneDX type or package SPDX purpose (application or library)
  * For a Swift package, if there is at least one product that is an executable, the package is considered an SBOM `application` component; else it is an SBOM `library` component. Test products are not considered.
  * For a Swift product, if it is a Swift executable product, it will be considered an SBOM `application` component; else the product is an SBOM `library` component. 
* Name
* Version, either a version tag or SHA
* Package URL (PURL) for unique identification
* Source repository information (commit SHA and repo URL if available)
* Entity type (Swift package or product)
* Scope (whether an SBOM component is a test component)
  * For a Swift package, if all products are test products, then the SBOM component scope is `test`; else it is `required`.
  * For a Swift product, if all modules are test modules, then the SBOM component scope is `test`; else it is `required`.

**CycloneDX:**

```json
{
    "bom-ref" : "swift-asn1:SwiftASN1",
    "name" : "SwiftASN1",
    "pedigree" : {
        "commits" : [
            {
                 "uid" : "40d25bbb2fc5b557a9aa8512210bded327c0f60d",
                 "url" : "https://github.com/apple/swift-asn1.git"
            }
        ]
    },
    "properties" : [
        {
            "name" : "swift-entity",
            "value" : "swift-product"
        }
    ],
    "purl" : "pkg:swift/github.com/apple/swift-asn1:SwiftASN1@1.5.0",
    "scope" : "required",
    "type" : "library",
    "version" : "1.5.0"
}
```

**SPDX:**

```json
{
    "creationInfo" : "_:creationInfo",
    "description" : "<ResolvedPackage: swift-asn1>",
    "externalUrl" : "pkg:swift/github.com/apple/swift-asn1@1.5.0",
    "name" : "swift-asn1",
    "software_internalVersion" : "1.5.0",
    "software_primaryPurpose" : "library",
    "spdxId" : "urn:spdx:swift-asn1",
    "summary" : "swift-package",
    "type" : "software_Package"
},
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:40d25bbb2fc5b557a9aa8512210bded327c0f60d",
    "relationshipType" : "generates",
    "spdxId" : "urn:spdx:40d25bbb2fc5b557a9aa8512210bded327c0f60d-generates",
    "to" : [
        "urn:spdx:swift-asn1",
        "urn:spdx:swift-asn1:SwiftASN1"
    ],
    "type" : "Relationship"
},
{
    "externalIdentifierType" : "gitoid",
    "identifier" : "urn:spdx:40d25bbb2fc5b557a9aa8512210bded327c0f60d",
    "identifierLocator" : [
        "https://github.com/apple/swift-asn1.git"
    ],
    "type" : "ExternalIdentifier"
}
```

#### Dependencies

SBOM generation cross-references two different sources (the resolved modules graph and the SwiftBuild build dependency graph) for dependency information.

If `SwiftBuild` is specified and the build dependency graph is used, then only used dependencies will be included. Otherwise, all dependencies in the resolved package graph will be included.

The SBOM will contain information about:

* Package-to-package dependencies
  * Root package depends on other packages.
  * A package depends on other packages.
* Package-to-product dependencies ("dependencies" isn't exactly accurate, but the relationship is treated as a deepndency in the SBOM in order to create a complete graph)
  * A package produces products.
* Product-to-product dependencies
  * A product depends on products from other packages.

So a package can depend on a package or product, whereas a product can only depend on products. This maintains cleanliness and prevents cycles in the SBOM.

**Note about products in the same package:** Products in the same root package that share targets can create cycles if they depend on each other. So product-to-product dependencies within the same root package are not tracked, only product-to-product dependencies from outside the root package are tracked.

For further information, see [Appendix](#appendix).

**CycloneDX:**

```json
{
    "dependsOn" : [
        "swift-asn1:SwiftASN1"
    ],
    "ref" : "swift-crypto:_CryptoExtras"
},
{
    "dependsOn" : [
        "swift-crypto:Crypto",
        "swift-crypto:_CryptoExtras",
        "swift-asn1"
    ],
    "ref" : "swift-crypto"
},
{
    "dependsOn" : [
        "swift-asn1",
        "swift-crypto",
        "swift-certificates:X509"
    ],
    "ref" : "swift-certificates"
},
{
    "dependsOn" : [
        "swift-crypto:Crypto",
        "swift-asn1:SwiftASN1",
        "swift-crypto:_CryptoExtras"
    ],
    "ref" : "swift-certificates:X509"
},
{
    "dependsOn" : [
        "swift-asn1:SwiftASN1"
    ],
    "ref" : "swift-asn1"
}
```

**SPDX:**

```json
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:swift-crypto:_CryptoExtras",
    "relationshipType" : "dependsOn",
    "spdxId" : "urn:spdx:swift-crypto:_CryptoExtras-dependsOn",
    "to" : [
        "urn:spdx:swift-asn1:SwiftASN1"
    ],
    "type" : "Relationship"
},
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:swift-crypto",
    "relationshipType" : "dependsOn",
    "spdxId" : "urn:spdx:swift-crypto-dependsOn",
    "to" : [
        "urn:spdx:swift-crypto:Crypto",
        "urn:spdx:swift-crypto:_CryptoExtras",
        "urn:spdx:swift-asn1"
    ],
    "type" : "Relationship"
},
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:swift-certificates",
    "relationshipType" : "dependsOn",
    "spdxId" : "urn:spdx:swift-certificates-dependsOn",
    "to" : [
        "urn:spdx:swift-asn1",
        "urn:spdx:swift-crypto",
        "urn:spdx:swift-certificates:X509"
    ],
    "type" : "Relationship"
},
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:swift-certificates:X509",
    "relationshipType" : "dependsOn",
    "spdxId" : "urn:spdx:swift-certificates:X509-dependsOn",
    "to" : [
        "urn:spdx:swift-crypto:Crypto",
        "urn:spdx:swift-asn1:SwiftASN1",
        "urn:spdx:swift-crypto:_CryptoExtras"
    ],
    "type" : "Relationship"
},
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:swift-asn1",
    "relationshipType" : "dependsOn",
    "spdxId" : "urn:spdx:swift-asn1-dependsOn",
    "to" : [
        "urn:spdx:swift-asn1:SwiftASN1"
    ],
    "type" : "Relationship"
}
```

#### Metadata

* SwiftPM version used
* SBOM timestamp
* Spec version

**CycloneDX:**

```json
"metadata" : {
...
    "timestamp" : "2025-11-19T21:42:50Z",
    "tools" : {
        "components" : [
            {
                "bom-ref" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6",
                "licenses" : [
                    {
                        "license" : {
                            "id" : "Apache-2.0",
                            "url" : "http://swift.org/LICENSE.txt"
                         }
                    }
                ],
                "name" : "swift-package-manager",
                "purl" : "pkg:swift/github.com/swiftlang/swift-package-manager@6.3.0-dev",
                "scope" : "excluded",
                "type" : "application",
                "version" : "6.3.0-dev"
            }
        ]
    }
},
"serialNumber" : "urn:uuid:8318774a-f646-4eab-a08c-0dc3f952abc5",
"specVersion" : "1.7",
"version" : 1
```

**SPDX:**

```json
{
    "creationInfo" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6:creationInfo",
    "from" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6",
    "relationshipType" : "hasDeclaredLicense",
    "spdxId" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6-hasDeclaredLicense-urn:spdx:Apache-2.0",
    "to" : [
        "urn:spdx:Apache-2.0"
    ],
    "type" : "Relationship"
},
{
    "creationInfo" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6:creationInfo",
    "simplelicensing_licenseExpression" : "Apache-2.0",
    "spdxId" : "urn:spdx:Apache-2.0",
    "type" : "simplelicensing_LicenseExpression"
},
{
    "@id" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6:creationInfo",
    "created" : "1970-01-01T00:00:00Z",
    "createdBy" : [
        "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6"
    ],
    "specVersion" : "6.3.0-dev",
    "type" : "CreationInfo"
},
{
    "creationInfo" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6:creationInfo",
    "name" : "swift-package-manager",
    "spdxId" : "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6",
    "type" : "Agent"
},
{
    "@id" : "_:creationInfo",
    "created" : "2025-11-19T21:42:50Z",
    "createdBy" : [
        "urn:uuid:40316357-938f-4a8c-9962-e928fbc251a6"
    ],
    "specVersion" : "3.0.1",
    "type" : "CreationInfo"
},
{
    "creationInfo" : "_:creationInfo",
    "profileConformance" : [
        "core",
        "software"
    ],
    "rootElement" : [
        "urn:spdx:swift-package-manager"
    ],
    "spdxId" : "urn:uuid:5aee3149-5395-4a41-a076-2491437026d3",
    "type" : "software_Sbom"
}
```

#### Primary Component

**CycloneDX:**

```json
"component" : {
    "bom-ref" : "swift-package-manager",
    "name" : "swift-package-manager",
    "pedigree" : {
        "commits" : [
            {
                "uid" : "37990426e3f1cb4344f39641e634c76130c1fb42",
                "url" : "git@github.com:echeng3805/swift-package-manager.git"
            }
        ]
    },
    "properties" : [
        {
            "name" : "swift-entity",
            "value" : "swift-package"
        }
    ],
    "purl" : "pkg:swift/github.com/echeng3805/swift-package-manager@37990426e3f1cb4344f39641e634c76130c1fb42-modified",
    "scope" : "required",
    "type" : "application",
    "version" : "37990426e3f1cb4344f39641e634c76130c1fb42-modified"
}
```

**SPDX:**

```json
{
    "creationInfo" : "_:creationInfo",
    "description" : "<ResolvedPackage: swift-package-manager>",
    "externalUrl" : "pkg:swift/github.com/swiftlang/swift-package-manager@37990426e3f1cb4344f39641e634c76130c1fb42-modified",
    "name" : "swift-package-manager",
    "software_internalVersion" : "37990426e3f1cb4344f39641e634c76130c1fb42-modified",
    "software_primaryPurpose" : "application",
    "spdxId" : "urn:spdx:swift-package-manager",
    "summary" : "swift-package",
    "type" : "software_Package"
}
{
    "externalIdentifierType" : "gitoid",
    "identifier" : "urn:spdx:37990426e3f1cb4344f39641e634c76130c1fb42",
    "identifierLocator" : [
        "git@github.com:echeng3805/swift-package-manager.git"
    ],
    "type" : "ExternalIdentifier"
},
{
    "creationInfo" : "_:creationInfo",
    "from" : "urn:spdx:37990426e3f1cb4344f39641e634c76130c1fb42",
    "relationshipType" : "generates",
    "spdxId" : "urn:spdx:37990426e3f1cb4344f39641e634c76130c1fb42-generates",
    "to" : [
        "urn:spdx:swift-package-manager",
    ],
    "type" : "Relationship"
},
```

### Performance

Performance of SBOM generation depends on the machine that's generating the SBOM and how large the project is. In general, a repo that is the size of `swift-package-manager` (approx 60 components and 350 dependencies) will take less than 5 seconds to generate both CycloneDX and SPDX SBOMs.

## Security

This will strengthen Swift’s supply chain security profile by providing a basic inventory for packages and products.

## Impact on existing packages

This feature modifies existing SwiftPM functionality by making the SwiftBuild build dependency graph an optional output of the build (which is then consumed for SBOM generation). This feature also adds an optional feature to the build command and a new package subcommand.

## Alternatives considered

### Build Plugin and Command Plugin

Command and build plugins need to be added to the Package.swift file to be available. Building SBOM generation directly into `swift build` gives users the feature without any need to change existing `Package.swift` files or existing configuration.

## Future Features

Some future features that can be added include:

* **Best attempt at licenses**: Automatic license identification from source code (some edge cases make it difficult to exactly accurately determine licenses; examples: multi-license projects depending on whether payment was rendered, multiple licenses in the repository, license of single file vs license of whole project, changes in license verbiage without changing the name of the license, relicensing for different versions of the same project)
* **`--target` flag support**: Support more granular SBOMs (per target)
* **Additional information**: Maintainers’ contact information, commit/forking history, additional build metadata (e.g., host, operating system)
* **Additional file formats**: XML, TV, YAML. XML is a format supported by both specs; however, XML is not the preferred format for either CycloneDX or SPDX.
* **Additional spec versions**: CycloneDX 2, SPDX 4 when available
* **Merged SBOMs**: Generate one SBOM for multiple products/targets, merge or link existing SBOM (e.g., from a third-party SDK) into output SBOM. At the least, this requires a common output location for SBOMs, as well as SBOM parsing capabilities. 
* **Independent CycloneDX and SPDX libraries**: For parsing CycloneDX/SPDX files, or supporting other fields besides the bare minimum
* **Package.resolved generation**: Generate a `Package.resolved` file based on an SBOM in order to reproduce a dependency graph (e.g., for debugging)
* **SBOM signing**: Sign the SBOM cryptographically to link it to an artifact
* **Hashes**: Add hashes to the SBOM

## Appendix

### Dependencies Extraction Algorithm

The dependency extraction follows a breadth-first traversal pattern with the following steps:

1. Initialize tracking structures:
   - `components`: Set of all discovered components
   - `relationships`: Map of parent components to their child components
   - `processedProducts`: Set to avoid reprocessing products
   - `productsToProcess`: Queue of products to analyze

Then, for either the specified product, or for all products in the root package:

1. **Track root package → product relationship**
   - Add relationship: root package depends the target product

2. **Process product dependencies**:
   - While `productsToProcess` is not empty:
     - Remove product from queue and add to `processedProducts`. This is the `currentlyProcessedProduct`.
     - Add relationship: root package depends on `currentlyProcessedProduct`'s package (if it's not the root package -- products within the same root package shouldn't depend on each other)
     - Get `currentlyProcessedProduct`'s dependencies based on the SwiftBuild build graph. If the build graph isn't available, fall back to the resolved modules graph. 
     - For each dependency:
       - **If it's a product `dependentProduct`**: If not in `processedProducts`, then add `dependentProduct` to `productsToProcess` (so its own dependencies can be processed). Also:
          - Add relationship:`currentlyProcessedProduct` → `dependentProduct` (if from different packages)
          - Add relationship: `currentlyProcessedProduct`'s package → `dependentProduct`'s package
          - Add relationship: `dependentProduct`'s package → `dependentProduct`
       - **If it's a module `dependentModule`**:
          - Initialize module processing queue `modulesToProcess` with `dependentModule`
          - While `modulesToProcess` isn't empty:
              - Remove module and mark as processed
              - Get module's dependencies from either the build graph or modules graph (if build graph isn't available)
              - For each module dependency:
                  - If product, add to `productsToProcess`
                  - If module, add to `modulesToProcess`
           - Return list of discovered products added to `productsToProcess`
