# Package Registry Publish

* Proposal: [SE-NNNN](NNNN-package-registry-publish.md)
* Author: [Yim Lee](https://github.com/yim-lee)
* Review Manager: TBD
* Status: **Awaiting implementation**

## Introduction

A package registry makes packages available to consumers. Starting with Swift 5.7,
SwiftPM supports dependency resolution and package download using any registry that 
implements the [service specification](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md) proposed alongside with [SE-0292](https://github.com/apple/swift-evolution/blob/main/proposals/0292-package-registry-service.md).
SwiftPM does not yet provide any tooling for publishing packages, so package authors 
must manually prepare the contents (e.g., source archive) and interact 
with the registry on their own to publish a package release. This proposal 
aims to standardize package publishing such that SwiftPM can offer a complete and 
well-rounded experience for using package registries.

## Motivation

Publishing package release to a Swift package registry generally involves these steps:
  1. Prepare package source archive by using the [`swift package archive-source` subcommand](https://github.com/apple/swift-evolution/blob/main/proposals/0292-package-registry-service.md#archive-source-subcommand)
  1. Sign the archive (if required by the registry)
  1. Gather package release metadata
  1. [Authenticate](https://github.com/apple/swift-evolution/blob/main/proposals/0378-package-registry-auth.md) (if required by the registry)
  1. Send the archive (and signature if any) and metadata by calling the ["create package release" API](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-6)
  1. Check registry server response to determine if publication has succeeded or failed (if the registry processes request synchronously), or is pending (if the registry processes request asynchronously).

SwiftPM can streamline the workflow by combining all of these steps into a single 
`publish` command.

## Proposed solution

We propose to introduce a new `swift package-registry publish` subcommand to SwiftPM 
as well as standardization on package release metadata and package signing to ensure a
consistent user experience for publishing packages.

## Detailed design

### Package release metadata

Typically a package release has metadata associated with it, such as URL of the source
code repository, license, etc. In general, metadata gets set when a package release is
being published, but a registry service may allow modifications of the metadata afterwards.

The current [registry service specification](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md) states that:
  - A client (e.g., package author, publishing tool) may provide metadata for a package release by including it in the ["create a package release" request](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#462-package-release-metadata). The registry server will store the metadata and include it in the ["fetch information about a package release" response](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-2).
  - If a client does not include metadata, the registry server may populate it unless the client specifies otherwise (i.e., by sending an empty JSON object `{}` in the "create a package release" request).

It does not, however, define any requirements or server-client API contract on the 
metadata contents. We would like to change that by proposing the following:
  - Package release metadata will continue to be sent as a JSON object.
  - Package release metadata must be sent as part of the "create a package release" request and adhere to the [schema](#package-release-metadata-standards).
  - Package release metadata may be included in the "create a package release" request in one of these ways, depending on registry server support:
    + A multipart section named `metadata` in the request body
    + A file named `package-metadata.json` **inside** the source archive being published
  - Registry server may allow and/or populate additional metadata by expanding the schema, but not alter any predefined properties.
  - Registry server will continue to include metadata in the "fetch information about a package release" response.
  
#### Package release metadata standards

Package release metadata submitted to a registry must be a JSON object of type 
[`PackageRelease`](#packagerelease-type), the schema of which is defined below.

<details>

<summary>Expand to view <a href="https://json-schema.org/specification.html">JSON schema</a></summary>  

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md",
  "title": "Package Release Metadata",
  "description": "Metadata of a package release.",
  "type": "object",
  "properties": {
    "author": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",      
          "description": "Name of the author."
        },  
        "email": {
          "type": "string",      
          "description": "Email address of the author."
        },              
        "description": {
          "type": "string",      
          "description": "A description of the author."
        },
        "organization": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",      
              "description": "Name of the organization"
            },  
            "email": {
              "type": "string",      
              "description": "Email address of the organization."
            },              
            "description": {
              "type": "string",      
              "description": "A description of the organization."
            },        
            "url": {
              "type": "string",      
              "description": "URL of the organization."
            },        
          },
          "required": ["name"]
        },                
        "url": {
          "type": "string",      
          "description": "URL of the author."
        },        
      },
      "required": ["name"]
    },
    "description": {
      "type": "string",      
      "description": "A description of the package release."
    },
    "license": {
      "type": "string",
      "description": "URL of the package release's license document."
    },
    "readmeURL": {
      "type": "string",      
      "description": "URL of the README specifically for the package release or broadly for the package."
    },
    "repositoryURLs": {
      "type": "array",
      "description": "Code repository URL(s) of the package release.",
      "items": {
        "type": "string",
        "description": "Code repository URL"
      }      
    }
  }
}
```

</details>

##### `PackageRelease` type

| Property          | Type                | Description                                      | Required |
| ----------------- | :-----------------: | ------------------------------------------------ | :------: |
| `author`          | [Author](#author-type) | Author of the package release. | |
| `description`     | String | A description of the package release. | |
| `license`         | String | URL of the package release's license document. | |
| `readmeURL`       | String | URL of the README specifically for the package release or broadly for the package. | |
| `repositoryURLs`  | Array | Code repository URL(s) of the package. This can be omitted if the package does not have source control representation. Otherwise, the registry server must ensure that these URLs are searchable using the ["lookup package identifiers registered for a URL" API](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#45-lookup-package-identifiers-registered-for-a-url). | |

##### `Author` type

| Property          | Type                | Description                                      | Required |
| ----------------- | :-----------------: | ------------------------------------------------ | :------: |
| `name`            | String | Name of the author. | ✓ |
| `email`           | String | Email address of the author. | |
| `description`     | String | A description of the author. | |
| `organization`    | [Organization](#organization-type) | Organization that the author belongs to. | |
| `url`             | String | URL of the author. | |

##### `Organization` type

| Property          | Type                | Description                                      | Required |
| ----------------- | :-----------------: | ------------------------------------------------ | :------: |
| `name`            | String | Name of the organization. | ✓ |
| `email`           | String | Email address of the organization. | |
| `description`     | String | A description of the organization. | |
| `url`             | String | URL of the organization. | |

### Package signing

A registry may require packages to be signed. In order for SwiftPM to be able to
download and handle signed packages from a registry, we propose to standardize 
package signature format and establish server-client API contract on package
signing.

#### Package signature

Package signature format will be identified by the underlying standard/technology 
(e.g., Cryptographic Message Syntax (CMS), JSON Web Signature (JWS), etc.) and 
version number. In the initial release, all signatures will be in [CMS](https://www.rfc-editor.org/rfc/rfc5652.html).

| Signature format ID | Description                                               |
| ------------------- | --------------------------------------------------------- |
| `cms-1.0.0`         | Version 1.0.0 of package signature in CMS                 |

A registry server that requires package signing must select from the active
signature formats and make its supported format(s) known.

##### Package signature format `cms-1.0.0`

Package signature format `cms-1.0.0` uses CMS.

| CMS Attribute                  | Details                                                   |
| ------------------------------ | --------------------------------------------------------- |
| Content type                   | [Signed-Data](https://www.rfc-editor.org/rfc/rfc5652.html#section-5) |
| Encapsulated data              | The content being signed ([`EncapsulatedContentInfo.eContent`](https://www.rfc-editor.org/rfc/rfc5652.html#section-5.2)) is omitted since we are constructing an external signature. |
| Message digest algorithm       | SHA-256, computed on the package source archive.          |
| Signature algorithm            | ECDSA P-256                                               |
| Number of signatures           | 1                                                         |
| Certificate                    | Certificate that contains the signing key. It is up to the registry to define the certificate policy (e.g., trusted root(s)). |

The signature, represented in CMS, will be base64-encoded then included as part
of the "create a package release" API request. 

A registry receiving such signed package will:
  - Check if the signature format (`cms-1.0.0`) is accepted
  - Validate the signature is well-formed according to the signature format
  - Validate the certificate chain meets registry policy
  - Extract public key from the certificate and use it to verify the signature

Then the registry will process the package and save it for client downloads if publishing is successful.

The registry must include signature information in the "fetch information about a package release" API 
response to indicate the package is signed and the signature format (`cms-1.0.0`).

After downloading a signed package SwiftPM will:
  - Check if the signature format (`cms-1.0.0`) is supported
  - Validate the signature is well-formed according to the signature format
  - Validate that the signed package complies with the locally-configured signing policy
  - Extract public key from the certificate and use it to verify the signature

#### New `package sign` subcommand

There will be a new subcommand `package sign` dedicated to package signing.

```manpage
> swift package sign --help
OVERVIEW: Sign a package archive

