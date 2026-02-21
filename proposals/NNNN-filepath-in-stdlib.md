# Add `FilePath` to the Standard Library

* Proposal: TBD
* Authors: [Michael Ilseman](https://github.com/milseman)
* Review Manager: TBD
* Status: **Pitch**
* Implementation: TBD
* Review: TBD

## Introduction

We propose adding `FilePath` and its syntactic operations to the Swift standard library. These operations inspect, decompose, and modify paths without making system calls. The API has been shipping in the [swift-system](https://github.com/apple/swift-system) package since version 0.0.2, iterated through [two review cycles](https://forums.swift.org/t/api-review-filepath-syntactic-apis-version-2/44197).

## Motivation

Swift has no standard representation for file system paths. The swift-system package introduced `FilePath` in [System 0.0.1](https://github.com/apple/swift-system/releases/tag/0.0.1), and it has since gained a comprehensive set of [syntactic operations](https://forums.swift.org/t/api-review-filepath-syntactic-apis-version-2/44197) for platform-correct path manipulation. But because `FilePath` lives in an external package, it cannot be depended on by the standard library or the Swift runtime, nor can it appear in API in toolchain libraries such as Foundation.

Every new API that needs to name a file path faces the same dilemma around using `String` that [SE-0513](https://forums.swift.org/t/se-0513-api-to-get-the-path-to-the-current-executable/84800) faces.

`String` is a poor fit for paths. It does not capture the structure of a file path, as paths have an optional root, a sequence of components, and things like per-component stem/extension decomposition. Path string representations are platform-specific: the separator is `/` on Unix and `\` on Windows, and Windows paths have complex root forms (drive letters, UNC paths, device paths). Path encodings are also platform-specific and not Unicode. On Unix, paths are null-terminated byte sequences that are not necessarily valid UTF-8; on Windows, null-terminated `UInt16` sequences that are not necessarily valid UTF-16. 

`FilePath` addresses all of these concerns. It stores the path in its native platform encoding, provides a rich set of syntactic operations that are consistent across platforms, and enables strongly-typed programming with paths.

## Proposed solution

We propose adding `FilePath`, `FilePath.Root`, `FilePath.Component`, and `FilePath.ComponentView` to the `Swift` module, along with their syntactic operations for decomposition, mutation, lexical normalization, and string conversion.

```swift
var path: FilePath = "/tmp/archive.tar.gz"

path.extension               // "gz"
path.stem                    // "archive.tar"
path.lastComponent           // "archive.tar.gz" as a FilePath.Component
path.removingLastComponent() // "/tmp"
path.isAbsolute              // true
path.root                    // "/"

path.starts(with: "/tmp")   // true
path.starts(with: "/tm")    // false (component-aware)

// Protecting against path traversal
let base: FilePath = "/var/www/static"
base.lexicallyResolving("../../etc/passwd")  // nil

// In-place mutation
var config: FilePath = "/etc/nginx/nginx.conf"
config.extension = "bak"     // "/etc/nginx/nginx.bak"

// Iterating components
for component in path.components {
    print(component, component.kind)
}
```

## Detailed design

### `FilePath`

`FilePath` stores a null-terminated sequence of platform characters (`CChar` on Unix, `UInt16` on Windows). It normalizes directory separators on construction: trailing separators in the relative portion are stripped, repeated separators are coalesced, and on Windows forward slashes are normalized to backslashes.

```swift
/// A file path is a null-terminated sequence of bytes that represents
/// a location in the file system.
///
/// The file path is stored in the file system's native encoding:
/// UTF-8 on Unix and UTF-16 on Windows.
///
/// File paths are a currency type across many APIs.
///
/// Example:
///
///     let path: FilePath = "/tmp/foo.txt"
///     if path.isAbsolute && path.extension == "txt" {
///         // ...
///     }
///
public struct FilePath: Sendable {
  /// Creates an empty file path.
  public init()

  /// Creates a file path from a string.
  public init(_ string: String)
}

extension FilePath:
  Hashable, Codable,
  CustomStringConvertible, CustomDebugStringConvertible,
  ExpressibleByStringLiteral
{
  /// A textual representation of the file path.
  ///
  /// If the content of the path isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public var description: String { get }

  /// A textual representation of the file path, suitable for debugging.
  public var debugDescription: String { get }

  /// Create a file path from a string literal.
  public init(stringLiteral: String)
}
```

### `FilePath.Root`

`FilePath.Root` represents the root of a path. On Unix, this is simply `/`. On Windows, it can include volume and server/share information in several syntactic forms.

```swift
extension FilePath {
  /// Represents a root of a file path.
  ///
  /// On Unix, a root is simply the directory separator `/`.
  ///
  /// On Windows, a root contains the entire path prefix up to and including
  /// the final separator.
  ///
  /// Examples:
  /// * Unix:
  ///   * `/`
  /// * Windows:
  ///   * `C:\`
  ///   * `C:`
  ///   * `\`
  ///   * `\\server\share\`
  ///   * `\\?\UNC\server\share\`
  ///   * `\\?\Volume{12345678-abcd-1111-2222-123445789abc}\`
  public struct Root: Sendable { }
}

extension FilePath.Root:
  Hashable,
  CustomStringConvertible, CustomDebugStringConvertible,
  ExpressibleByStringLiteral
{
  /// A textual representation of the path root.
  ///
  /// If the content of the path root isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public var description: String { get }

  /// A textual representation of the path root, suitable for debugging.
  public var debugDescription: String { get }

  /// Create a file path root from a string literal.
  ///
  /// Precondition: `stringLiteral` is non-empty and is a root.
  public init(stringLiteral: String)

  /// Create a file path root from a string.
  ///
  /// Returns `nil` if `string` is empty or is not a root.
  public init?(_ string: String)
}
```

### `FilePath.Component`

`FilePath.Component` represents a single non-root component of a path. Components are always non-empty and do not contain a directory separator.

```swift
extension FilePath {
  /// Represents an individual, non-root component of a file path.
  ///
  /// Components can be one of the special directory components (`.` or `..`)
  /// or a file or directory name. Components are never empty and never
  /// contain the directory separator.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/tmp"
  ///     let file: FilePath.Component = "foo.txt"
  ///     file.kind == .regular           // true
  ///     file.extension                  // "txt"
  ///     path.append(file)               // path is "/tmp/foo.txt"
  ///
  public struct Component: Sendable {
    /// Whether a component is a regular file or directory name, or a special
    /// directory `.` or `..`
    public enum Kind: Sendable {
      /// The special directory `.`, representing the current directory.
      case currentDirectory

      /// The special directory `..`, representing the parent directory.
      case parentDirectory

      /// A file or directory name
      case regular
    }

    /// The kind of this component
    public var kind: Kind { get }
  }
}

extension FilePath.Component:
  Hashable,
  CustomStringConvertible, CustomDebugStringConvertible,
  ExpressibleByStringLiteral
{
  /// A textual representation of the path component.
  ///
  /// If the content of the path component isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public var description: String { get }

  /// A textual representation of the path component, suitable for debugging.
  public var debugDescription: String { get }

  /// Create a file path component from a string literal.
  ///
  /// Precondition: `stringLiteral` is non-empty and has only one component in it.
  public init(stringLiteral: String)

  /// Create a file path component from a string.
  ///
  /// Returns `nil` if `string` is empty, a root, or has more than one component
  /// in it.
  public init?(_ string: String)
}
```

### Stem and extension

Components may be decomposed into their stem and optional extension (`.txt`, `.o`, `.app`, etc.). `FilePath` provides convenience APIs for dealing with the stem and extension of the last component.

```swift
extension FilePath.Component {
  /// The extension of this file or directory component.
  ///
  /// If `self` does not contain a `.` anywhere, or only
  /// at the start, returns `nil`. Otherwise, returns everything after the dot.
  ///
  /// Examples:
  ///   * `foo.txt    => txt`
  ///   * `foo.tar.gz => gz`
  ///   * `Foo.app    => app`
  ///   * `.hidden    => nil`
  ///   * `..         => nil`
  ///
  public var `extension`: String? { get }

  /// The non-extension portion of this file or directory component.
  ///
  /// Examples:
  ///   * `foo.txt => foo`
  ///   * `foo.tar.gz => foo.tar`
  ///   * `Foo.app => Foo`
  ///   * `.hidden => .hidden`
  ///   * `..      => ..`
  ///
  public var stem: String { get }
}

extension FilePath {
  /// The extension of the file or directory last component.
  ///
  /// If `lastComponent` is `nil` or one of the special path components
  /// `.` or `..`, `get` returns `nil` and `set` does nothing.
  ///
  /// If `lastComponent` does not contain a `.` anywhere, or only
  /// at the start, `get` returns `nil` and `set` will append a
  /// `.` and `newValue` to `lastComponent`.
  ///
  /// Otherwise `get` returns everything after the last `.` and `set` will
  /// replace the extension.
  ///
  /// Examples:
  ///   * `/tmp/foo.txt                 => txt`
  ///   * `/Applications/Foo.app/       => app`
  ///   * `/Applications/Foo.app/bar.txt => txt`
  ///   * `/tmp/foo.tar.gz              => gz`
  ///   * `/tmp/.hidden                 => nil`
  ///   * `/tmp/.hidden.                => ""`
  ///   * `/tmp/..                      => nil`
  ///
  /// Example:
  ///
  ///     var path = "/tmp/file"
  ///     path.extension = ".txt" // path is "/tmp/file.txt"
  ///     path.extension = ".o"   // path is "/tmp/file.o"
  ///     path.extension = nil    // path is "/tmp/file"
  ///     path.extension = ""     // path is "/tmp/file."
  ///
  public var `extension`: String? { get set }

  /// The non-extension portion of the file or directory last component.
  ///
  /// Returns `nil` if `lastComponent` is `nil`
  ///
  ///   * `/tmp/foo.txt                 => foo`
  ///   * `/Applications/Foo.app/       => Foo`
  ///   * `/Applications/Foo.app/bar.txt => bar`
  ///   * `/tmp/.hidden                 => .hidden`
  ///   * `/tmp/..                      => ..`
  ///   * `/                            => nil`
  public var stem: String? { get }
}
```

> **Rationale**: `stem` and `extension` are expressed as `String`s, which are more ergonomic than a slice of raw platform characters. These operations perform Unicode error correction, which is desirable when reading content. Setting extensions containing invalid Unicode is especially indicative of a programming error.

> **Rationale**: `FilePath.stem` does not have a setter. Components are never empty and always have stems. Setting a stem to `""` or `nil` would result in either an invalid component or a hidden file whose new name was an extension. This is indicative of a programming error.

> **Rationale**: Components do not have mutating operations such as setters. Components are slice types and participate in copy-on-write; they would not mutate the containing path unless part of an accessor chain. Allowing mutations would give the false impression that modifications are published back to the containing path (e.g. while iterating the components).

### `FilePath.ComponentView`

`FilePath.ComponentView` is a `BidirectionalCollection` and `RangeReplaceableCollection` of the non-root components that comprise a path.

```swift
extension FilePath {
  /// A bidirectional, range replaceable collection of the non-root components
  /// that make up a file path.
  ///
  /// ComponentView provides access to standard `BidirectionalCollection`
  /// algorithms for accessing components from the front or back, as well as
  /// standard `RangeReplaceableCollection` algorithms for modifying the
  /// file path using component or range of components granularity.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/./home/./username/scripts/./tree"
  ///     let scriptIdx = path.components.lastIndex(of: "scripts")!
  ///     path.components.insert("bin", at: scriptIdx)
  ///     // path is "/./home/./username/bin/scripts/./tree"
  ///
  ///     path.components.removeAll { $0.kind == .currentDirectory }
  ///     // path is "/home/username/bin/scripts/tree"
  ///
  public struct ComponentView:
    BidirectionalCollection, RangeReplaceableCollection, Sendable { }

  /// View the non-root components that make up this path.
  public var components: ComponentView { get set }
}
```

`FilePath` can be created from a root and components. The `ComponentView.SubSequence` overload is more efficient as it can directly access the underlying storage, which already has normalized separators.

```swift
extension FilePath {
  /// Create a file path from a root and a collection of components.
  public init<C: Collection>(root: Root?, _ components: C)
    where C.Element == Component

  /// Create a file path from a root and any number of components.
  public init(root: Root?, components: Component...)

  /// Create a file path from an optional root and a slice of another path's
  /// components.
  public init(root: Root?, _ components: ComponentView.SubSequence)
}
```

### Basic queries

```swift
extension FilePath {
  /// Returns whether `other` is a prefix of `self`, only considering
  /// whole path components.
  ///
  /// Example:
  ///
  ///     let path: FilePath = "/usr/bin/ls"
  ///     path.starts(with: "/")              // true
  ///     path.starts(with: "/usr/bin")       // true
  ///     path.starts(with: "/usr/bin/ls")    // true
  ///     path.starts(with: "/usr/bin/ls///") // true
  ///     path.starts(with: "/us")            // false
  ///
  public func starts(with other: FilePath) -> Bool

  /// Returns whether `other` is a suffix of `self`, only considering
  /// whole path components.
  ///
  /// Example:
  ///
  ///     let path: FilePath = "/usr/bin/ls"
  ///     path.ends(with: "ls")             // true
  ///     path.ends(with: "bin/ls")         // true
  ///     path.ends(with: "usr/bin/ls")     // true
  ///     path.ends(with: "/usr/bin/ls///") // true
  ///     path.ends(with: "/ls")            // false
  ///
  public func ends(with other: FilePath) -> Bool

  /// Whether this path is empty
  public var isEmpty: Bool { get }
}
```

### Absolute and relative paths

Windows roots are more complex than Unix roots and can take several syntactic forms. The presence of a root does not imply the path is absolute on Windows. For example, `C:foo` refers to `foo` relative to the current directory on the `C` drive, and `\foo` refers to `foo` at the root of the current drive. Neither is absolute (i.e. "fully-qualified" in Windows terminology).

```swift
extension FilePath {
  /// Returns true if this path uniquely identifies the location of
  /// a file without reference to an additional starting location.
  ///
  /// On Unix platforms, absolute paths begin with a `/`. `isAbsolute` is
  /// equivalent to `root != nil`.
  ///
  /// On Windows, absolute paths are fully qualified paths. `isAbsolute` is
  /// _not_ equivalent to `root != nil` for traditional DOS paths
  /// (e.g. `C:foo` and `\bar` have roots but are not absolute). UNC paths
  /// and device paths are always absolute. Traditional DOS paths are
  /// absolute only if they begin with a volume or drive followed by
  /// a `:` and a separator.
  ///
  /// NOTE: This does not perform shell expansion or substitute
  /// environment variables; paths beginning with `~` are considered relative.
  ///
  /// Examples:
  /// * Unix:
  ///   * `/usr/local/bin`
  ///   * `/tmp/foo.txt`
  ///   * `/`
  /// * Windows:
  ///   * `C:\Users\`
  ///   * `\\?\UNC\server\share\bar.exe`
  ///   * `\\server\share\bar.exe`
  public var isAbsolute: Bool { get }

  /// Returns true if this path is not absolute (see `isAbsolute`).
  ///
  /// Examples:
  /// * Unix:
  ///   * `~/bar`
  ///   * `tmp/foo.txt`
  /// * Windows:
  ///   * `bar\baz`
  ///   * `C:Users\`
  ///   * `\Users`
  public var isRelative: Bool { get }
}
```

### Path decomposition

Paths can be decomposed into their optional root and their (potentially empty) relative components.

```swift
extension FilePath {
  /// Returns the root of a path if there is one, otherwise `nil`.
  ///
  /// On Unix, this will return the leading `/` if the path is absolute
  /// and `nil` if the path is relative.
  ///
  /// On Windows, for traditional DOS paths, this will return
  /// the path prefix up to and including a root directory or
  /// a supplied drive or volume. Otherwise, if the path is relative to
  /// both the current directory and current drive, returns `nil`.
  ///
  /// On Windows, for UNC or device paths, this will return the path prefix
  /// up to and including the host and share for UNC paths or the volume for
  /// device paths followed by any subsequent separator.
  ///
  /// Examples:
  /// * Unix:
  ///   * `/foo/bar => /`
  ///   * `foo/bar  => nil`
  /// * Windows:
  ///   * `C:\foo\bar                => C:\`
  ///   * `C:foo\bar                 => C:`
  ///   * `\foo\bar                  => \`
  ///   * `foo\bar                   => nil`
  ///   * `\\server\share\file       => \\server\share\`
  ///   * `\\?\UNC\server\share\file => \\?\UNC\server\share\`
  ///   * `\\.\device\folder         => \\.\device\`
  ///
  /// Setting the root to `nil` will remove the root and setting a new
  /// root will replace the root.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/foo/bar"
  ///     path.root = nil // path is "foo/bar"
  ///     path.root = "/" // path is "/foo/bar"
  ///
  /// Example (Windows):
  ///
  ///     var path: FilePath = #"\foo\bar"#
  ///     path.root = nil         // path is #"foo\bar"#
  ///     path.root = "C:"        // path is #"C:foo\bar"#
  ///     path.root = #"C:\"#     // path is #"C:\foo\bar"#
  ///
  public var root: FilePath.Root? { get set }

  /// Creates a new path containing just the components, i.e. everything
  /// after `root`.
  ///
  /// Returns self if `root == nil`.
  ///
  /// Examples:
  /// * Unix:
  ///   * `/foo/bar => foo/bar`
  ///   * `foo/bar  => foo/bar`
  ///   * `/        => ""`
  /// * Windows:
  ///   * `C:\foo\bar                  => foo\bar`
  ///   * `foo\bar                     => foo\bar`
  ///   * `\\?\UNC\server\share\file   => file`
  ///   * `\\?\device\folder\file.exe  => folder\file.exe`
  ///   * `\\server\share\file         => file`
  ///   * `\                           => ""`
  ///
  public func removingRoot() -> FilePath
}
```

A common decomposition of a path is between its last non-root component and everything prior (analogous to `basename` and `dirname` in C).

```swift
extension FilePath {
  /// Returns the final component of the path.
  /// Returns `nil` if the path is empty or only contains a root.
  ///
  /// Note: Even if the final component is a special directory
  /// (`.` or `..`), it will still be returned. See `lexicallyNormalize()`.
  ///
  /// Examples:
  /// * Unix:
  ///   * `/usr/local/bin/ => bin`
  ///   * `/tmp/foo.txt    => foo.txt`
  ///   * `/tmp/foo.txt/.. => ..`
  ///   * `/tmp/foo.txt/.  => .`
  ///   * `/               => nil`
  /// * Windows:
  ///   * `C:\Users\                    => Users`
  ///   * `C:Users\                     => Users`
  ///   * `C:\                          => nil`
  ///   * `\Users\                      => Users`
  ///   * `\\?\UNC\server\share\bar.exe => bar.exe`
  ///   * `\\server\share               => nil`
  ///   * `\\?\UNC\server\share\        => nil`
  ///
  public var lastComponent: Component? { get }

  /// Creates a new path with everything up to but not including
  /// `lastComponent`.
  ///
  /// If the path only contains a root, returns `self`.
  /// If the path has no root and only includes a single component,
  /// returns an empty FilePath.
  ///
  /// Examples:
  /// * Unix:
  ///   * `/usr/bin/ls => /usr/bin`
  ///   * `/foo        => /`
  ///   * `/           => /`
  ///   * `foo         => ""`
  /// * Windows:
  ///   * `C:\foo\bar.exe                 => C:\foo`
  ///   * `C:\                            => C:\`
  ///   * `\\server\share\folder\file.txt => \\server\share\folder`
  ///   * `\\server\share\                => \\server\share\`
  public func removingLastComponent() -> FilePath
}
```

For discoverability by users coming from C, unavailable-renamed declarations redirect `basename` and `dirname`:

```swift
extension FilePath {
  @available(*, unavailable, renamed: "removingLastComponent()")
  public var dirname: FilePath { removingLastComponent() }

  @available(*, unavailable, renamed: "lastComponent")
  public var basename: Component? { lastComponent }
}
```

### Lexical operations

`FilePath` supports lexical operations (i.e. operations that do not consult the file system to follow symlinks) such as normalization of `.` and `..` components.

```swift
extension FilePath {
  /// Whether the path is in lexical-normal form, that is `.` and `..`
  /// components have been collapsed lexically (i.e. without following
  /// symlinks).
  ///
  /// Examples:
  /// * `"/usr/local/bin".isLexicallyNormal == true`
  /// * `"../local/bin".isLexicallyNormal   == true`
  /// * `"local/bin/..".isLexicallyNormal   == false`
  public var isLexicallyNormal: Bool { get }

  /// Collapse `.` and `..` components lexically (i.e. without following
  /// symlinks).
  ///
  /// Examples:
  /// * `/usr/./local/bin/.. => /usr/local`
  /// * `/../usr/local/bin   => /usr/local/bin`
  /// * `../usr/local/../bin => ../usr/bin`
  public mutating func lexicallyNormalize()

  /// Returns a copy of `self` in lexical-normal form, that is `.` and `..`
  /// components have been collapsed lexically (i.e. without following
  /// symlinks). See `lexicallyNormalize`
  public func lexicallyNormalized() -> FilePath
}
```

`FilePath` also provides API to protect against arbitrary path traversal from untrusted subpaths:

```swift
extension FilePath {
  /// Create a new `FilePath` by resolving `subpath` relative to `self`,
  /// ensuring that the result is lexically contained within `self`.
  ///
  /// `subpath` will be lexically normalized (see `lexicallyNormalize`) as
  /// part of resolution, meaning any contained `.` and `..` components will
  /// be collapsed without resolving symlinks. Any root in `subpath` will be
  /// ignored.
  ///
  /// Returns `nil` if the result would "escape" from `self` through use of
  /// the special directory component `..`.
  ///
  /// This is useful for protecting against arbitrary path traversal from an
  /// untrusted subpath: the result is guaranteed to be lexically contained
  /// within `self`. Since this operation does not consult the file system to
  /// resolve symlinks, any escaping symlinks nested inside of `self` can still
  /// be targeted by the result.
  ///
  /// Example:
  ///
  ///     let staticContent: FilePath = "/var/www/my-website/static"
  ///     let links: [FilePath] =
  ///       ["index.html", "/assets/main.css", "../../../../etc/passwd"]
  ///     links.map { staticContent.lexicallyResolving($0) }
  ///       // ["/var/www/my-website/static/index.html",
  ///       //  "/var/www/my-website/static/assets/main.css",
  ///       //  nil]
  public func lexicallyResolving(_ subpath: FilePath) -> FilePath?
}
```

### Modifying paths

```swift
extension FilePath {
  /// If `prefix` is a prefix of `self`, removes it and returns `true`.
  /// Otherwise returns `false`.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/usr/local/bin"
  ///     path.removePrefix("/usr/bin")   // false
  ///     path.removePrefix("/us")        // false
  ///     path.removePrefix("/usr/local") // true, path is "bin"
  ///
  public mutating func removePrefix(_ prefix: FilePath) -> Bool

  /// Append a `component` on to the end of this path.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/tmp"
  ///     let sub: FilePath = "foo/./bar/../baz/."
  ///     for comp in sub.components.filter({ $0.kind != .currentDirectory }) {
  ///       path.append(comp)
  ///     }
  ///     // path is "/tmp/foo/bar/../baz"
  ///
  public mutating func append(_ component: FilePath.Component)

  /// Append `components` on to the end of this path.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/"
  ///     path.append(["usr", "local"])     // path is "/usr/local"
  ///     let otherPath: FilePath = "/bin/ls"
  ///     path.append(otherPath.components) // path is "/usr/local/bin/ls"
  ///
  public mutating func append<C: Collection>(_ components: C)
    where C.Element == FilePath.Component

  /// Append the contents of `other`, ignoring any spurious leading separators.
  ///
  /// A leading separator is spurious if `self` is non-empty.
  ///
  /// Example:
  ///   var path: FilePath = ""
  ///   path.append("/var/www/website") // "/var/www/website"
  ///   path.append("static/assets") // "/var/www/website/static/assets"
  ///   path.append("/main.css") // "/var/www/website/static/assets/main.css"
  ///
  public mutating func append(_ other: String)

  /// Non-mutating version of `append(_:Component)`.
  public func appending(_ other: Component) -> FilePath

  /// Non-mutating version of `append(_:C)`.
  public func appending<C: Collection>(
    _ components: C
  ) -> FilePath where C.Element == FilePath.Component

  /// Non-mutating version of `append(_:String)`.
  public func appending(_ other: String) -> FilePath

  /// If `other` does not have a root, append each component of `other`. If
  /// `other` has a root, replaces `self` with other.
  ///
  /// This operation mimics traversing a directory structure (similar to the
  /// `cd` command), where pushing a relative path will append its components
  /// and pushing an absolute path will first clear `self`'s existing
  /// components.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/tmp"
  ///     path.push("dir/file.txt") // path is "/tmp/dir/file.txt"
  ///     path.push("/bin")         // path is "/bin"
  ///
  public mutating func push(_ other: FilePath)

  /// Non-mutating version of `push()`
  public func pushing(_ other: FilePath) -> FilePath

  /// In-place mutating variant of `removingLastComponent`.
  ///
  /// If `self` only contains a root, does nothing and returns `false`.
  /// Otherwise removes `lastComponent` and returns `true`.
  ///
  /// Example:
  ///
  ///     var path = "/usr/bin"
  ///     path.removeLastComponent() == true  // path is "/usr"
  ///     path.removeLastComponent() == true  // path is "/"
  ///     path.removeLastComponent() == false // path is "/"
  ///
  @discardableResult
  public mutating func removeLastComponent() -> Bool

  /// Remove the contents of the path, keeping the null terminator.
  public mutating func removeAll(keepingCapacity: Bool = false)

  /// Reserve enough storage space to store `minimumCapacity` platform
  /// characters.
  public mutating func reserveCapacity(_ minimumCapacity: Int)
}
```

> **Rationale**: `removeLastComponent` does not return the component, as components are slices of `FilePath`'s underlying storage. Returning a removed component would trigger a copy-on-write copy.

> **Rationale**: We do not propose `append` taking a `FilePath` since appending absolute paths is problematic. Silently ignoring a root (loose stringy semantics) is commonly expected when given a string literal, so we provide an overload of `append` taking a `String`, which is far more convenient than splitting components out by hand. Silently ignoring a root is surprising and undesirable in programmatic/strongly-typed use cases, so we provide `push`, which has similar semantics to operations from other languages (Rust's `push`, C#'s `Combine`, Python's `join`, and C++17's `append`). This allows programmatic use cases to explicitly choose semantics by calling either `other.push(myPath)` or `other.append(myPath.components)`.

### Paths and strings

`FilePath`, `FilePath.Component`, and `FilePath.Root` can be decoded/validated into a Swift `String`.

```swift
extension String {
  /// Creates a string by interpreting the path's content as UTF-8 on Unix
  /// and UTF-16 on Windows.
  ///
  /// If the content of the path isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public init(decoding path: FilePath)

  /// Creates a string from a file path, validating its contents as UTF-8
  /// on Unix and UTF-16 on Windows.
  ///
  /// If the contents of the path isn't well-formed Unicode,
  /// this initializer returns `nil`.
  public init?(validating path: FilePath)

  /// Creates a string by interpreting the path component's content as UTF-8 on
  /// Unix and UTF-16 on Windows.
  ///
  /// If the content of the path component isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public init(decoding component: FilePath.Component)

  /// Creates a string from a path component, validating its contents as UTF-8
  /// on Unix and UTF-16 on Windows.
  ///
  /// If the contents of the path component isn't well-formed Unicode,
  /// this initializer returns `nil`.
  public init?(validating component: FilePath.Component)

  /// On Unix, creates the string `"/"`
  ///
  /// On Windows, creates a string by interpreting the path root's content as
  /// UTF-16.
  ///
  /// If the content of the path root isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD.
  public init(decoding root: FilePath.Root)

  /// On Unix, creates the string `"/"`
  ///
  /// On Windows, creates a string from a path root, validating its contents as
  /// UTF-16.
  ///
  /// If the contents of the path root isn't well-formed Unicode,
  /// this initializer returns `nil`.
  public init?(validating root: FilePath.Root)
}
```

`FilePath`, `FilePath.Component`, and `FilePath.Root` gain convenience properties for viewing their content as `String`s.

```swift
extension FilePath {
  /// Creates a string by interpreting the path's content as UTF-8 on Unix
  /// and UTF-16 on Windows.
  ///
  /// This property is equivalent to calling `String(decoding: path)`
  public var string: String { get }
}

extension FilePath.Component {
  /// Creates a string by interpreting the component's content as UTF-8 on Unix
  /// and UTF-16 on Windows.
  ///
  /// This property is equivalent to calling `String(decoding: component)`.
  public var string: String { get }
}

extension FilePath.Root {
  /// On Unix, this returns `"/"`.
  ///
  /// On Windows, interprets the root's content as UTF-16.
  ///
  /// This property is equivalent to calling `String(decoding: root)`.
  public var string: String { get }
}
```

> **Rationale**: While we strongly encourage the use of strong types for handling paths and path operations, systems programming has a long history of using weakly typed strings as paths. These properties enable more rapid prototyping and easier testing while being far more discoverable and ergonomic than the corresponding `String` initializers. This API (anti)pattern is to be used sparingly.

### Separator normalization

`FilePath` normalizes directory separators on construction and maintains this invariant across mutations. In the relative portion of the path, `FilePath` strips trailing separators and coalesces repeated separators.

```swift
  FilePath("/a/b/") == "/a/b"
  FilePath("a///b") == "a/b"
```

Windows accepts either forward slashes (`/`) or backslashes (`\`) as directory separators, though the platform's preferred separator is backslash. On Windows, `FilePath` normalizes forward slashes to backslashes on construction. Separators after a UNC server/share or DOS device path's volume are treated as part of the root.

```swift
  FilePath("C:/foo/bar/") == #"C:\foo\bar"#
  FilePath(#"\\server\share\folder\"#) == #"\\server\share\folder"#
  FilePath(#"\\server\share\"#) == #"\\server\share\"#
  FilePath(#"\\?\volume\"#) == #"\\?\volume\"#
```

> **Rationale**: Normalization provides a simpler and safer internal representation. A trailing slash can give the false impression that the last component is a directory, leading to correctness and security hazards.

## Source compatibility

All changes are additive.

Existing users of `SystemPackage.FilePath` or `System.FilePath` may encounter ambiguity if they also have the standard library's `FilePath` in scope. The migration strategy is described below.

## ABI compatibility

This proposal is purely an extension of the ABI of the standard library and does not change any existing features.

On Darwin, `System.FilePath` currently has ABI commitments. Migration from the System module on Darwin can be handled through ABI-level redirection so that existing binaries linked against `System.FilePath` continue to work.

## Implications on adoption

Adopters will need a toolchain that includes this change. The type cannot be back-deployed to older runtimes without additional work.

For existing users of swift-system, `SystemPackage` (the SwiftPM package) can use `#if` conditionals to provide initializers and conversions between `SystemPackage.FilePath` and `Swift.FilePath` on toolchain versions that include this change, enabling a smooth source-compatible migration path. `System` (the Darwin framework) can perform ABI migration, redirecting the existing `System.FilePath` symbol to the standard library implementation, preserving binary compatibility for existing Darwin binaries.

## Future directions

### Platform string APIs and `CInterop`

swift-system defines a `CInterop` namespace with typealiases for platform-specific character types (`PlatformChar`, `PlatformUnicodeEncoding`) and provides `withPlatformString`/`init(platformString:)` APIs on `FilePath`, `FilePath.Component`, and `FilePath.Root`. These are important escape hatches for C interoperability. For now, these APIs remain in swift-system. Bringing them into the standard library would require a notion of what a "platform string" is at the standard library level, which is a larger design question.

### `SystemString`

swift-system internally uses a `SystemString` type that handles the underlying storage for `FilePath`. This type may be independently useful as a public type for working with null-terminated platform-encoded strings.

### Operations that consult the file system

Operations such as resolving symlinks, checking existence, and enumerating directory contents require system calls. These remain in swift-system and are not part of this proposal.

### `RelativePath` and `AbsolutePath`

Libraries and tools built on top of `FilePath` often raise some notion of "canonical" paths to type-level salience. This design space includes lexically-normalized absolute paths, semantically-normal paths (expanding symlinks and environment variables), and equivalency-normal paths (Unicode normalization, case-folding). Each tool may have a slightly different notion of "absolute" (e.g. whether `~` counts). We are deferring these types until the design space is better understood. Libraries and tools can define strongly-typed wrappers over `FilePath` that check their preconditions on initialization.

### Windows root analysis

Windows roots can be decomposed further into their syntactic form (traditional DOS vs. DOS device syntax) and their volume information (drive letter, UNC server/share). APIs for this decomposition could be added in the future.

### Paths from other platforms

A cross-platform application targeting a specific platform (e.g. a script that manages files on a remote Linux server) might want to construct and manipulate paths with the semantics of a platform other than the host. This could be addressed by explicit `UnixPath` and `WindowsPath` types conforming to a common protocol.

## Alternatives considered

### Do more: bring all of swift-system into the toolchain

As discussed in [system-in-the-toolchain](https://forums.swift.org/t/pitch-system-in-the-toolchain/84247), it may also make sense to have a `System` module in the toolchain for low-level OS interfaces and low-level currency types (like `FileDescriptor`, `Errno`, etc).

`FilePath` is different from these other types in that it transcends the entire tech stack, from kernel-level programming to high level scripts and automation. Note that we are not pulling in syscalls such as `FilePath.stat`, those will remain in System/SystemPackage.

### Add `FilePath` to a separate standard library module

`FilePath` could live in a new module (e.g. `FilePaths`, `Path`, `Files`, ...) that ships with the toolchain but requires an explicit import. Currency types lose much of their value when they require an import. `String`, `Array`, `Int`, and `Result` are all in the `Swift` module; it is our (weakly held) opinion `FilePath` should be too.

### Use Foundation's `URL`

Foundation's `URL` is designed for URI semantics, including scheme parsing and percent-encoding. File system paths and URIs have different structure and different invariants. For example, `URL(fileURLWithPath:)` and `URL.appendingPathComponent` make blocking file system calls, which is surprising for what appears to be a pure data type. On Unix, paths containing bytes that are not valid UTF-8 cannot survive conversion to a `file://` URL, which requires percent-encoding. Foundation also sits high in the dependency stack; the Swift runtime and toolchain components cannot depend on it.

### Do nothing

Every new API that needs to name a file will continue using `String`, perpetuating the loss of structure, platform correctness, and type safety that `FilePath` was designed to address.

## Acknowledgments

Thanks to [Saleem Abdulrasool](https://github.com/compnerd) for co-authoring the original `FilePath` syntactic operations design and implementation in swift-system. Thanks to the participants in the [System-in-toolchain discussion](https://forums.swift.org/t/pitch-system-in-the-toolchain/84247) and the [SE-0513 review](https://forums.swift.org/t/se-0513-api-to-get-the-path-to-the-current-executable/84800) for helping clarify that `FilePath` specifically belongs in the standard library.
