# Package Collections

* Proposal: [SE-0291](0291-package-collections.md)
* Authors: [Boris Bügling](https://github.com/neonichu), [Yim Lee](https://github.com/yim-lee), [Tom Doron](https://github.com/tomerd)
* Review Manager: [Tom Doron](https://github.com/tomerd)
* Implementation: [apple/swift-package-manager#3030](https://github.com/apple/swift-package-manager/pull/3030)
* Status: **Returned for revision**

## Introduction

This is a proposal for adding support for **Package Collections** to SwiftPM. A package feed is a curated list of packages and associated metadata which makes it easier to discover an existing package for a particular use case. SwiftPM will allow users to subscribe to these collections, search them via the `swift package-collections` command-line interface, and will make their contents accessible to any clients of libSwiftPM. This proposal is focused on the shape of the command-line interface and the format of configuration data related to package collections.

We believe there are three different components in the space of package discovery with different purposes:

**Package Registry** is focused on hosting and serving package sources as an alternative to fetching them directly from git. The goal is to provide better immutability, durability and potentially improve performance and security. This initiative is in-progress and governed by [a separate proposal](https://github.com/apple/swift-evolution/pull/1179).

**Package Index** is focused for providing a search index for packages. The goal is to improve discoverability of packages that may be hosted anywhere, and provide a rich set of metadata that helps making informed decisions when choosing dependencies. The Index indexes the package core metadata available in Package.swift as well as additional metadata from additional and external sources. An example of a package index is https://swiftpackageindex.com.

**Package Collections** which are the subject of this proposal are closer to the Package Index than to the Package Registry. Collections are also designed to make discovery easier, but focused on simpler curation lists that can be easily shared rather than on larger scale indexing and ranking system that requires infrastructure. This design is the first step in teaching SwiftPM about discovery of packages and future work to support Package Indexes can build on this initial design.


## Motivation

Currently, it can be difficult to discover packages that fit particular use cases.  There is also no standardized way of accessing metadata about a package which is not part of the package manifest itself. We envision educators and community influencers publishing package collections to go along with course materials or blog posts, removing the friction of using packages for the first time and the cognitive overload of deciding which packages are useful for a particular task. We also envision enterprises using collections to narrow the decision space for their internal engineering teams, focusing them on a trusted set of vetted packages.

Exposing the data of package collections via libSwiftPM and the `swift package-collections` command-line interface will also allow other tools to leverage this information and provide a richer experience for package discovery that is configured by the user in one central place.


## Proposed solution

We propose to introduce a new concept called **Package Collections** to the Swift package ecosystem. Collections are authored as static JSON documents and contain a list of packages and additional metadata per package. They are published to a web server or CDN-like infrastructure making them accessible to users. SwiftPM will gain new command-line interface for adding and removing collections and will index them in the background, allowing users to more easily discover and integrate packages that are included in the collections.

For example, a course instructor knows they intend to teach with a set of several packages for their class. They can construct a feed JSON file, representing those packages. Then, they can post that JSON file to a GitHub repo or a website, giving the URL to that JSON file to all their students. Students use SwiftPM to add the instructor's feed to their SwiftPM configuration, and any packages the instructor puts into that feed can be easily used by the students.


## Detailed design

We propose to add a new sets of commands under a `swift package-collections` command-line interface that support the following workflows:

1. Managing collections
2. Querying metadata for individual packages
3. Searching for packages and modules across collections

We also propose adding a new per-user SwiftPM configuration file which will initially store the list of collections a user has configured, but can later be used for other per-user configuration for SwiftPM.

### Example

A course instructor shares a feed with packages needed for some assignments. The participants can add this feed to their set of collections:

```
$ swift package-collections add https://www.example.com/packages.json
Added "Packages for course XYZ" to your package collections.
```

This will add the given feed to the user's set of collections for querying metadata and search.

One of the assignments requires parsing a YAML file and instead of searching the web, participants can search the curated feed for packages that could help with their task:

```
$ swift package-collections search --keywords yaml
https://github.com/jpsim/yams: A sweet and swifty YAML parser built on LibYAML.
...
```

This will perform a string-based search across various metadata fields of all packages, such as the description and name. Results will contain URL and description (if any) of each match.

Once a suitable package has been identified, there will also be the ability to query for more metadata, such as available versions, which will be required to actually depend on the package in practice.

```
$ swift package-collections describe https://github.com/jpsim/yams
Description: A sweet and swifty YAML parser built on LibYAML.
Available Versions: 4.0.0, 3.0.0, ...
Watchers: 14
Readme: https://github.com/jpsim/Yams/blob/master/README.md
Authors: @norio-nomura, @jpsim
--------------------------------------------------------------
Latest Version: 4.0.0
Package Name: Yams
Modules: Yams, CYaml
Supported Platforms: iOS, macOS, Linux, tvOS, watchOS
Supported Swift Versions: 5.3, 5.2, 5.1, 5.0
License: MIT
CVEs: ...
```

This will list the basic metadata for the given package, as well as more detailed metadata for the latest version of the package. Available metadata for a package can incorporate data from the feed itself, as well as data discovered by SwiftPM.  For example, by querying the package's repository or gathering data from the source code hosting platform being used by the package.


### Profiles

A user can organise their package collections into multiple profiles, if desired. When adding a feed, an optional profile can be specified and each command also accepts an optional `--profile` parameter. This can be useful if the user is part of multiple organisations or is using different sets of collections for disjunct use cases. There is an implicit default profile that will be used if the `--profile` parameter is omitted, so the use of profiles is entirely optional. Each of the following commands has an optional `--profile` parameter.

To list all the profiles the user has created, the `profile-list` command can be used. Once a profile contains no more collections, it will not appear in this list anymore.

```
$ swift package-collections profile-list [--json]
Organization 1 Profile
Organization 2 Profile
...
```



### Manage Package Collections

#### List

The list command lists all collections that are configured by the user. The result can optionally be returned as JSON for integration into other tools.

```
$ swift package-collections list [--json] [--profile NAME]
My organisation's packages - https://example.com/packages.json
...
```


#### Manual refresh

The refresh command refreshes any cached data manually. SwiftPM will also automatically refresh data under various conditions, but some queries such as search will rely on locally cached data.

```
$ swift package-collections refresh [--profile NAME]
Refreshed 23 configured package collections.
```


#### Add

The add command adds a feed by URL, with an optional order hint, to the user's list of configured collections. The order hint will influence ranking in search results and can also potentially be used by clients of SwiftPM to order results in a UI, for example.


```
$ swift package-collections add https://www.example.com/packages.json [--order N] [--profile NAME]
Added "My organisation's packages" to your package collections.
```


#### Remove

The remove command removes a feed by URL from the user's list of configured collections.

```
$ swift package-collections remove https://www.example.com/packages.json [--profile NAME]
Removed "My organisation's packages" from your package collections.
```


#### Metadata and packages of a single feed

The info command shows the metadata and included packages for a single feed. This can be used for both collections that have been previously added to the list of the user's configured collections, as well as to preview any other collections.

```
$ swift package-collections describe-collection https://www.example.com/packages.json [--profile NAME]
Name: My organisation's packages
Source: https://www.example.com/packages.json
Description: ...
Keywords: best, packages
Created At: 2020-05-30 12:33
Packages:
    https://github.com/jpsim/yams
    ...
```



### Get metadata for a single package

Note: Collections will be limited in the number of major and minor versions they store per package. For each major/minor combination that is being stored, only data for the latest patch version will be present.

#### Metadata for the package itself

The info shows the metadata from the package itself. The result can optionally be returned as JSON for integration into other tools.

```
$ swift package-collections describe [--json] [--profile NAME] https://github.com/jpsim/yams
Description: A sweet and swifty YAML parser built on LibYAML.
Available Versions: 4.0.0, 3.0.0, ...
Watchers: 14
Readme: https://github.com/jpsim/Yams/blob/master/README.md
Authors: @norio-nomura, @jpsim
--------------------------------------------------------------
Latest Version: 4.0.0
Package Name: Yams
Modules: Yams, CYaml
Supported Platforms: iOS, macOS, Linux, tvOS, watchOS
Supported Swift Versions: 5.3, 5.2, 5.1, 5.0
License: MIT
CVEs: ...
```


#### Metadata for a package version

When passing an additional `--version` parameter, the info command shows the metadata for a single package version. The result can optionally be returned as JSON for integration into other tools.

```
$ swift package-collections describe [--json] [--profile NAME] --version 4.0.0 https://github.com/jpsim/yams
Package Name: Yams
Version: 4.0.0
Modules: Yams, CYaml
Supported Platforms: iOS, macOS, Linux, tvOS, watchOS
Supported Swift Versions: 5.3, 5.2, 5.1, 5.0
License: MIT
CVEs: ...
```



### Search

#### String-based search

The search command does a string-based search when using the `--keyword` option and returns the list of packages that match the query. The result can optionally be returned as JSON for integration into other tools.

```
$ swift package-collections search [--json] [--profile NAME] --keywords yaml
https://github.com/jpsim/yams: A sweet and swifty YAML parser built on LibYAML.
...
```


#### Module-based search

The search command does a search for a specific module name when using the `--module` option. The result can optionally be returned as JSON for integration into other tools. Lists the newest version the matching module can be found in. This will display more metadata per package than the string-based search as we expect just one or very few results for packages with a particular module name.

```
$ swift package-collections search [--json] [--profile NAME] --module yams
Package Name: Yams
Latest Version: 4.0.0
Description: A sweet and swifty YAML parser built on LibYAML.
--------------------------------------------------------------
...
```



### Configuration file

The global configuration file will be expected at this location:


```
~/.swiftpm/config
```


This file will be stored in a `.swiftpm` directory in the user's home directory (or its equivalent on the specific platform SwiftPM is running on).

This file will be managed through SwiftPM commands and users are not expected to edit it by hand. The format of this file is an implementation detail but it will be human readable format, likely JSON in practice.

There could be a supplemental file providing key-value pairs whose keys can be referenced by the main configuration file. This can be used as an override mechanism that allows sharing the main configuration file between different users and machines by keeping user-specific configuration information out of the main configuration file. The use of this additional file will be optional and it will be managed by the user. The format will be based on git's configuration files, described [here](https://git-scm.com/docs/git-config#_syntax).


### Data format

Package collections must adhere to a specific JSON format for SwiftPM to be able to consume them. A draft of the JSON format has been [posted in the forums](https://forums.swift.org/t/package-collection-format/42071), but it is not part of this proposal because it is not considered stable API. Over time as the data format matures, we will consider making it stable API in a separate proposal.

Since the data format is unstable, users should avoid generating package collections on their own. This proposal includes providing the necessary tooling for generating and consuming package collections.


## Future direction

This proposal shows an initial set of metadata that package collections will offer, but the exact metadata provided can be evolved over time as needed. The global configuration files introduced here can be used for future features which require storing per-user configuration data.

This design is the first step in teaching SwiftPM about sets of curated packages, with the goal of allowing the community to build trusted working-sets of packages. Future work to support more dynamic server-based indexes can build on this initial design.


## Impact on existing packages

There is no impact on existing packages as this is a discovery feature that's being added to SwiftPM's command-line interface.


## Alternatives considered

The initial pitch considered adding the new CLI functionality under the existing `swift package` command, but that caused deeper nesting of commands and also did not fit with the existing functionality under this command.