USAGE: package sign <input-path> <output-path>

ARGUMENTS:
  <input-path>            The path to the package source archive to be signed
  <output-path>           The path the output signature file will be written to

OPTIONS:
  --signature-format      Signature format identifier. Defaults to 'cms-1.0.0'.

  --signing-identity      The label of the signing identity to be retrieved from the system's secrets store if supported

  --private-key-path      The path to the certificate's PKCS#8 private key (DER-encoded)
  --cert-chain-paths      Paths to all of the certificates (DER-encoded) in the chain. The certificate used for signing must be listed first and the root certificate last.
```

A signing identity encompasses a private key and a certificate. On 
systems where it is supported SwiftPM can look for a signing identity 
using the query string given via the `--signing-identity` option. This
feature will be available on macOS through Keychain in the initial 
release, so a certificate and its private key can be located by the
certificate label alone.

Otherwise, both `--private-key-path` and `--cert-chain-paths` must be
provided to locate the signing key and certificate.

#### Server-side requirements for package signing

As [mentioned previously](#package-signature), a registry server that requires package signing 
must advertise the signing requirements, which include:
  - Supported signature format(s)
  - Any requirements for certificates used in signing
  
This can be done by implementing the ["package publish requirements" API](#package-publish-requirements-api). A
client can then generate package signature based on information returned by this
API.

A registry must also modify the ["create package release" API](#create-package-release-api) to allow
signature in the request, as well as the response for the ["fetch package release metadata" API](#fetch-package-release-metadata-api)
to include signature information.
    
#### SwiftPM handling of signed packages

Users will be able to configure how SwiftPM handles packages downloaded from a 
registry. In the user-level `registries.json` file, which by default is located at 
`~/.swiftpm/configuration/registries.json`, we will introduce a new `security` key:

```json
{
  "security": {
    "[default]": {
      "signing": {
        "required": <BOOL>,
        "trustedRootCertificatesPath": <STRING>
      }      
    },
    "internal.example.com": {
      ...
    }    
  }, 
  ...
}
```

The key `[default]` in the `security` dictionary specifies settings applied to
all registries. User may override settings for a registry by adding an entry
in `security` using the registry's domain as key (e.g., `internal.example.com`).

- `signing.required`: Defaults to `true`, SwiftPM requires all packages to be signed. Set this to `false` to allow unsigned packages.
- `signing.trustedRootCertificatesPath`: Defaults to `~/.swiftpm/configuration/trust-root-certs/packages/`, this is the absolute path to the directory containing trusted root certificates. Any certificates used for package signing must chain to these or those found in SwiftPM's default trust store.

When SwiftPM downloads a package release from registry via the 
["download source archive" API](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-4), it will:
  - Fetch package release metadata from the registry to see if the package is signed and if so, the signature and signature format.
  - Extract security settings for the registry from `registries.json`, which would be a combination of default values and any registry-specific overrides.
  - Check if the package is allowed based on security settings
  - Validate the signature according to the signature format
  - Save the package signature and checksum to the local fingerprint storage for [trust on first use (TOFU)](https://en.wikipedia.org/wiki/Trust_on_first_use)

### New `package-registry publish` subcommand

The new `package-registry publish` subcommand will create a package
source archive, sign it, and publish it to a registry.

```manpage
> swift package-registry publish --help
OVERVIEW: Publish a package release to registry

