# Software Bill of Materials (SBOM) Generation for Swift Package Manager

* Proposal: [SE-NNNN](NNNN-swift-sboms.md)
* Authors: [Ev Cheng](https://github.com/echeng3805)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: [swiftlang/swift-package-manager#NNNNN](https://github.com/swiftlang/swift-package-manager/pull/NNNNN)
* Decision Notes: [Rationale](https://forums.swift.org/), [Additional Commentary](https://forums.swift.org/)
* Bugs: [SR-NNNN](https://bugs.swift.org/browse/SR-NNNN), [SR-MMMM](https://bugs.swift.org/browse/SR-MMMM)
* Previous Revision: [1](https://github.com/swiftlang/swift-evolution/blob/...commit-ID.../proposals/NNNN-filename.md)
* Previous Proposal: [SE-XXXX](XXXX-filename.md)

## Introduction

An SBOM (Software Bill of Materials) provides a detailed inventory of software components included in an artifact. SBOMs allow developers to improve and analyze the software supply chain security profile for their Swift projects (for example, determining whether a dependency that's being used has a vulnerability). Also, some companies, governments, and other regulatory bodies require SBOMs to be produced for auditing purposes.

There are two common formats for SBOMs: [CycloneDX](https://cyclonedx.org) and [SPDX](https://spdx.dev).

Swift-evolution thread: [Discussion thread topic for that
proposal](https://forums.swift.org/t/pitch-software-bill-of-materials-sbom-generation-for-swift-package-manager/83499)

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
$ swift build --build-system swiftbuild --sbom-spec cyclonedx --sbom-spec spdx --sbom-dir /MyDirectory
```

### Optional Flags

`--sbom-spec` will trigger SBOM generation when a build is run. Either `cyclonedx` or `spdx` or both can be passed to indicate what kind of SBOMs to generate.

`--sbom-spec` can only be used with one of the following:

* without `--product` and without `--target` flags (i.e., a SBOM for the entire package), or
* with `--product` flag (i.e., a SBOM for a specific product)

The build will error if `--sbom-spec` is used with the `--target` flag.

If `--build-system swiftbuild` is not specified, a warning will be emitted that only the package graph is being used for SBOM generation. (The build dependency graph is only available through SwiftBuild.)

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
--sbom-dir <sbom-dir>  The absolute or relative directory path to generate the SBOM(s) in.
--sbom-filter <filter> Filter the SBOM components and dependencies by products and/or packages.
        all               - Include all entities in the SBOM (default)
        package           - Only include package information and package dependencies
        product           - Only include product information and product dependencies
--sbom-warning-only <bool> Whether to ignore SBOM generation errors and emit a warning instead (default: false)
```

The filter implementation uses a strategy pattern with three concrete strategies:
- `AllFilterStrategy`: Includes all components and dependencies
- `ProductFilterStrategy`: Includes only products and product-to-product dependencies (plus root package if primary component is a package)
- `PackageFilterStrategy`: Includes only packages and package-to-package dependencies (plus root product if primary component is a product)

#### Configuration

Environment variables can be used for SBOM generation configuration in the short-term.

An issue in Github will be raised and linked in the code to address changing SBOM environment variables to a configuration file.


* `SWIFTPM_BUILD_SBOM_DIRECTORY`: specifies which directory the SBOMs should be generated in. If `--sbom-dir` is passed to swift build, `--sbom-dir` will take precedence.
* `SWIFTPM_BUILD_SBOM_FILTER` (default: `all`): specifies which filter to apply, defaults to all. If `--sbom-filter` is passed to `swift build`, `--sbom-filter` will take precedence.
* `SWIFTPM_BUILD_SBOM_SPEC`: builds SBOMs automatically for CycloneDX and SPDX specs (can take values `spdx`, `cyclonedx` or `cyclonedx,spdx`). If `--sbom-spec` is passed to `swift build`, `--sbom-spec` takes precedence.
* `SWIFTPM_BUILD_SBOM_WARNING_ONLY` (default: `false`): if SBOM build fails, emit a warning only. If `--sbom-warning-only` is passed, `--sbom-warning-only` takes precedence.


The last two environment variables addresses the use case where an external party (e.g., infrastructure or security teams) wants to generate SBOMs for all Swift projects under their purview without interfering with build results.

### Package Subcommand

SBOM generation will also be added as a separate subcommand `swift package generate-sbom`. It will share the same SBOM flags as SBOM generation for `swift build`. Unlike SBOM generation in `swift build`, `swift package generate-sbom` will **not** call the build or use the `SwiftBuild` build dependency graph.

This subcommand is to address use cases where an SBOM might need to be created after a build (for example, in a CICD pipeline or using a different version of the toolchain), but calling `swift build` again is undesirable or impossible.

The subcommand will always emit a warning that the SBOM may not be fully accurate because it only uses the package graph.

```
warning: "`generate-sbom` subcommand creates SBOM(s) based on modules graph only"
```

The user will have the option to pass `--disable-automatic-resolution` to force SBOM generation to fail if the `Package.resolved` is not up-to-date.
 
Note: Using the package subcommand can result in dependency resolution timing issues. There is an edge case where an artifact is built, the dependency graph changes, and then the SBOM is generated. In that case, the SBOM will not accurately reflect the built artifact’s components and dependencies.

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
$ swift package generate-sbom --sbom-spec cyclonedx --sbom-spec spdx --sbom-dir /MyDirectory
```

## Detailed design


The SBOM generation will have three layers:

1. **Extractor Layer** (`SBOMExtractor`): Reads information from the package graph (modules graph) and optionally the build dependency graph, storing it in internal data structures (`SBOMDocument`, `SBOMComponent`, `SBOMDependencies`, etc.)
2. **Converter Layer** (`CycloneDXConverter`, `SPDXConverter`): Converts internal data structures into spec-specific formats (CycloneDX 1.7 JSON, SPDX 3.0.1 JSON)
3. **Validator Layer** (`SBOMValidator`): Validates generated SBOMs against embedded JSON schemas

The extractor layer is where most of the processing happens. The converter layer does minimal processing (just enough to convert internal data structures into CycloneDX-specific or SPDX-specific data structures). The validator reads a schema and does some optimized checks of the generated SBOM against the schemas.

### `SBOMExtractor`

The `SBOMExtractor` is the main entry point for extracting SBOM data from SwiftPM's package graph and optionally SwiftBuild's dependency graph.

#### Caching System

The extractor uses three actor-based caches to avoid redundant work:
- **`SBOMGitCache`**: Caches Git information (commits, versions) per package identity
- **`SBOMComponentCache`**: Caches extracted components (packages and products)
- **`SBOMTargetNameCache`**: Maps module IDs in the package graph to build graph target names in the build dependency graph

These caches are necessary for performance. Without the caches, SBOM generation can take up to 1 minute. With the caches, SBOM generation is usually under 5 seconds.

#### Component Extraction

Packages and products are both treated as components in the SBOM.

**Packages:**
- Extracts category (application vs library based on product types - if there is at least one product that is an executable, the package is considered an application; else, it is a library)
- Extracts scope (if all products are test products, then the scope is test)
- Gets version/commit info from Git (for root package) or resolved store (for dependencies)
- Generates PURL (Package URL) for unique identification
- Recursively extracts all products within the package

**Products:**
- Similar extraction but at product level
- Determines if product is an application (corresponds to executable) or library (defaults to library)
- Extract scope (if all modules are test modules, then the scope is test)
- Inherits version/commit info from the package

#### Dependency Extraction

The extractor can cross-reference two different sources (the resolved modules graph and the SwiftBuild build dependency graph) for dependency information:

**Algorithm:**

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

**Note about circular dependencies:** Products in the same root package that share modules can create cycles if they depend on each other. So product-to-product dependencies within the same root package are not tracked, only product-to-product dependencies from outside the root package are tracked.

These are the relationships that are included in the final SBOM:

- Root package depends on each product it produces.
- Root package depends on other packages.
- A package depends on other packages.
- A package depends on each product it produces.
- A product depends on other products from other packages.

(A package can depend on a package or a product it produces. A product can only depend on another product, not on a package. This maintains cleanliness in the SBOM and prevents circular dependencies in the SBOM.)

### `SBOMValidator` and Versioning

The `SBOMValidator` handles validation of generated SBOMs against schemas.

Only the most recent minor version of each major version will be supported. Currently, that means CycloneDX 1.7 (minor version 1.7 of v1) and SPDX 3.0 (minor version 3.0 of v3). CycloneDX 2 and SPDX 4 are yet to be released.

When minor versions are released of CycloneDX or SPDX, the previous minor version is no longer supported. For example, when CycloneDX 1.8 or SPDX 3.1 are released, CycloneDX 1.7 and SPDX 3.0 will no longer be supported. This is to keep maintenance of the SBOM feature feasible and scoped.

`SBOMSpec` is the internal structure that describes SBOM specifications. It consists of an enum `ConcreteSpec`, either `.cyclonedx1` or `.spdx3`.

When there is a major version update, the enum and any switch statements associated with the enum should be updated to add `.cyclonedx2` or `.spdx4`.

`SBOMVersionRegistry` is the registry where current minor versions are listed for each major version. Given an `SBOMSpec`, it returns the latest version for the spec. When there is a minor version update, the version strings should be updated.

#### Major Updates

- Extend the `Spec` enum. This is the enum that the users pass on the CLI.
- Extend the `SBOMSpec.ConcreteSpec` enum. This is the enum used internally for processing. 
- Create new constants in `CycloneDXConstants.swift` and `SPDXConstants.swift` that point to the new major version's schema files.
- New schemas used for validation should be added. Schemas for previous major versions should not be updated. 
- Update associated all switch statements in the code. These switch statements are comprehensive, so missing one should cause compilation to fail.

#### Minor Updates

- Update `SBOMVersionRegistry.swift` strings.
- New schemas used for validation should be added. Schemas for previous minor versions should be deleted. 
- `CycloneDXConstants.swift` and `SPDXConstants.swift` might need to be updated.
- Tests in `SBOMValidation.swift` might need to be updated.

#### Breaking Changes

Breaking changes will need to be handled at the `Converter` layer. This is the layer that translates SBOM information from internal Swift structures to specific structures that slign with CycloneDX and SPDX specifications.

Depending on the degree of the breaking change, `switch` statements can be used to handle small differences or should be used to initialize new versions of `SPDXConverter` or `CycloneDXConverter`. These new versions don't exist yet, and need to be written based on the breaking changes. 

#### Schemas

`SBOMSchema` handles schema loading and validation. It uses a bundle-based approach. If the bundle isn't found, validation of the SBOM is automatically skipped.

It avoids using `Bundle.module` because if the bundle is not found (like on a custom toolchain), there is fatal error. It also avoids using `Bundle.allBundles` because on Linux, `Bundle.allBundles` is not thread-safe. Instead, it searches for and tries to load bundles on disk at `Bundle.main.resourceURL`, `Bundle.main.bundleURL`, and `Bundle.main.executableURL`.

To update the schema,

- Replace or add a schema file in the `Resources` directory.
- Update the schema filename constant in `CycloneDXConstants.swift` and `SPDXConstants.swift`.
- Run `SBOMValidationTests`.

### SBOM Content

This feature will support the most recent minor versions of major versions starting with CycloneDX 1 and SPDX 3.

Only JSON files will be generated. JSON is a common file format supported by both CycloneDX and SPDX. JSON is the preferred format for CycloneDX and becoming more common in SPDX.

Generated SBOMs will include:

#### Components

If `SwiftBuild` is specified and the build dependency graph is used, then only used components will be included. Otherwise, all components in the resolved package graph will be included.

* Component CycloneDX type or package SPDX purpose; name; and version
* Package URL (PURL) for unique identification
* Source repository information
* Entity type (Swift package or product)

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

If `SwiftBuild` is specified and the build dependency graph is used, then only used dependencies will be included. Otherwise, all dependencies in the resolved package graph will be included.

* Direct and transitive relationships
* Package-to-package dependencies
* Package-to-product dependencies (i.e., a package depends on its own products; package-to-product relationships will not include dependencies between a package and a product the package doesn't produce)
* Product-to-product dependencies

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
