# Package Registry Authentication

* Proposal: [SE-NNNN](NNNN-package-registry-auth.md)
* Author: [Yim Lee](https://github.com/yim-lee)
* Review Manager: TBD
* Status: **Draft implementation**
* Implementation: [apple/swift-package-manager#5838](https://github.com/apple/swift-package-manager/pull/5838)

## Introduction

A package registry may require authentication for some or all of 
its API in order to identify user performing the action and authorize
the request accordingly.

## Motivation

Common authentication methods used by web services include basic
authentication, access token, and OAuth. SwiftPM supports only basic 
authentication today, which limits its abilities to interact with
package registry services.

## Proposed solution

We propose to modify the `swift package-registry` command and registry
configuration to add token authentication support. The changes should also 
ensure there is flexibility to add other authentication methods in the future.

The design draws inspiration from [`docker login`](https://docs.docker.com/engine/reference/commandline/login/) and [`npm login`](https://docs.npmjs.com/cli/v8/commands/npm-adduser), 
in that there will be a single command for user to verify and persist
registry credentials.

## Detailed design

### Changes to `swift package-registry` command

Instead of the `swift package-registry set` subcommand and the `--login` 
and `--password` options as proposed in [SE-0292](0292-package-registry-service.md) originally, 
we propose the new `login` and `logout` subcommands for adding/removing 
registry credentials. 

#### New `login` subcommand

Log in to a package registry. SwiftPM will verify the credentials using
the registry service's [`login` API](#login-api). If it returns a successful 
response, credentials will be persisted to the operating system's 
credential store if supported, or the user-level `.netrc` file otherwise. 
The global configuration file located at `~/.swiftpm/configuration/registries.json` 
will also be updated.

```manpage
SYNOPSIS
    swift package-registry login <url> [options]
OPTIONS:  
  --username     Username
  --password     Password
  
  --token        Access token

  --no-confirm    Allow writing to .netrc file without confirmation
  --netrc-file   Specify the .netrc file path
```

`url` should be the registry's base URL (e.g., `https://example-registry.com`). 
In case the location of the `login` API is something other than `/login` 
(e.g., `https://example-registry.com/api/v1/login`), provide the full URL.

The table below shows the supported authentication types and their 
required option(s):

| Authentication Method | Required Option(s)         |
| --------------------- | -------------------------- | 
| Basic                 | `--username`, `--password` |
| Token                 | `--token`                  |

The tool will analyze the provided options to determine the authentication 
type and prompt (i.e., interactive mode) for the password/token if it 
is missing. For example, if only `--username` is present, the tool 
assumes basic authentication and prompts for the password.

For non-interactive mode, simply provide the `--password` or `--token` 
option as required or make sure the secret is present in credential storage.

If the operating system's credential store is not supported, the 
tool will prompt user for confirmation before writing credentials 
to the less secured `.netrc` file. Use `--no-confirm` to disable 
this confirmation.

##### Example: basic authentication (macOS, interactive)

```console
> swift package-registry login https://example-registry.com \
    --username jappleseed
Enter password for 'jappleseed':

Login successful. Credentials have been saved to the operating system's secure credential store.
```

An entry for `example-registry.com` would be added to Keychain.

`registries.json` would be updated to indicate that `example-registry.com` 
requires basic authentication:

```json
{
  "authentication": {
    "example-registry.com": {
      "type": "basic"
    },
    ...
  },
  ...
}
```

##### Example: basic authentication (non-macOS, interactive)

```console
> swift package-registry login https://example-registry.com \
    --username jappleseed
Enter password for 'jappleseed':

Login successful.

WARNING: Secure credential storage is not supported on this platform. 
Your credentials will be written out to ~/.netrc. 
Continue? (Y/N): Y

Credentials have been saved to ~/.netrc.
```

An entry for `example-registry.com` would be added to the `.netrc` file:

```
machine example-registry.com
login jappleseed
password alpine
```

`registries.json` would be updated to indicate that `example-registry.com` 
requires basic authentication:

```json
{
  "authentication": {
    "example-registry.com": {
      "type": "basic"
    },
    ...
  },
  ...
}
```

##### Example: basic authentication (non-macOS, non-interactive)

```console
> swift package-registry login https://example-registry.com \
    --username jappleseed \
    --password alpine
    --no-confirm
    
Login successful. Credentials have been saved to ~/.netrc.
```

An entry for `example-registry.com` would be added to the `.netrc` file:

```
machine example-registry.com
login jappleseed
password alpine
```

`registries.json` would be updated to indicate that `example-registry.com` 
requires basic authentication:

```json
{
  "authentication": {
    "example-registry.com": {
      "type": "basic"
    },
    ...
  },
  ...
}
```

##### Example: basic authentication (non-macOS, non-interactive, non-default `login` URL)

```console
> swift package-registry login https://example-registry.com/api/v1/login \
    --username jappleseed \
    --password alpine
    --no-confirm
    
Login successful. Credentials have been saved to ~/.netrc.
```

An entry for `example-registry.com` would be added to the `.netrc` file:

```
machine example-registry.com
login jappleseed
password alpine
```

`registries.json` would be updated to indicate that `example-registry.com` 
requires basic authentication:

```json
{
  "authentication": {
    "example-registry.com": {
      "type": "basic",
      "loginAPIPath": "/api/v1/login"
    },
    ...
  },
  ...
}
```

##### Example: token authentication

```console
> swift package-registry login https://example-registry.com \
    --token jappleseedstoken
```

An entry for `example-registry.com` would be added to the operating 
system's credential store if supported, or the user-level `.netrc` 
file otherwise:

```
machine example-registry.com
login token
password jappleseedstoken
```

`registries.json` would be updated to indicate that `example-registry.com` 
requires token authentication:

```json
{
  "authentication": {
    "example-registry.com": {
      "type": "token"
    },
    ...
  },
  ...
}
```

#### New `logout` subcommand

Log out from a registry. Credentials are removed from the operating system's 
credential store if supported, and the global configuration file 
(`registries.json`).

To avoid accidental removal of sensitive data, `.netrc` file needs to be 
updated manually by the user. 

```manpage
SYNOPSIS
    swift package-registry logout <url>
```

### Changes to registry configuration

We will introduce a new `authentication` key to the global 
`registries.json` file, which by default is located at 
`~/.swiftpm/configuration/registries.json`. Any package
registry that requires authentication must have a corresponding
entry in this dictionary.

```json
{
  "registries": {
    "[default]": {
      "url": "https://example-registry.com"
    }
  },
  "authentication": {
    "example-registry.com": {
      "type": <AUTHENTICATION_TYPE>, // One of: "basic", "token"
      "loginAPIPath": <LOGIN_API_PATH> // Optional. Overrides the default API path (i.e., /login).
    }
  },
  "version": 1
}
```

`type` must be one of the following:
* `basic`: username and password
* `token`: access token

Credentials are to be specified in the native credential store 
of the operating system if supported, otherwise in the user-level 
`.netrc` file. (Only macOS Keychain will be supported in the 
initial feature release; more might be added in the future.)

See [credential storage](#credential-storage) for more details on configuring 
credentials for each authentication type.

### Credential storage

#### Basic Authentication

##### macOS Keychain

Registry credentials should be stored as "Internet password" 
items in the macOS Keychain. The "item name" should be the 
registry URL, including `https://` (e.g., `https://example-registry.com`).

##### `.netrc` file (non-macOS platforms only)

A `.netrc` entry for basic authentication looks as follows:

```
machine example-registry.com
login jappleseed
password alpine
```

By default, SwiftPM looks for `.netrc` file in the user's 
home directory. A custom `.netrc` file can be specified using 
the `--netrc-file` option.

#### Token Authentication

User can configure access token for a registry as similarly 
done for basic authentication, but with `token` as the login/username 
and the access token as the password. 

For example, a `.netrc` entry would look like:

```
machine example-registry.com
login token
password jappleseedstoken
```

### Additional changes in SwiftPM

1. Only the user-level `.netrc` file will be used. Project-level `.netrc` file will not be supported.
2. SwiftPM will perform lookups in one credential store only. For macOS, it will be Keychain. For all other platforms, it will be the user-level `.netrc` file.
3. The `--disable-keychain` and `--disable-netrc` options will be removed.

### New package registry service API

A package registry that requires authentication must implement
the new API endpoint(s) covered in this section.

#### `login` API

SwiftPM will send a HTTP `POST` request to `/login` to validate 
user credentials provided by the `login` subcommand. The request 
will include an `Authorization` HTTP header constructed as follows:

* Basic authentication: `Authorization: Basic <base64 encoded username:password>`
* Token authentication: `Authorization: Bearer <token>`

The registry service must return HTTP status `200` in the 
response if login is successful, and `401` otherwise.

In case the registry service does not support an authentication method,
it should return HTTP status `501`.

SwiftPM will persist user credentials to local credential store 
if login is successful.

## Security

This proposal moves SwiftPM to use operating system's native credential 
store (e.g., macOS Keychain) on supported platforms, which should yield
better security.

We are also eliminating the use of project-level `.netrc` file. This should
prevent accidental checkin of `.netrc` file and thus leakage of sensitive
information.

## Impact on existing packages

This proposal eliminates the project-level `.netrc` file. There should be 
no other impact on existing packages.