USAGE: package-registry publish <id> <version>

ARGUMENTS:
  <id>                    The package identifier
  <version>               The package release version being created

OPTIONS:
  --url                   The registry URL
  --output-directory      The path of the directory where output file(s) will be written

  --metadata-path         The path to the package metadata JSON file

  --signature-format      Signature format identifier. Defaults to 'cms-1.0.0'.

  --signing-identity      The label of the signing identity to be retrieved from the system's secrets store if supported

  --private-key-path      The path to the certificate's PKCS#8 private key (DER-encoded)
  --cert-chain-paths      Paths to all of the certificates (DER-encoded) in the chain. The certificate used for signing must be listed first and the root certificate last.  
```

- `id`: The package identifier in the `<scope>.<name>` notation as defined in [SE-0292](https://github.com/apple/swift-evolution/blob/main/proposals/0292-package-registry-service.md#package-identity). It is the package author's responsibility to register the package identifier with the registry beforehand.
- `version`: The package release version in [SemVer 2.0](https://semver.org) notation.
- `url`: The URL of the registry to publish to. SwiftPM will try to determine the registry URL by searching for a scope-to-registry mapping or use the `[default]` URL in `registries.json`. The command will fail if this value is missing.
- `output-directory`: The path of the output directory. SwiftPM will write to the package directory by default.

SwiftPM will call the registry's ["package publish requirements" API](#package-publish-requirements-api)
to determine how metadata should be included and whether signing is
required. Depending on the response, the following may be required
as well:
  - `metadata-path`: The path to the JSON file containing [package release metadata](#package-release-metadata). If the registry expects metadata to be sent as part of the request body, then SwiftPM will include the content of this file. Otherwise, it is the package author's responsibility to make sure the metadata file is present in the package directory so that it gets included in the package source archive.
  - `signature-format`: Signature format identifier. [`cms-1.0.0`](#package-signature-format-cms-100) is used by default.
  - `signing-identity`: The label that identifies the signing identity to use for package signing in the system's secrets store if supported. See also the [`package sign` subcommand](#new-package-sign-subcommand) for details.
  - `private-key-path`: Required for package signing unless `signing-identity` is specified, this is the path to the private key used for signing.
  - `cert-chain-paths`: Required for package signing unless `signing-identity` is specified, this is the signing certificate chain.

Prerequisites:
- Run [`swift package-registry login`](https://github.com/apple/swift-evolution/blob/main/proposals/0378-package-registry-auth.md#new-login-subcommand) to authenticate registry user if needed. 
- The user has the necessary permissions to call the ["create a package release" API](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-6) for the package identifier.

Using these inputs, SwiftPM will:
  - Generate source archive for the package release
  - Sign the source archive if needed
  - Make HTTP request to the "create a package release" API
  - Check server response for any errors

### Changes to the registry service specification

| New       | Method | Path                             | Description                                          |
| :-------: | :----: | -------------------------------- | ---------------------------------------------------- |
| Yes       | `GET`  | `/publish-requirements`          | Specify requirements for publishing package release |
| [No](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-6) | `PUT`  | `/{scope}/{name}/{version}`      | Create a package release                             |
| [No](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-2) | `GET`  | `/{scope}/{name}/{version}`      | Fetch metadata for a package release                 |

#### Package publish requirements API

All registries must implement this new endpoint for fetching package 
publishing requirements. The new [`package-registry publish` subcommand](#new-package-registry-publish-subcommand) 
in SwiftPM will use information retrieved from this API to determine how 
package release metadata should be included in the 
[create package release request](#create-package-release-api), and whether package signing is required.

```
GET /publish-requirements HTTP/1.1
Host: packages.example.com
Accept: application/vnd.swift.registry.v1+json
```

The server must respond with a status code of `200` (OK) and the `Content-Type` 
header `application/json`.

```
HTTP/1.1 200 OK
Content-Version: 1
Content-Type: application/json
Content-Length: 511

