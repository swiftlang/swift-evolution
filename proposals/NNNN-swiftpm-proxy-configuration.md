# Package Manager HTTP Proxy Configuration

* Proposal: [SE-NNNN](NNNN-swiftpm-proxy-configuration.md)
* Authors: [raiyyan089](https://github.com/raiyyan089)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Bugs: [swiftlang/swift-package-manager#7470](https://github.com/swiftlang/swift-package-manager/issues/7470)
* Implementation: [swiftlang/swift-package-manager#10274](https://github.com/swiftlang/swift-package-manager/pull/10274)
* Review: ([pitch](https://forums.swift.org/t/pitch-package-manager-http-proxy-configuration/88121))

## Introduction

This proposal adds HTTP and HTTPS proxy support for all network operations performed by Swift Package Manager that use its built-in HTTP client. Today, SPM ignores standard proxy environment variables (`http_proxy`, `https_proxy`, `no_proxy`) for these operations, making it impossible to use SPM behind corporate firewalls or in environments that require proxy routing. This proposal introduces a configuration file–based approach that works cross-platform and across invocation contexts (CLI, Xcode, CI).

## Motivation

Many developers work in environments where all HTTP traffic must pass through a proxy server — corporate networks, government systems, university campuses, and CI infrastructure behind firewalls. The standard Unix convention is to set environment variables like `http_proxy` and `https_proxy`, and virtually all command-line tools respect these.

Swift Package Manager has a split personality regarding proxy support:

- **Git operations work.** When SPM shells out to `git` for cloning and fetching source packages, the git subprocess inherits the process environment and natively respects `http_proxy`/`https_proxy`. These operations work behind a proxy today.

- **All other HTTP operations are broken.** SPM uses Foundation's `URLSession` for downloading binary artifacts, fetching from package registries, downloading package collections, performing OCSP checks for signing validation, and installing Swift SDKs. The `URLSession` is created with `URLSessionConfiguration.default` and no proxy settings are applied. On macOS, system-level proxy settings (from System Preferences) may be picked up, but environment variables are not. On Linux, there is no system proxy at all, so these operations have zero proxy support.

This means a developer behind a proxy can `swift package resolve` a source dependency but cannot download a binary target artifact from the same server. This is the issue reported in [#7470](https://github.com/swiftlang/swift-package-manager/issues/7470).

Additionally, environment variables are problematic for GUI-based workflows on macOS. When Xcode invokes SPM, it does not inherit shell environment variables — it launches from `launchd` with a minimal environment. Users cannot easily configure `http_proxy` for Xcode-initiated SPM operations without resorting to non-ergonomic workarounds like `launchctl setenv`.

A file-based configuration approach solves both problems: it works regardless of how SPM is invoked (terminal, Xcode, CI) and is portable across platforms.

## Proposed solution

We introduce proxy configuration through two complementary mechanisms: a JSON configuration file (`proxy.json`) and standard proxy environment variables (`http_proxy`, `https_proxy`, `no_proxy`). The configuration file is stored in SPM's existing configuration directory hierarchy and provides reliable configuration across all invocation contexts. Environment variables provide a natural integration with CI systems and existing Unix workflows.

### Configuration file

A new file `proxy.json` is recognized in SPM's configuration directories:

- **User-level (shared):** `~/.swiftpm/configuration/proxy.json`
- **Project-level (local):** `<project>/.swiftpm/configuration/proxy.json`

Example:

```json
{
  "version": 1,
  "http": {
    "proxy": "http://proxy.corp.example.com:8080"
  },
  "https": {
    "proxy": "http://proxy.corp.example.com:8080"
  },
  "noProxy": ["localhost", "127.0.0.1", "::1", ".internal.corp"]
}
```

### CLI commands

New subcommands are added under `swift package config`:

```
swift package config set-proxy [--http <url>] [--https <url>] [--no-proxy <hosts>]
swift package config get-proxy
swift package config unset-proxy [--http] [--https] [--no-proxy]
```

`set-proxy` requires at least one flag. It is **additive** — it updates only the fields specified, leaving existing settings intact.

`unset-proxy` with flags removes specific settings. With no flags, it removes all proxy configuration.

Examples:

```bash
# Set HTTP proxy
swift package config set-proxy --http http://proxy:8080

# Set HTTPS proxy
swift package config set-proxy --https http://proxy:8080

# Set both at once
swift package config set-proxy --http http://proxy:8080 --https http://proxy:8080

# Add exclusions to existing config
swift package config set-proxy --no-proxy "localhost,.internal.corp"

# View current effective configuration
swift package config get-proxy

# Remove just the HTTPS proxy setting
swift package config unset-proxy --https

# Remove just the exclusions
swift package config unset-proxy --no-proxy

# Remove all proxy configuration
swift package config unset-proxy
```

### Precedence order

When determining proxy configuration, SPM uses the first source that provides a value:

1. **Local project config** (`<project>/.swiftpm/configuration/proxy.json`) — highest priority
2. **User-level config** (`~/.swiftpm/configuration/proxy.json`)
3. **Environment variables** (`http_proxy`/`HTTP_PROXY`, `https_proxy`/`HTTPS_PROXY`, `no_proxy`/`NO_PROXY`)
4. **macOS system proxy** (from System Settings → Network → Proxies; macOS only)
5. **No proxy** (direct connection) — default behavior

For environment variables, lowercase variants take precedence over uppercase (consistent with curl behavior).

On macOS, `URLSession` automatically inherits the system-level proxy configuration. This means SPM will route traffic through a system proxy even without a `proxy.json` or environment variables — no action is required from the user if their system proxy is already configured. The `proxy.json` file and environment variables act as explicit overrides when the system proxy is not appropriate for SPM operations.

On Linux, there is no system proxy layer. The `proxy.json` file and environment variables are the available configuration mechanisms.

Each field is resolved independently. For example, a user-level config could set `http` while the system proxy provides the HTTPS proxy — they do not need to come from the same source.

### Scope

Proxy configuration applies to all HTTP operations performed by SPM's built-in HTTP client:

- Binary artifact downloads
- Package registry API requests
- Package collection fetches
- OCSP certificate validation requests
- Swift SDK downloads
- Prebuilt binary downloads

It does **not** affect git operations, which continue to use git's own proxy configuration (`http.proxy` in gitconfig, or environment variables passed to the git subprocess).

## Detailed design

### Configuration file schema

```json
{
  "version": 1,
  "http": {
    "proxy": "<url>"
  },
  "https": {
    "proxy": "<url>"
  },
  "noProxy": ["<pattern>", ...]
}
```

**Fields:**

- `version` (required, integer): Schema version. Must be `1`.
- `http` (optional, object): Proxy settings for HTTP requests.
  - `proxy` (required, string): The proxy URL. Must include scheme and host. Port defaults to `80` for `http` schemes and `1080` for `socks5` schemes.
- `https` (optional, object): Proxy settings for HTTPS requests. Format is the same as `http`. The proxy URL scheme refers to the proxy connection itself (usually `http` even for HTTPS target requests, since the client uses `CONNECT` tunneling).
- `noProxy` (optional, array of strings): Hosts and patterns that should bypass the proxy.

The nested structure under `http` and `https` is intentional — it provides a natural location for future authenticated proxy support (e.g., `"authentication": "basic"`) without requiring a schema version bump.

If only `http` is specified, HTTPS requests will **not** use that proxy (they go direct). If only `https` is specified, HTTP requests go direct. This is intentional — it follows the behavior of `curl` and avoids accidentally routing HTTPS traffic through an HTTP-only proxy.

### `noProxy` matching rules

The `noProxy` field supports the following patterns:

| Pattern | Matches |
|---------|---------|
| `*` | All hosts (effectively disables the proxy) |
| `example.com` | Exactly `example.com` and all subdomains (e.g., `sub.example.com`) |
| `.example.com` | All subdomains of `example.com` but NOT `example.com` itself |
| `192.168.1.1` | Exact IP address |
| `localhost` | The literal hostname `localhost` |

Matching is case-insensitive.

### Proxy URL format

Proxy URLs follow the standard format:

```
scheme://host[:port]
```

Proxy URLs must **not** contain credentials (userinfo). If a URL containing `user:password@` is provided, SPM will emit an error directing the user to a future authenticated proxy mechanism. See [Future directions](#future-directions).

Supported schemes:
- `http` — HTTP proxy (most common, used for both HTTP and HTTPS targets via CONNECT)
- `https` — HTTPS connection to the proxy itself
- `socks5` — SOCKS5 proxy

### Integration point

Proxy configuration is applied at the `URLSessionHTTPClient` layer, which is the single concrete networking implementation used by all of SPM's HTTP client abstractions (`HTTPClient` and `LegacyHTTPClient`).

When a `URLSessionHTTPClient` is created, it:
1. Reads proxy configuration (local config → shared config)
2. If proxy settings are found, sets `connectionProxyDictionary` on the `URLSessionConfiguration` before creating the `URLSession` instances

This means all existing consumers of `HTTPClient` and `LegacyHTTPClient` automatically gain proxy support without any changes to their code.

### Cross-platform considerations

On macOS, `URLSessionConfiguration.connectionProxyDictionary` uses CoreFoundation constants:
- `kCFNetworkProxiesHTTPEnable`, `kCFNetworkProxiesHTTPProxy`, `kCFNetworkProxiesHTTPPort`
- `kCFStreamPropertyHTTPSProxyHost`, `kCFStreamPropertyHTTPSProxyPort`

On Linux (`FoundationNetworking`), the same property exists but may use string-based keys. The implementation uses conditional compilation to handle platform differences.

### CLI command behavior

`swift package config set-proxy`:
- Requires at least one of `--http`, `--https`, or `--no-proxy`
- Additive: only updates the fields specified, preserving existing settings
- Writes to the **user-level** `proxy.json` by default
- The `--package` flag writes to the project-level configuration instead
- Validates that proxy URLs are well-formed before writing

`swift package config get-proxy`:
- Displays the effective proxy configuration after resolving precedence
- Shows which source each value came from (project config, user config, system, or none)
- On macOS, queries the system proxy configuration and displays it when active
- On Linux, only file-based configuration is shown

Example output when both file and system proxy are in effect:

```
$ swift package config get-proxy
HTTP proxy:  http://proxy:8080 (user: ~/.swiftpm/configuration/proxy.json)
HTTPS proxy: http://corpproxy:3128 (system)
No proxy:    localhost, .internal.corp (user: ~/.swiftpm/configuration/proxy.json)
```

Example output when only system proxy is configured (no `proxy.json`):

```
$ swift package config get-proxy
HTTP proxy:  http://corpproxy:3128 (system)
HTTPS proxy: http://corpproxy:3128 (system)
No proxy:    *.local, 169.254/16 (system)
```

Example output when environment variables are set (no `proxy.json`, no system proxy):

```
$ swift package config get-proxy
HTTP proxy:  http://proxy:8080 (environment: http_proxy)
HTTPS proxy: http://proxy:8080 (environment: https_proxy)
No proxy:    localhost, .internal.corp (environment: no_proxy)
```

Example output with no proxy configured:

```
$ swift package config get-proxy
No proxy configuration.
```

`swift package config unset-proxy`:
- With `--http`, `--https`, or `--no-proxy` flags: removes only the specified settings
- With no flags: removes all proxy configuration (deletes the file if empty)
- Operates on the **user-level** config by default; `--package` targets project-level

### Authenticated proxies

Authenticated proxy support (proxies requiring username/password or token credentials) is **out of scope** for this proposal. See [Future directions](#future-directions) for the planned approach.

If a user provides a proxy URL containing credentials (e.g., `http://user:pass@proxy:8080`), SPM will reject it with an error message explaining that authenticated proxies are not yet supported.

## Security

### Traffic routing

When a proxy is configured, all matching HTTP traffic is routed through it. This means the proxy operator can observe request URLs, headers, and (for HTTP) request/response bodies. For HTTPS requests, the proxy sees only the target hostname (via `CONNECT`) but cannot observe the encrypted payload.

### No credentials stored

This proposal does not store any credentials. Proxy URLs are addresses only (scheme, host, port). Authenticated proxy support is deferred to a future proposal that will use SPM's existing secure credential storage (Keychain on macOS, `.netrc` on other platforms).

### No new attack surface

This proposal does not introduce new network endpoints or listening services. It routes existing traffic through a user-configured intermediary. The proxy itself is entirely under the user's control.

## Impact on existing packages

This proposal has **no impact on existing packages**. Proxy configuration is purely opt-in:

- Packages that do not configure a proxy continue to make direct connections exactly as they do today.
- No changes to `Package.swift` manifest format.
- No changes to dependency resolution behavior.
- No tools-version gating required.

The only observable difference is that SPM operations which previously failed with network errors in proxy-required environments will now succeed when properly configured.

## Future directions

### Authenticated proxy support

Some proxy servers require credentials (username/password or token). A future proposal could add authenticated proxy support following the same pattern established by `swift package-registry login`:

- A `swift package config proxy-login <proxy-url>` command that accepts `--username`/`--password` or `--token` flags
- Credentials stored in the operating system's secure credential store (Keychain on macOS) or `.netrc` on platforms without a secure store
- The `proxy.json` file updated to record only the authentication *type* (e.g., `"authentication": "basic"`), not the credentials themselves
- Interactive prompting for passwords to avoid credentials appearing in shell history

This approach keeps credentials out of plain-text configuration files, maintains consistency with the registry login workflow, and supports both interactive and non-interactive (CI) use cases.

### CIDR range matching in `noProxy`

The initial implementation treats IP addresses in `noProxy` as exact matches. A future enhancement could support CIDR notation (e.g., `192.168.0.0/16`) for matching IP ranges.

### Consolidation into a broader network configuration

If SPM gains additional network-level configuration needs in the future (custom CA certificates, connection timeouts, TLS settings), it may make sense to consolidate `proxy.json` into a broader `network.json`. The `version` field in the schema provides a migration path.

## Alternatives considered

### Environment variables only (no config file)

This was the simplest approach but fails the Xcode use case entirely. Environment variables are not available when Xcode invokes SPM, and requiring `launchctl setenv` is a poor user experience. A config file is necessary for GUI workflows. However, environment variables remain the most natural configuration mechanism for CI systems and command-line usage, which is why the proposal supports both — the config file for reliability across all contexts, and environment variables as a fallback for the common case.

### Environment variables as the highest-priority override

We considered making environment variables override the config file. This was rejected because it creates confusion: a developer might set `proxy.json` explicitly and then be surprised when an inherited environment variable overrides it in some contexts. The chosen precedence (file > env > system) ensures that explicit configuration always wins.

### Extend `registries.json` with proxy settings

Adding a `proxy` key to the existing `registries.json` was considered. However, proxy configuration is a transport-level concern that applies to all HTTP traffic (binary artifacts, collections, signing, SDKs), not just registry operations. Coupling it to the registry config would be a conceptual mismatch and could confuse users who use proxy but not registries.

### macOS System Proxy as the sole mechanism

On macOS, `URLSessionConfiguration.default` already reads system-level proxy settings from System Settings. We considered relying on this exclusively. However:
- This doesn't help Linux users at all
- It doesn't provide a way to configure proxy specifically for SPM without affecting all apps
- It doesn't allow project-level proxy overrides
- The behavior is implicit and hard to debug

Instead, we treat the macOS system proxy as the lowest-priority layer that `proxy.json` can override. This gives macOS users a zero-configuration experience when their system proxy is sufficient, while still providing explicit, portable configuration for cases where it isn't.

### Reading git's `http.proxy` config

Since git operations already work with proxy, we considered reading `git config --get http.proxy` as a fallback. This was rejected because:
- It couples non-git operations to git configuration
- It requires shelling out to `git` just to read proxy settings
- Git's per-URL proxy rules (`http.<url>.proxy`) would be complex to replicate
- Users may not want the same proxy for git and for binary artifact downloads

### A general `network.json` configuration file

A broader "network configuration" file could hold proxy settings alongside other network options (timeouts, custom CA certificates, TLS settings). This is a reasonable future direction, but over-scoping the initial proposal adds risk and delays the fix for a real problem. Starting with a focused `proxy.json` allows us to deliver value quickly. A future proposal could consolidate network settings if warranted.
