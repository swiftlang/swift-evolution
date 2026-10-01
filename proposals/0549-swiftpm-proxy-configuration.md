# Package Manager HTTP Proxy Configuration

* Proposal: [SE-0549](0549-swiftpm-proxy-configuration.md)
* Authors: [raiyyan089](https://github.com/raiyyan089)
* Review Manager: [Franz Busch](https://github.com/FranzBusch)
* Status: **Active review (September 14...28, 2026)**
* Bugs: [swiftlang/swift-package-manager#7470](https://github.com/swiftlang/swift-package-manager/issues/7470)
* Implementation: [swiftlang/swift-package-manager#10274](https://github.com/swiftlang/swift-package-manager/pull/10274)
* Review: ([pitch](https://forums.swift.org/t/pitch-package-manager-http-proxy-configuration/88121)) ([review](https://forums.swift.org/t/review-se-0549-package-manager-http-proxy-configuration/89513))

## Introduction

This proposal adds HTTP and HTTPS proxy support for all network operations performed by Swift Package Manager that use its built-in HTTP client. Today, these operations do not consistently honor standard proxy environment variables (`http_proxy`, `https_proxy`, `no_proxy`), preventing them from working in environments that require proxy routing. This proposal supports those environment variables and introduces persistent SwiftPM configuration that does not depend on the invoking process providing them.

## Motivation

Many developers work in environments where all HTTP traffic must pass through a proxy server — corporate networks, government systems, university campuses, and CI infrastructure behind firewalls. The standard Unix convention is to set environment variables like `http_proxy` and `https_proxy`, and virtually all command-line tools respect these.

Swift Package Manager has inconsistent proxy support across its network operations:

- **Git operations work.** When SPM shells out to `git` for cloning and fetching source packages, the git subprocess inherits the process environment and natively respects `http_proxy`/`https_proxy`. These operations work behind a proxy today.

- **SwiftPM-managed HTTP operations can fail.** Binary artifact downloads, package registry requests, package collection fetches, OCSP checks for signing validation, and Swift SDK downloads use SwiftPM's built-in HTTP client rather than `git`. Their proxy behavior currently depends on the platform and networking backend, and standard proxy environment variables are not consistently honored. For example, on macOS the networking stack may use system proxy settings while ignoring proxy variables from the SwiftPM process environment.

This means a developer behind a proxy can `swift package resolve` a source dependency but cannot download a binary target artifact from the same server. This is the issue reported in [#7470](https://github.com/swiftlang/swift-package-manager/issues/7470).

Process environment is also not available in every SwiftPM invocation context. GUI and embedded clients may invoke SwiftPM without the user's shell environment. Xcode is one concrete example that motivates persistent configuration, but this proposal does not specify any Xcode integration or behavior. The proposed SwiftPM capability is the ability to obtain proxy settings independently of how the invoking process supplies environment variables.

It is worth noting that SPM's existing [dependency mirror configuration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0219-package-manager-dependency-mirroring.md) (SE-0219) can partially work around this problem — by mirroring external URLs to internal hosts that don't require a proxy, users can bypass the issue for specific dependencies. However, mirrors are not a general solution:

- Mirrors require a 1:1 mapping for each dependency URL. In a large project with dozens of dependencies across different hosts, maintaining mirrors for all of them is impractical.
- Mirrors are a URL-rewriting mechanism, not a network-routing mechanism. If the destination host requires a proxy (even after mirroring), mirrors cannot help.
- Organizations with a blanket "all external traffic goes through a proxy" policy need transport-level proxy support, not per-URL rewrites.
- Mirrors are designed for availability and caching use cases, not for network routing. Using them as a proxy workaround is a misuse of the abstraction.

A file-based configuration complements environment variables by providing persistent, platform-portable settings that do not depend on the invocation context.

## Proposed solution

We introduce proxy configuration through two complementary mechanisms: a JSON configuration file (`proxy.json`) and standard proxy environment variables (`http_proxy`, `https_proxy`, `no_proxy`). The configuration file is stored in SPM's existing configuration directory hierarchy and provides persistent configuration when environment variables are unavailable. Environment variables provide a natural integration with CI systems and existing command-line workflows.

### Configuration file

A new file `proxy.json` is recognized in SPM's configuration directories:

- **User-level (shared):** `<SwiftPM shared configuration directory>/proxy.json`
- **Project-level (local):** `<project>/.swiftpm/configuration/proxy.json`

The shared configuration directory is the same platform-specific directory SwiftPM already uses for files such as `mirrors.json` and `registries.json`. Its concrete path follows SwiftPM's existing platform conventions rather than being universally fixed at `~/.swiftpm/configuration`.

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
swift package config set-proxy [--global] [--http <url>] [--https <url>] [--no-proxy <hosts>]
swift package config get-proxy [--global]
swift package config unset-proxy [--global] [--http] [--https] [--no-proxy]
```

`set-proxy` requires at least one of `--http`, `--https`, or `--no-proxy`. It is **additive** — it updates only the fields specified, leaving existing settings intact.

`unset-proxy` with flags removes specific settings. With no flags, it removes all proxy configuration.

The `--global` flag targets the user-level file in SwiftPM's shared configuration directory and can be run from any directory — it does not require a `Package.swift` in the current directory. Without `--global`, commands operate on the project-level configuration. This is consistent with [SE-0535](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0535-global-mirrors-configuration-cli.md)'s `--global` flag for mirror commands.

Examples:

```bash
# Set HTTP proxy for current project
swift package config set-proxy --http http://proxy:8080

# Set HTTP proxy globally (user-level, all projects)
swift package config set-proxy --global --http http://proxy:8080

# Set both at once
swift package config set-proxy --http http://proxy:8080 --https http://proxy:8080

# Add exclusions to existing config
swift package config set-proxy --no-proxy "localhost,.internal.corp"

# View current effective configuration
swift package config get-proxy

# View only global configuration
swift package config get-proxy --global

# Remove just the HTTPS proxy setting
swift package config unset-proxy --https

# Remove all global proxy configuration
swift package config unset-proxy --global

# Remove all proxy configuration (project-level)
swift package config unset-proxy
```

### Precedence order

When determining proxy configuration, SPM uses the first source that provides a value:

1. **Environment variables** (`http_proxy`/`HTTP_PROXY`, `https_proxy`/`HTTPS_PROXY`, `no_proxy`/`NO_PROXY`) — highest priority
2. **Local project config** (`<project>/.swiftpm/configuration/proxy.json`)
3. **User-level (global) config** (`<SwiftPM shared configuration directory>/proxy.json`)
4. **Platform-native proxy configuration**, where supported by the active networking implementation
5. **No proxy** (direct connection) — default behavior

For environment variables, lowercase variants take precedence over uppercase (consistent with curl behavior). Environment variables are the highest priority source because this is the standard convention for CLI tools — it allows the caller to unambiguously force proxy settings regardless of other configuration.

When neither environment variables nor a `proxy.json` field supplies a setting, SwiftPM preserves the native proxy behavior of its active networking implementation. On macOS, for example, this allows system proxy settings to continue to apply. An implementation may delegate environment-variable or native proxy handling to its networking backend when that backend already provides the required behavior.

On platforms without native system proxy integration, environment variables and `proxy.json` provide the explicit configuration mechanisms.

Each field is resolved independently. For example, a user-level config could set `http` while the system proxy provides the HTTPS proxy — they do not need to come from the same source.

### Scope

Proxy configuration applies to all HTTP operations performed by SPM's built-in HTTP client:

- Binary artifact downloads
- Package registry API requests
- Package collection fetches
- OCSP certificate validation requests
- Swift SDK downloads
- Prebuilt binary downloads

It does **not** change how git operations resolve proxy settings. Git continues to use its own proxy configuration (`http.proxy` in gitconfig, or environment variables passed to the git subprocess).

Environment variables are therefore the common configuration mechanism for users who want one setting to apply to both Git and SwiftPM's built-in HTTP client. `proxy.json` serves a separate purpose: persistent SwiftPM configuration for built-in HTTP operations when process environment variables are unavailable. For example, a project may successfully resolve its Git dependencies while failing to download a binary target through SwiftPM's HTTP client; `proxy.json` addresses that missing SwiftPM configuration path without replacing Git's existing configuration.

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

### HTTP client integration

SwiftPM resolves the effective proxy configuration before performing operations through its built-in HTTP client. All built-in HTTP operations listed under [Scope](#scope) use that effective configuration.

This proposal does not require a particular networking library or configuration API. An implementation may use Foundation networking, NIO, or another backend, provided it preserves the configuration sources, precedence, matching rules, and native fallback behavior described by this proposal.

### Cross-platform considerations

The observable behavior defined by this proposal is consistent across platforms even when the underlying networking implementations differ. SwiftPM may rely on a backend's existing support for environment variables and native settings or translate the effective configuration into backend-specific options where necessary. In the absence of explicit environment or file configuration, SwiftPM leaves the backend's native proxy behavior intact.

### Interaction with git operations

SwiftPM shells out to `git` when resolving source-control dependencies, and this proposal does not replace Git's mature proxy configuration. Git continues to honor proxy environment variables and its own configuration, including URL-specific settings.

When proxy environment variables are present, both the Git subprocess and SwiftPM's built-in HTTP client use them, giving command-line and CI users a single configuration mechanism. When environment variables are unavailable, users may combine Git's persistent configuration with SwiftPM's `proxy.json`, with each tool retaining responsibility for its own network operations.

Keeping these configurations separate avoids silently overriding Git's own proxy rules while filling the configuration gap for HTTP operations performed directly by SwiftPM.

### Interaction with dependency mirrors

SPM's [dependency mirror configuration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0219-package-manager-dependency-mirroring.md) (SE-0219) rewrites package URLs before dependency resolution begins. The proxy configuration operates at a lower layer — the HTTP client — and sees only the *final* URL after mirror translation has already been applied.

The resolution order is:

1. SPM resolves the dependency graph and applies mirror rewrites (original URL → mirror URL)
2. When SPM makes an HTTP request (e.g., downloading a binary artifact), it uses the post-mirror URL
3. The HTTP client evaluates `noProxy` rules against the post-mirror URL
4. If no bypass matches, the request is routed through the configured proxy

This means `noProxy` patterns should reference the *mirror* URL (the actual destination), not the original URL declared in `Package.swift`. For example, if a dependency at `https://github.com/Org/Lib` is mirrored to `https://internal.corp/Org/Lib`, users should add `internal.corp` to their `noProxy` list if the internal host does not require a proxy.

This is the natural and expected behavior — the proxy layer should not need to be aware of the higher-level URL-rewriting semantics of mirrors.

### CLI command behavior

`swift package config set-proxy`:
- Requires at least one of `--http`, `--https`, or `--no-proxy`
- Additive: only updates the fields specified, preserving existing settings
- Writes to the **project-level** `proxy.json` by default
- The `--global` flag writes to the user-level file in SwiftPM's shared configuration directory and does not require a `Package.swift` in the current directory
- Validates that proxy URLs are well-formed before writing

`swift package config get-proxy`:
- Displays the effective proxy configuration after resolving precedence
- Shows which source each value came from (environment, project config, user config, system, or none)
- Displays platform-native proxy configuration when SwiftPM can query it
- On platforms where native settings cannot be queried, displays environment and file-based configuration

Example output when both file and system proxy are in effect:

```
$ swift package config get-proxy
HTTP proxy:  http://proxy:8080 (user: <SwiftPM shared configuration directory>/proxy.json)
HTTPS proxy: http://corpproxy:3128 (system)
No proxy:    localhost, .internal.corp (user: <SwiftPM shared configuration directory>/proxy.json)
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
- Operates on the **project-level** config by default; `--global` targets user-level

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

This is the simplest approach and remains the most natural mechanism for CI systems and command-line usage. However, environment variables are scoped to the invoking process and are not reliably available when SwiftPM is launched by GUI or embedded clients. Xcode is one motivating example of such an invocation context, though this proposal does not specify Xcode behavior. The configuration file provides a persistent SwiftPM-owned source that is independent of the process environment, while environment variables retain the highest precedence when present.

### Config file as the highest-priority override

We considered making the config file override environment variables. This was rejected because it deviates from the standard convention for CLI tools — environment variables are the established mechanism for callers to unambiguously force settings regardless of other configuration sources. A CI job that sets `http_proxy` expects it to take effect unconditionally.

### Extend `registries.json` with proxy settings

Adding a `proxy` key to the existing `registries.json` was considered. However, proxy configuration is a transport-level concern that applies to all HTTP traffic (binary artifacts, collections, signing, SDKs), not just registry operations. Coupling it to the registry config would be a conceptual mismatch and could confuse users who use proxy but not registries.

### Extend `mirrors.json` with proxy settings

The mirror configuration (SE-0219) is another existing configuration file that deals with network access patterns. We considered placing proxy settings there. However, mirrors and proxies solve fundamentally different problems: mirrors rewrite *where* a request goes (URL translation), while proxies control *how* the request is routed at the transport layer. A mirror changes the destination; a proxy changes the path to get there. Conflating the two concepts in one file would be confusing and architecturally unsound. Furthermore, proxy configuration applies uniformly to all HTTP traffic regardless of whether a dependency is mirrored.

### Platform-native proxy configuration as the sole mechanism

Some platform networking stacks can obtain proxy settings from the operating system. We considered relying on this exclusively. However:
- Native proxy integration is not consistent across all SwiftPM-supported platforms and networking backends
- It doesn't provide a way to configure proxy specifically for SPM without affecting all apps
- It doesn't allow project-level proxy overrides
- The behavior is implicit and hard to debug

Instead, platform-native proxy behavior remains the lowest-priority layer that explicit environment or file configuration can override. This preserves a zero-configuration experience where native settings are sufficient while providing portable SwiftPM configuration where they are not.

### Reading git's `http.proxy` config

Since git operations already work with proxy, we considered reading `git config --get http.proxy` as a fallback. This was rejected because:
- It couples non-git operations to git configuration
- It requires shelling out to `git` just to read proxy settings
- Git's per-URL proxy rules (`http.<url>.proxy`) would be complex to replicate
- Users may not want the same proxy for git and for binary artifact downloads

### Apply `proxy.json` to git subprocesses

We also considered translating `proxy.json` into settings for Git subprocesses. This was rejected because Git already has a mature proxy configuration model, including URL-specific rules and authentication behavior that are outside the scope of this proposal. Injecting SwiftPM configuration could unexpectedly override or conflict with those rules. Standard proxy environment variables remain the intentional common mechanism when users want the same proxy to apply to both Git and SwiftPM's built-in HTTP client.

### A general `network.json` configuration file

A broader "network configuration" file could hold proxy settings alongside other network options (timeouts, custom CA certificates, TLS settings). This is a reasonable future direction, but over-scoping the initial proposal adds risk and delays the fix for a real problem. Starting with a focused `proxy.json` allows us to deliver value quickly. A future proposal could consolidate network settings if warranted.