{
  "metadata": {
    "location": ["in-request", "in-archive"]
  },
  "signing": {
    "required": true,
    "acceptedSignatureFormats": ["cms-1.0.0"],
    "trustedRootCertificates": [...]
  }
}
```

The response body must contain a JSON object containing the following fields:

| Key                                     | Type    | Description                              |
| --------------------------------------- | :-----: | ---------------------------------------- |
| `metadata.location`                     | Array   | How package release metadata should be included: `in-request` for [multipart section in request](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#462-package-release-metadata), or `in-archive` for `package-metadata.json` file inside package source archive. SwiftPM gives precedence to the `in-archive` method if both `in-request` and `in-archive` are supported by the registry. |
| `signing.required`                      | Boolean | If package source archive must be signed |
| `signing.acceptedSignatureFormats`      | Array   | An array of accepted [package signature formats](#package-signature) (e.g., `cms-1.0.0`). Optional if package signing is not required. |
| `signing.trustedRootCertificates`       | Array   | An array of trusted root certificates (PEM-encoded) that signing certificates must chain to. Optional if package signing is not required. |

A registry server may include additional fields for information
not covered by those listed in the table above. For example, a 
registry may add `documentationsURL` which points to the location 
where detailed documentations on package publishing can be found.

#### Create package release API

A registry must update [this existing endpoint](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-6) to handle package release 
metadata as described in a [previous section](#package-release-metadata) of this document. In particular,
  - Metadata is now required
    - Client must include metadata in the request
    - Empty metadata is not allowed in the request
  - Metadata may be submitted in two ways, with the `in-archive` method being new.
  - Values provided with the `repositoryURLs` JSON key must be searchable

If package signing is required, a client must identify the signature format
in the `X-Swift-Package-Signature-Format` HTTP request header so that the
server can process the signature accordingly. Additional request headers
may be needed depending on the signature format.

The signature is sent as part of the request body:

```
PUT /mona/LinkedList?version=1.1.1 HTTP/1.1
Host: packages.example.com
Accept: application/vnd.swift.registry.v1+json
Content-Type: multipart/form-data;boundary="boundary"
Content-Length: 336
Expect: 100-continue
X-Swift-Package-Signature-Format: cms-1.0.0

