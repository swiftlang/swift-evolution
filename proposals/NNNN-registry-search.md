# Package Registry Search

* Proposal: [SE-NNNN](NNNN-registry-search.md)
* Author: [Paul LeMarquand](https://github.com/plemarquand)
* Review Manager: TDB
* Status: **Awaiting review**
* Review: ([pitch](https://forums.swift.org/t/pitch-package-registry-search/86320))

## Introduction

[SE-0292](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0292-package-registry-service.md) introduced a package registry service for the Swift ecosystem. Its future directions section identified package search as a natural extension of the registry service. This pitch proposes adding a search endpoint to the [package registry specification](https://github.com/swiftlang/swift-package-manager/blob/main/Documentation/PackageRegistry/Registry.md) and a corresponding `swift package-registry search` subcommand to Swift Package Manager, enabling users to discover packages in registries by name, author, and other criteria.

## Motivation

Today, to use a package from a registry a user must already know its exact package identifier (in the form `scope.name`). There is no standardized mechanism for discovering packages within a registry.

This is a gap when comparing SwiftPM to other package ecosystems. npm provides `npm search`, PyPI has `pip search`, Cargo has `cargo search`, and NuGet has `dotnet package search`. Package discovery is a fundamental part of the package management workflow, and adding this at the registry protocol level offers benefits to both SwiftPM users as well as 3rd party clients.

[SE-0292](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0292-package-registry-service.md) anticipated this need in its future directions:

> The package registry API could be extended to add a search endpoint to allow users to search for packages by name, keywords, or other criteria. This endpoint could be used by clients like Swift Package Manager.

```
$ swift package-registry search LinkedList
LinkedList (github.com/mona/LinkedList) - One thing links to another.

$ swift package-registry search author:"Mona Lisa Octocat"
LinkedList (github.com/mona/LinkedList) - One thing links to another.
RegEx (github.com/mona/RegEx) - Expressions on the reg.
```

With [SE-0391](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0391-package-registry-publish.md) having introduced the `swift package-registry publish` subcommand alongside a standardized metadata schema, registries now have enough structured metadata to power search. This pitch builds on that foundation.

## Proposed Solution

We propose:

1. A new `GET /search` endpoint in the registry service specification
2. A new `swift package-registry search` subcommand in Swift Package Manager
3. A structured query syntax supporting free-text search, field-specific qualifiers, and logical operators
4. A formalized `GET /availability` endpoint, extending it to advertise optional capabilities.

The search endpoint is additive and therefore **optional** . Registries are not required to implement it, and clients must handle registries that do not support search. A registry that does not support search responds with `404 Not Found` to requests to `/search`. Registries that do support search advertise this capability through the `/availability` response so that clients can discover it without trial and error.

For registries that implement search the endpoint returns a paginated list of packages matching the query. Registries are free to use whatever backend technology is appropriate for their deployment (database queries, full-text search engines, etc.) as long as they conform to the API contract defined here.

## Detailed Design

### Registry Service Endpoint

#### Capability Advertisement

Because search is an optional endpoint, registries that support it need a way to advertise this capability to clients.

Swift Package Manager already performs a `GET /availability` request to check whether a registry is reachable before interacting with it. This endpoint is not currently part of any proposal or the registry specification, and exists only as an implementation detail in SwiftPM's `RegistryClient`. However, registries today implement this endpoint since without it Swift Package Manager marks the registry as not available and throws an error. Today the client checks the status code alone and discards the response body.

This pitch formalizes `GET /availability` and extends it to serve as a capability discovery mechanism. A registry SHOULD respond with a `200 OK` status and a JSON body listing its supported capabilities:
```
GET /availability HTTP/1.1
Host: packages.example.com
Accept: application/vnd.swift.registry.v1+json
```
```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Version: 1
```
```
{
  "capabilities": {
    "search": {}
  }
}
```

**Capabilities Object:**

The `capabilities` field is a JSON object where each key is a capability name and the value describes that capability. This response can be used to declare new package registry capabilities in the future. This pitch defines one capability:

|Capability|Value|Description|
| --- | --- | --- |
|search|{}|The registry supports the search endpoint|

The capability object is an empty object whose presence indicates that the registry supports search. Future capabilities for other features may declare more fine grained capabilities in this object.

A client SHOULD cache the capabilities response for the duration of its session.

**Backwards Compatibility:**

Registries that do not return a JSON body (or return an empty body) in their `/availability` response continue to work as they do today. A `200` status code indicates the registry is available, and the absence of a `capabilities` object means no optional features are advertised. Clients MUST NOT require a response body from `/availability`.

A registry that responds with `404` or `501` to `/availability` is treated as not supporting availability checks, which is the existing behaviour.

#### Search Packages

A client MAY search for packages by sending a `GET` request to `/search`.

```
GET /search?q={query} HTTP/1.1
Host: packages.example.com
Accept: application/vnd.swift.registry.v1+json
```

##### Query Parameters

|Parameter|Type|Required|Default|Description|
| --- | --- | --- | --- | --- |
|q|String|No|""|The search query string|
|limit|Integer|No|20|Maximum number of results to return (1-100)|
|offset|Integer|No|0|Number of results to skip for pagination|

If `q` is empty or omitted, the server SHOULD return an empty result set with no packages.

##### Query Syntax

The query string supports both free-text search and structured qualifiers. Free text matches against the package name, scope, and description. Qualifiers filter results to packages matching specific metadata fields. Spaces delimit separate search terms.

Multi-word values (in both free text and qualifier values) MUST be enclosed in double quotes:
```
GET /search?q="openapi+generator" HTTP/1.1
```
```
GET /search?q=scope:apple+"openapi+generator" HTTP/1.1
```
```
GET /search?q=author:"Mona+Lisa+Octocat" HTTP/1.1
```
**Free-text search:**
```
GET /search?q=networking HTTP/1.1
```

**Qualifier syntax:**
Qualifiers take the form `field:value` and filter results to packages where the specified metadata field matches the value. Multiple qualifiers and free-text terms may be combined in a single query.

|Qualifier|Metadata Field|Description|
| --- | --- | --- |
|scope:|scope|Filter by package scope|
|name:|name|Filter by package name|
|description:|description|Filter by package description|
|author:|author.name|Filter by author name|
|pkg:|N/A|Search for a specific package url ([purl](https://github.com/package-url/purl-spec))|

Qualifier values are case-insensitive. Registries SHOULD treat qualifier values as substring matches.

The `pkg:` qualifier allows for searching for a specific package via [purl](https://github.com/package-url/purl-spec), otherwise known as 'package url'. For example, `pkg:` `swift/mona/LinkedList@1.1.1` searches the `mona` scope for a package called `LinkedList` with a version specifier of `1.1.1`. The type of the purl url is always `swift`.

Registries MAY define additional qualifiers beyond those listed here to expose metadata they index locally (for example, internal tags or organization-specific fields). A registry that does not recognize a qualifier SHOULD respond with `400 Bad Request`.

**Combining qualifiers and free text:**

GET /search?q=scope:apple+networking HTTP/1.1

This searches for packages in the `apple` scope whose name or description matches "networking".

**Logical operators:**

The query syntax for the search endpoint is based on [AIP-160: Filtering](https://google.aip.dev/160), a standard for filtering collections in APIs. AIP-160 defines a string-based filter language; this pitch adopts a deliberately small subset of it suited to package discovery.

The supported subset is:

- **Bare literals** for free-text search, matching across the package name, scope, and description.
- **The has operator (`:`)** for qualifiers that filter on specific metadata fields.
- **Logical operators** `AND`, `OR`, and `NOT`/`-` for combining terms. Multiple terms separated by spaces are combined with implicit `AND`.

The following logical operators are supported:

|Operator|Syntax|Description|
| --- | --- | --- |
|AND|scope:apple networking|Both conditions must match (implicit)|
|OR|scope:apple OR scope:vapor|Either condition may match|
|NOT|`NOT scope:example`|Exclude packages matching the condition|

As in AIP-160, `OR` has higher precedence than `AND`. For example:
```
GET /search?q=networking+scope:apple+OR+scope:vapor HTTP/1.1
```
Returns packages matching "networking" in either the `apple` or `vapor` scope. This is equivalent to `networking AND (scope:apple OR scope:vapor)`.
```
GET /search?q=networking+NOT+scope:example HTTP/1.1
```

AIP-160 comparison operators (`=`, `!=`, `<`, `>`, `<=`, `>=`), the traversal operator (`.`) for nested structures, and wildcards (`*`) in string equality are intentionally excluded to keep the surface area small and predictable across registry implementations. Registries MAY adopt additional AIP-160 features in the future. For more information, see the [EBNF grammar.](https://google.aip.dev/assets/misc/ebnf-filtering.txt)

**Fuzzy matching:**

A registry MAY support fuzzy matching to handle typos and approximate search terms. For example, a query like `netwrking` could match packages containing "networking". The degree of fuzziness is left to the registry implementation. Registries that do not support fuzzy matching perform exact substring matching as described above.

##### Result Ordering

When a query is provided, the server SHOULD order results by query relevance. When no query is provided (empty `q`), the server returns an empty result set. Registries are free to use whatever ranking signals are appropriate for their implementation when a query is present (recency, popularity, internal quality metrics, etc.).

This pitch does not define a cross-registry ranking score. Clients aggregating results from multiple registries preserve each registry's server-side ordering; see [Swift Package Manager Subcommand](#swift-package-manager-subcommand) for how the CLI merges results.

##### Response

A server SHOULD respond with a `200 OK` status and a JSON object containing the search results.
```
HTTP/1.1 200 OK
Content-Type: application/json
Content-Version: 1
```
```
{
    "results": [
        {
            "identity": "mona.LinkedList",
            "summary": "One thing links to another.",
            "latestVersion": "1.1.1",
            "author": "Mona Lisa Octocat",
            "licenseURL": "https://github.com/mona/LinkedList/blob/main/LICENSE",
            "url": "https://packages.example.com/mona/LinkedList"
        },
        {
            "identity": "mona.RegEx",
            "summary": "Expressions on the reg.",
            "latestVersion": "2.0.0",
            "author": "Mona Lisa Octocat",
            "licenseURL": "https://github.com/mona/RegEx/blob/main/LICENSE",
            "url": "https://packages.example.com/mona/RegEx"
        }
    ],
    "total": 42,
    "offset": 0,
    "limit": 20
}
```

**Results Object:**

| Field         | Type     | Required | Description                                                                                                                                                                                                                                                                                                |
| ------------- | -------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| identity      | String   | Yes      | The package identifier in `scope.name` format                                                                                                                                                                                                                                                              |
| summary       | String   | No       | Short description of the package                                                                                                                                                                                                                                                                           |
| latestVersion | String   | No       | Most recent stable release.                                                                                                                                                                                                                                                                                |
| author        | String   | No       | Package author name                                                                                                                                                                                                                                                                                        |
| licenseURL    | String   | No       | URL of the package's license document                                                                                                                                                                                                                                                                      |
| url           | String   | No       | URL to the package's releases on this registry                                                                                                                                                                                                                                                             |
| registry      | String   | No       | Computed by the client; identifies the registry URL the result came from. Only included when a single search spans multiple registries. Omitted when all results come from one registry (either because only one is configured or `--registry` was passed). Not set by the server but computed by SwiftPM. |

**Pagination:**

|Field|Type|Required|Description|
| --- | --- | --- | --- |
|total|Integer|Yes|Total number of matching packages matching the query|
|offset|Integer|Yes|Current offset|
|limit|Integer|Yes|Limit applied to this response|

A given package identity MUST NOT appear in results more than once, and total MUST equal the number of unique packages matching the query, not the number of versions or artifacts.

For a given query string and constant pagination parameters, result ordering MUST be stable across requests in the same session. A client iterating `offset += limit` until `offset >= total` MUST visit every matching package exactly once and never visit the same package twice.

The server SHOULD include `Link` headers for pagination when additional results are available:
```
Link: </search?q=networking&limit=20&offset=0>; rel="first",
</search?q=networking&limit=20&offset=20>; rel="next",
</search?q=networking&limit=20&offset=40>; rel="last"
```

##### Errors

|Status|Description|
| --- | --- |
|400 Bad Request|Invalid query syntax or parameter values|
|404 Not Found|Search is not supported by this registry|
|429 Too Many Requests|Rate limit exceeded|

Error responses use [RFC 7807](https://tools.ietf.org/html/rfc7807) problem details:
```
{
"detail": "search query too long"
}
```
A server that does not support search SHOULD respond to requests to `/search` with `404 Not Found`. A client MUST handle the case where a registry does not implement the search endpoint.

### Swift Package Manager Subcommand

#### `swift package-registry search`

A new `swift package-registry search` subcommand enables searching configured registries from the command line.

**SYNOPSIS**
```
swift package-registry search [<query>]
[--limit <limit>] [--offset <offset>]
[--registry <url>] [--json]
```
**OPTIONS**

|Option|Description|
| --- | --- |
|<query>|Free-text search term|
|--limit <limit>|Maximum results to return (default: 20)|
|--offset <offset>|Skip N results for pagination (default: 0)|
|--registry <url>|Restrict search to a single registry (default: search all configured registries)|
|--json|Output results as JSON|
|||

By default, `swift package-registry search` searches **all configured registries** and aggregates the results. A common pattern is a workspace with a public default registry and a private company registry. Users generally want a single command to find packages regardless of which registry they live on. Passing `--registry <url>` narrows the search to a single registry.

When a single search spans more than one registry, the CLI annotates each result with the registry URL so users can distinguish identical identifiers served by different registries. When a search targets a single registry (either because only one is configured or `--registry` was used), the registry annotation is omitted to keep output terse.

Aggregated results preserve each registry's server-side ordering. The CLI interleaves results from multiple registries so users see a mix from each rather than all results from one registry before the next.

**EXAMPLES**

Search for packages by name:
```
$ swift package-registry search LinkedList
mona.LinkedList - One thing links to another. (v1.1.1)
```
Search by author:
```
$ swift package-registry search author:"Mona Lisa Octocat"
mona.LinkedList - One thing links to another. (v1.1.1)
mona.RegEx - Expressions on the reg. (v2.0.0)
```
Search with a scope filter:
```
$ swift package-registry search networking scope:apple
apple.swift-nio - Event-driven network application framework. (v2.60.0)
apple.swift-http-types - HTTP type definitions. (v1.0.3)
```
Search across multiple scopes:
```
$ swift package-registry search "networking scope:apple OR scope:vapor"
apple.swift-nio - Event-driven network application framework. (v2.60.0)
vapor.vapor - A server-side Swift HTTP framework. (v4.92.0)
```
Searching with multiple registries configured (public + private). The registry URL is shown per result to disambiguate:
```
$ swift package-registry search Logger
acme.Logger - Internal logging framework. (v3.2.0) [https://packages.acme.internal]
mona.Logger - A tiny logger. (v1.0.1) [https://packages.example.com]
```
JSON output:
```
$ swift package-registry search LinkedList --json
{
    "results": [
        {
            "identity": "mona.LinkedList",
            "summary": "One thing links to another.",
            "latestVersion": "1.1.1"
        }
    ],
    "total": 1,
    "offset": 0,
    "limit": 20
}
```

Multi-registry JSON output includes the `registry` field on each result:
```
$ swift package-registry search Logger --json
{
    "results": [
        {
            "identity": "acme.Logger",
            "summary": "Internal logging framework.",
            "latestVersion": "3.2.0",
            "registry": "https://packages.acme.internal"
        },
        {
            "identity": "mona.Logger",
            "summary": "A tiny logger.",
            "latestVersion": "1.0.1",
            "registry": "https://packages.example.com"
        }
    ],
    "total": 2,
    "offset": 0,
    "limit": 20
}
```

The subcommand constructs a query string from the provided query and sends it to the registry's `/search` endpoint. Users can include qualifiers directly in their search query (e.g., `author:"Mona"` is passed as `author:Mona` in the `q` parameter).

If the registry has previously advertised search support via its `/availability` response, the client sends the search request to the advertised URL. If the registry did not advertise search support (no `capabilities` object, or no `search` key), the client informs the user:
```
$ swift package-registry search LinkedList --registry https://nosearch.example.com
error: registry at 'https://nosearch.example.com' does not support search
```
### Searchable Metadata

The search endpoint leverages package metadata submitted during the `swift package-registry publish` flow defined in [SE-0391](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0391-package-registry-publish.md). The following metadata fields are searchable:

|Search Field|Metadata Source|
| --- | --- |
|Package scope|Package identifier|
|Package name|Package identifier|
|Description|metadata.description|
|Author|metadata.author.name|

Registries MAY index additional metadata beyond what is defined here.

`metadata.licenseURL` is intentionally **not** listed as a searchable field. The URL alone is not a reliable way to filter by license type, and requiring registries to introspect packages to determine the actual license places an undue burden on registry implementations. Adding first-class license filtering is addressed in [Future Directions](#license-detection-during-publish).

## Security

Search results MUST respect the same access controls as other registry endpoints. If a client is not authorized to access a package, that package MUST NOT appear in search results.

Registries SHOULD implement rate limiting on the search endpoint to prevent abuse. When rate limited, the server responds with `429 Too Many Requests` and a `Retry-After` header as specified in the registry service specification.

Search queries MUST be sanitized by the server to prevent injection attacks against the underlying search backend. Registries SHOULD impose reasonable limits on query string length.

## Impact on Existing Packages

This is a purely additive change. The search endpoint is optional and existing registries are unaffected. A registry that does not implement `/search` simply returns `404 Not Found`, and clients handle this gracefully by informing the user that the registry does not support search. No changes to existing endpoints or package formats are required.

## Alternatives Considered

### Query string vs. individual query parameters

An alternative design would use individual query parameters for each searchable field rather than embedding qualifiers in the `q` parameter:
```
GET /search?name=LinkedList&author=Mona&scope=mona
```
This approach is simpler to parse on the server but less flexible. The qualifier syntax `field:value` within a single `q` parameter follows the conventions established by GitHub, npm, and other search APIs. It allows users to construct queries naturally in both the CLI and API contexts, and is extensible without requiring API changes when new searchable fields are added.

### Returning full release metadata in search results

Search results could include the complete release metadata (manifests, checksums, signing information) for each result. This was rejected because search results should be lightweight. Clients that need full metadata can fetch it from the existing `GET /{scope}/{name}/{version}` endpoint after discovering a package through search.

## Future Directions

### Result Sorting Options

Registries could support alternative sort orders beyond the default relevance-based ranking. A `sort` query parameter could be added:
```
GET /search?q=networking&sort=recent
GET /search?q=networking&sort=name
```
### Package Collections Integration

Search results could be used to populate [SE-0291 Package Collections](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0291-package-collections.md), enabling users to curate collections based on search queries.

### Suggested Packages

Registries could provide a suggestions endpoint for autocomplete-style search, returning results as the user types.

### Platform and Swift Version Filtering

As the ecosystem evolves, filtering packages by supported platforms or Swift language version could be valuable:
```
GET /search?q=networking+platform:linux+swift:6.0
```
This would require packages to declare platform and Swift version support in a machine-readable way.

### License Detection During Publish

A design goal of this pitch is that a registry can offer `/search` using only the information captured in `package-metadata.json` today — no package introspection required on the server. That constraint is why this pitch drops `licenseURL` as a searchable field: the URL alone is not a reliable way to identify a license (e.g., MIT, Apache-2.0, GPLv3), and requiring each registry to fetch and classify license text is a significant burden that invites inconsistent results across registries.

A better path is to do the detection once, in Swift Package Manager, at publish time. `swift package-registry publish` could identify the package's license (for example, by matching against SPDX identifiers) and include the detected license type as a structured field in `package-metadata.json`. Registries could then index this structured field and clients could filter with a `license:MIT` style qualifier, with consistent semantics across registries. This is out of scope for this pitch but is a natural follow-up.

### `swift package info`

Search results are intentionally lightweight. A separate `swift package info <identity>` subcommand could present the full metadata for a single package — description, author, readme URL, repository URLs, versions, and any registry-supplied augmentation (platform support, repo analytics, etc.) — using the existing `GET /{scope}/{name}` and `GET /{scope}/{name}/{version}` endpoints. The fields available by default mirror what is already captured in `package-metadata.json`; individual registries may enrich the response with optional fields. Designing this subcommand (and any additions to publish-time metadata it needs) is left to a follow-on pitch.