--boundary
Content-Disposition: form-data; name="source-archive"
Content-Type: application/zip
Content-Length: 32
Content-Transfer-Encoding: base64

gHUFBgAAAAAAAAAAAAAAAAAAAAAAAA==

--boundary
Content-Disposition: form-data; name="source-archive-signature"
Content-Type: application/octet-stream
Content-Length: 88
Content-Transfer-Encoding: base64

l1TdTeIuGdNsO1FQ0ptD64F5nSSOsQ5WzhM6/7KsHRuLHfTsggnyIWr0DxMcBj5F40zfplwntXAgS0ynlqvlFw==
```

#### Fetch package release metadata API

A registry may update [this existing endpoint](https://github.com/apple/swift-package-manager/blob/main/Documentation/Registry.md#endpoint-2) for the [metadata changes](#package-release-metadata)
described in this document.

If a registry requires package signing, it must include a `signing` JSON object
in the response:

```json
{
  "id": "mona.LinkedList",
  "version": "1.1.1",
  "resources": [
    {
      "name": "source-archive",
      "type": "application/zip",
      "checksum": "a2ac54cf25fbc1ad0028f03f0aa4b96833b83bb05a14e510892bb27dea4dc812"
    }
  ],
  "metadata": { ... },
  "signing": {
    "signatureBase64Encoded": "l1TdTeIuGdNsO1FQ0ptD64F5nSSOsQ5WzhM6/7KsHRuLHfTsggnyIWr0DxMcBj5F40zfplwntXAgS0ynlqvlFw==",
    "signatureFormat": "cms-1.0.0"
  }
}
```

A client can use the API response to determine if a package is signed and 
handle it accordingly.

## Security

Package signing can offer better authenticity guarantees by allowing package
authors to sign their source archives before publishing them to the registry.
The signature can include information about the package authors, and package
users will be able to control the kind(s) of packages they trust by specifying a
local validation policy. This can include a trust on first use approach, or by
validating against a pre-configured set of trusted roots.

It is important to note that package signing as proposed in this document 
does not validate that a package is published by a specific entity. Instead, 
it validates that a package is published by an entity who can obtain a 
signing certificate that meets the requirements defined by the registry,
which could be anybody. As such, it does not provide any protection against
malware, and it would be wrong to assume that signed packages can be trusted
unconditionally.

### Package release metadata signing

Package release metadata submitted as `package-metadata.json` in a [signed package](#package-signing) 
is considered signed and not modifiable. Otherwise, the registry server may override the
metadata and/or allow it to be edited afterwards. It is recommended that package authors 
use `package-metadata.json` to submit metadata if this method and package signing are 
supported by the registry. 

## Impact on existing packages

Current packages won't be affected by changes in this proposal.

## Alternatives considered

### Signing package source archive vs. manifest

A package manifest is a reference list of files that are present in the 
source archive. We considered an approach where SwiftPM would produce 
such manifest, sign the manifest instead of the source archive,
then create a new archive containing the source archive, manifest, and
signature file. This way the archive and its signature can be distributed
by the registry as a single file. 

However, given the potential complications with extracting files from the
archive and verifying manifest contents, moreover there is no restriction
that would require single-file download (i.e., SwiftPM can download the 
source archive and signature separately), we have decided to take the approach
covered in previous sections of this proposal. 

The steps to publish a signed package are:
1. SwiftPM generates source archive for the package
1. SwiftPM generates signature of the source archive
1. SwiftPM uploads both source archive and signature to the registry via a single HTTP request
1. Registry processes the source archive and adds its signature to the package release metadata response

The steps to download a signed package are:
1. SwiftPM downloads source archive for the package release
1. SwiftPM fetches package release metadata from the registry
1. SwiftPM reads signature from the metadata received in the previous step

## Future directions

### Support encrypted private keys

Private keys are encrypted typically. SwiftPM commands that have private key
as input, such as `package sign` and `package-registry publish`, should support
reading encrypted private key. This could mean modifying the command to prompt
user for the passphrase if needed, and adding a `--private-key-passphrase` 
option to the command for non-interactive/automation use-cases.

### Transitive trust

SwiftPM's trust on first use (TOFU) mitigation could be further improved by 
including fingerprint and signature information in `Package.resolved` 
(or another similar file), which then gets included in the package content. 
Including such security metadata would allow distributing information about 
direct and transitive dependencies across the ecosystem much faster than a 
local-only TOFU without requiring a centralized database/service to vend 
this information.

```json
{
  "pins": [
    {
      "identity": "mona.LinkedList",
      "kind": "registry",
      "location": "https://packages.example.com/mona/LinkedList",
      "state": {
        "version": "0.12.0"
      },
      "signing": {
        "signatureBase64Encoded": "l1TdTeIuGdNsO1FQ0ptD64F5nSSOsQ5WzhM6/7KsHRuLHfTsggnyIWr0DxMcBj5F40zfplwntXAgS0ynlqvlFw==",
        "signatureFormat": "cms-1.0.0"
      }
    },
    {
      "identity": "Foo",
      "kind": "remoteSourceControl",
      "location": "https://github.com/something/Foo.git",
      "state": {
        "revision": "90a9574276f0fd17f02f58979423c3fd4d73b59e",
        "version": "1.0.2",
      }
    }    
  ],
  "version": 2
}
```
