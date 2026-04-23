# Add `FilePath` to the Standard Library

* Proposal: [SE-0529](0529-filepath-in-stdlib.md)
* Authors: [Michael Ilseman](https://github.com/milseman), [Saleem Abdulrasool](https://github.com/compnerd)
* Review Manager: [John McCall](https://github.com/rjmccall)
* Status: **Active Review (April 22nd...May 4th, 2026)**
* Implementation: TBD
* Review: ([first pitch](https://forums.swift.org/t/pitch-add-filepath-to-the-standard-library/84812)) ([second pitch](https://forums.swift.org/t/pitch-2-add-filepath-to-stdlib/85695)) ([review](https://forums.swift.org/t/se-0529-add-filepath-to-the-standard-library/86194))

## Introduction

We propose adding `FilePath` and its essential operations to the Swift standard library. `FilePath` parses platform-specific path syntax on the developer's behalf, provides a normalized view of path components, and enables resolution against the filesystem. This proposal establishes the core types (`FilePath`, `FilePath.Anchor`, `FilePath.Component`, `FilePath.ComponentView`), their conformances, and the essential operations needed to adopt `FilePath` as a currency type. Additional syntactic convenience methods and platform-specific path decomposition API are planned as [future additions](#future-directions).

## Motivation

Swift has no standard representation for file system paths. The swift-system package introduced `FilePath` in [System 0.0.1](https://github.com/apple/swift-system/releases/tag/0.0.1), and it has since gained a comprehensive set of [syntactic operations](https://forums.swift.org/t/api-review-filepath-syntactic-apis-version-2/44197) for platform-correct path manipulation. But because `FilePath` lives in an external package, it cannot be depended on by the standard library or the Swift runtime, nor can it appear in API in toolchain libraries such as Foundation.

Every new API that needs to name a file path faces the same dilemma around using `String` that [SE-0513](https://forums.swift.org/t/se-0513-api-to-get-the-path-to-the-current-executable/84800) faces. `String` is a poor fit for paths as it does not capture the structure of a file path. Path string representations are also platform-specific and path components are not necessarily valid Unicode.

`FilePath` stores the path in its native platform encoding, enabling strongly-typed programming with paths. It encapsulates the platform-specific details of path syntax (separators, anchor forms, special components, even Darwin resource forks) so that developers can work with paths correctly without needing to understand each platform's conventions. In particular, `FilePath.Anchor` represents the initial portion of a path that identifies a volume or reference point (a drive letter, UNC share, Darwin resolve flag, etc.), which varies substantially across platforms and is very difficult to handle correctly as a string.

## Proposed solution

We propose adding `FilePath`, `FilePath.Anchor`, `FilePath.Component`, and `FilePath.ComponentView` to the `Swift` module, alongside essential functionality for construction, decomposition, resolution, and C interoperability.

```swift
var path: FilePath = "/var/www/static/index.html"

path.isAbsolute                      // true
path.hasTrailingSeparator            // false

print(path.anchor)                   // Optional(/)
for component in path.components {
    print(component, component.kind) // "var": .regular, "www": .regular, ...
}

// Resolve against the filesystem
let resolved = try path.resolve()

// Construct a path through mutation
var config: FilePath = "/etc/nginx"
config.components.append("nginx.conf")
// config is "/etc/nginx/nginx.conf"

// On Windows, transplant a conventional path to verbatim-component form
var winPath: FilePath = #"C:\Users\dev\project"#
winPath.anchor?.driveLetter            // Optional("C")
winPath.anchor?.isVerbatimComponent    // Optional(false)
winPath.anchor = #"\\?\C:\"#
print(winPath)                         // \\?\C:\Users\dev\project

// On Darwin, strip kernel resolve flags by replacing the anchor with `/`
var untrusted: FilePath = "/.nofollow/etc/passwd"
untrusted.anchor = "/"
print(untrusted)                       // /etc/passwd
```

## Detailed design

### `FilePath`

`FilePath` stores a null-terminated sequence of platform characters (`CChar` on Linux and Darwin, `UInt16` on Windows).

```swift
/// A file path is a null-terminated sequence of bytes that represents
/// a location in the file system.
public struct FilePath: Sendable {
  /// Creates an empty file path.
  public init()

  /// The platform directory separator character.
  ///
  /// On Linux and Darwin, this is `"/"`.
  /// On Windows, this is `"\"`.
  public static var separator: Character { get }

  /// Whether this path is empty.
  ///
  /// An empty path is the result of `FilePath()` or `FilePath("")`.
  /// Anchor-only paths such as `"/"` and `"C:\"` are not empty, nor is `"."`.
  public var isEmpty: Bool { get }
}
```

### Path decomposition

Every path can be understood as comprised of three parts: an *anchor*, a sequence of relative path components, and a *suffix*.

The anchor identifies a reference point and precedes any components. It may also encode platform-specific directives such as the syntax to use for interpreting the rest of the path (`\\?\` on Windows) or instructions to the kernel to error out in the presence of symlinks (`/.nofollow/` on Darwin).

Relative path components are non-empty opaque bags of bytes, excluding certain bytes that are part of the path syntax as parsed by the kernel (such as `NUL` or component separators). Some byte sequences (`.` and `..`) have special meaning in path syntax (outside of verbatim-component Windows paths) and the kernel will interpret them specially. Otherwise, components are the opaque names of entities on the file system and interpreting them in any way is outside the scope of `FilePath` for this proposal. See Future Directions for filesystem-specific and context-specific component interpretation such as Unicode normalization and case-insensitive comparison.

Finally, a path may have a suffix that instructs the kernel what to do after it has resolved the final path component. On Linux, Darwin, and Windows, this could be an optional trailing separator that tells the kernel to treat it as a directory (or to jump through a symlink). Darwin may (mutually exclusive with a trailing separator) have a resource fork with the fixed suffix of `/..namedfork/rsrc` to address a file's resource fork.

For example, the Linux path `/foo/bar` has an anchor of `/`, relative path components of `[foo, bar]`, and no trailing separator.

#### Anchors

On Linux, an anchor is simply root (`/`) for absolute paths. On Darwin, it may also include resolve flags (e.g. `/.nofollow/`, `/.resolve/3/`, etc.) and/or volume identifiers (e.g. `/.vol/1234/5678`). On Windows, the anchor encompasses a drive letter (`C:\`, `C:`), a UNC server/share (`\\server\share`), or a verbatim or device-namespace form (`\\?\C:\`, `\\.\pipe`), along with any root separator that is syntactically required.

```swift
extension FilePath {
  /// The anchor of a file path identifies a reference point
  /// and precedes any components.
  ///
  /// On Linux, the anchor is `/` for absolute paths.
  ///
  /// On Darwin, the anchor may additionally include kernel
  /// resolve flags (`/.nofollow/`, `/.resolve/3/`, etc.) or volume references
  /// (`/.vol/1234/5678`).
  ///
  /// On Windows, the anchor encompasses drive letters
  /// (`C:\`, `C:`), UNC names (`\\server\share`), device
  /// paths (`\\.\pipe`), verbatim paths (`\\?\C:\`), and
  /// the current-drive root (`\`).
  ///
  /// A path with no anchor is purely relative.
  public struct Anchor: Sendable {
    /// Whether this anchor is rooted.
    ///
    /// An anchor is rooted if it fixes the path to a volume root rather
    /// than to a working directory.
    ///
    /// On Linux and Darwin, all anchors are rooted.
    ///
    /// On Windows, the anchors `\`, `C:\`, `\\server\share`, `\\?\C:\`,
    /// and `\\.\pipe` are all rooted. `C:` is not: it names a drive but
    /// resolves relative to that drive's current working directory rather
    /// than the drive's root.
    public var isRooted: Bool { get }

    /// The drive letter of this anchor, if any.
    ///
    /// On Linux and Darwin, always `nil`.
    ///
    /// On Windows, returns the drive letter for anchors of the form
    /// `C:\`, `C:`, `\\?\C:\`, or `\\.\C:\`. Returns `nil` for UNC
    /// anchors, non-drive device anchors, and the current-drive root `\`.
    ///
    /// Examples:
    /// * `C:\`     => `"C"`
    /// * `c:`      => `"c"`
    /// * `\\?\C:\` => `"C"`
    /// * `\\.\C:\` => `"C"`
    /// * `\\.\pipe`       => `nil`
    /// * `\\server\share` => `nil`
    /// * `\`              => `nil`
    public var driveLetter: Character? { get }

    /// Whether this anchor uses the Windows verbatim-component form (`\\?\`).
    ///
    /// Inside verbatim-component paths, `/` is a legal component-name
    /// character, and `.` and `..` have no special directory meaning.
    ///
    /// Always `false` on Linux and Darwin.
    public var isVerbatimComponent: Bool { get }
  }

  /// The anchor of this path, if any.
  ///
  /// Returns `nil` for purely relative paths.
  ///
  /// Linux and Darwin:
  ///
  ///     /usr/bin                   => /
  ///     foo/bar                    => nil
  ///
  /// Darwin additionally:
  ///
  ///     /.nofollow/foo             => /.nofollow/
  ///     /.vol/1234/5678/foo        => /.vol/1234/5678
  ///
  /// Windows:
  ///
  ///     C:\foo                     => C:\
  ///     C:foo                      => C:
  ///     \foo                       => \
  ///     \\server\share\foo         => \\server\share
  ///     \\.\pipe\name              => \\.\pipe
  ///     \\.\NUL                    => \\.\NUL
  ///     \\?\C:\foo                 => \\?\C:\
  ///     \\?\UNC\server\share\foo   => \\?\UNC\server\share
  ///     foo\bar                    => nil
  ///
  public var anchor: Anchor? { get set }
}
```

##### Windows path styles

Windows paths fall into three styles, distinguished by their leading bytes. 

- **Conventional.** Drive-letter forms (`C:\...`, `C:...`), UNC forms (`\\server\share\...`), the current-drive root (`\...`), and rootless paths (`foo\bar`). Most code writes paths in this style. Here `/` is interchangeable with `\` as a separator, and `.` and `..` have their usual directory meaning.

- **Device-namespace.** Paths beginning with `\\.\`, followed by a Win32 device name (e.g. `\\.\pipe`, `\\.\NUL`, `\\.\COM1`, `\\.\PhysicalDrive0`). The anchor consists of `\\.\` plus the device name. Any components following the anchor apply inside that device's namespace. The special form `\\.\C:\...` is treated as a disk reference and exposes the drive letter via `Anchor.driveLetter`.

- **Verbatim-component.** Paths beginning with `\\?\`, which pass to the kernel with minimal normalization. `/` is a legal component-name character rather than a separator, and `.` and `..` are literal names rather than directory references. Three sub-forms are recognized: verbatim disk (`\\?\C:\...`), verbatim UNC (`\\?\UNC\server\share\...`), and verbatim plain (`\\?\name\...`).

> Note: Microsoft documentation does not give these styles canonical names. We introduce this terminology here so that this proposal and any follow-on work can refer to each style precisely. The boundary between conventional and device-namespace styles is fuzzy at the Win32 layer, where legacy device names such as `NUL` and `COM1` are rewritten to `\\.\NUL` and `\\.\COM1` before reaching the NT kernel. See the note on legacy device names below.

##### Darwin anchor canonicalization

Certain Darwin anchor forms have equivalent spellings that `FilePath` canonicalizes on construction, so that semantically-identical paths compare byte-wise equal.

- `/.resolve/1/` canonicalizes to `/.nofollow/`. Both refer to the same XNU do-not-follow-symlinks flag.
- `/.vol/NNNN/2/` canonicalizes to `/.vol/NNNN/@/`. Inside a volume reference, `@` is an alias for the root directory (inode 2).

Other resolve-flag numbers (`/.resolve/3/`, `/.resolve/5/`, etc.) and other inode numbers inside `/.vol/NNNN/MMMM/` are preserved as written.

##### Potential future platforms

Potential future platforms may have their own anchors and interpretations. For instance, POSIX allows implementation-defined meaning for paths beginning with _exactly_ two slashes (and no more). Linux chooses to treat two slashes the same as a single slash, but Cygwin uses this form for Windows interoperability: on Cygwin, `//server/share` maps to UNC paths and `//cygdrive/c` maps to the `C:` drive. This proposal's decomposition model would naturally and directly extend to supporting more platforms. E.g., under theoretical Cygwin support, `//cygdrive/c/foo/bar` would have an anchor of `//cygdrive/c/` (with a drive letter of `"c"`) and components `[foo, bar]`.

##### Absolute, relative, and rooted

All paths are relative to some reference point. We use the term "absolute" to refer to paths that are only "relative" to the root of a named volume. That is, they do not depend on the current working directory or current working drive (on Windows), environment variables (such as `$HOME`), the contents of `/etc/passwd`, etc. Absoluteness is a property of a path's anchor.

On Linux and Darwin, absolute paths begin with `/`. On Windows, absolute paths begin with a drive letter and root separator (e.g. `C:\`) or a UNC/device anchor (e.g. `\\server\share\`, `\\?\`, `\\.\`). Windows paths such as `\foo` and `C:foo` are relative: the former is relative to the current drive, while the latter is relative to the current directory on drive `C`.

Windows also has a notion of a path being "rooted" (see `Anchor.isRooted`) which is distinct from absolute. While all absolute paths are rooted, some rooted paths are relative. `\foo` is rooted in the sense that it is relative to the root of a volume, but that volume (i.e. the current drive) hasn't been named, so it is not absolute. On Linux and Darwin, rootedness is equivalent to absoluteness.

```swift
extension FilePath {
  /// Returns true if this path uniquely identifies the location of
  /// a file without reference to an additional starting location.
  ///
  /// On Linux and Darwin, absolute paths begin with `/`.
  ///
  /// On Windows, absolute paths are fully qualified: they begin with
  /// a drive letter followed by `:\` (e.g. `C:\`), or with a UNC,
  /// verbatim, or device anchor (e.g. `\\server\share\`, `\\?\C:\`,
  /// `\\.\pipe`).
  ///
  /// This does not perform shell expansion or substitute
  /// environment variables; paths beginning with `~` are considered relative.
  ///
  /// Examples:
  /// * Linux and Darwin:
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
  /// * Linux and Darwin:
  ///   * `~/bar`
  ///   * `tmp/foo.txt`
  /// * Windows:
  ///   * `bar\baz`
  ///   * `C:Users\`
  ///   * `\Users`
  public var isRelative: Bool { get }
}
```

> Note: Windows reserves certain legacy device names (e.g. `CON`, `NUL`, `COM1`) which it internally rewrites to device paths (e.g. `\\.\NUL`). This means that paths containing them could be treated as absolute by the NT kernel post Win32-canonicalization. Note that what "contains" means can vary by version of Windows (e.g. Windows 10 considers `COM1.txt` a device name while Windows 11 does not). FilePath does not emulate this rewriting and treats them as normal named components. See Future Directions for planned work around legacy device name handling.

> **Rationale**: The original pitch included a `FilePath.Root` type. `Root` does not cleanly accommodate all platform anchor forms: `C:foo` has a named drive but isn't rooted at the drive's root, so it isn't "root" in any meaningful sense. `Anchor` is a better name for this initial region: it names a reference point without asserting that reference point is a root. Python's `pathlib` has used `.anchor` for this concept since 3.4. Rust uses the name "prefix" for an analogous concept, but "prefix" suffers from being too general. While "prefix" could refer to the whole region before the relative path components, it could also specifically refer to the metadata denoted by the fixed-length portion prior to the volume identifiers, such as the verbatim-component designator on Windows (`\\?\`) or resolve flags on Darwin (`/.nofollow`, `/.resolve/N`) prior to the actual volume or root. Also, `Sequence.prefix` already exists with a different meaning. "Anchor" better conveys the role the initial region plays in a path.

#### `FilePath.Component`

`FilePath.Component` represents a single component of a path. Components are always non-empty and do not contain a directory separator.

```swift
extension FilePath {
  /// Represents an individual component of a file path.
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
  ///     path.components.append(file)    // path is "/tmp/foo.txt"
  ///
  public struct Component: Sendable {
    /// Whether a component is a regular file or directory name, or a special
    /// directory `.` or `..`
    ///
    /// Classification reflects the component's effective meaning in its
    /// originating path context. On Windows verbatim-component paths,
    /// `.` and `..` have no special directory meaning and are classified
    /// as `.regular`. When a component is inserted into a path with a
    /// different context (for example, a component constructed via
    /// `init(verbatim:)` inserted into a non-verbatim path), its kind
    /// is re-classified against the destination path's anchor.
    /// See `var kind` below.
    public enum Kind: Sendable {
      /// The special directory `.`, representing the current directory.
      case currentDirectory

      /// The special directory `..`, representing the parent directory.
      case parentDirectory

      /// A file or directory name.
      case regular
    }

    /// The kind of this component.
    ///
    /// On Windows verbatim-component paths (`\\?\`), `.` and `..` are valid file
    /// or directory names, not special directories. Components that are
    /// `.` or `..` inside a verbatim-component path have kind `.regular`.
    public var kind: Kind { get }
  }
}

#if os(Windows)
extension FilePath.Component {
  /// Creates a component treating the input as verbatim component content.
  ///
  /// Unlike `init?(_:)`, this initializer accepts strings containing `/`,
  /// which is a legal component-name character inside Windows
  /// verbatim-component (`\\?\`) paths. The resulting component has
  /// `kind == .regular` regardless of whether the string is `.` or `..`.
  ///
  /// Returns `nil` if `string` is empty or contains `\`, `NUL`, or any
  /// other character that is invalid even in verbatim-component paths.
  public init?(verbatim string: String)

  /// Creates a component treating the code units as verbatim component content.
  ///
  /// Unlike `init?(codeUnits:)`, this initializer accepts spans containing
  /// `/`, which is a legal component-name character inside Windows
  /// verbatim-component paths. The resulting component has `kind == .regular`
  /// regardless of whether the content is `.` or `..`.
  ///
  /// Returns `nil` if the span is empty or contains `\`, `NUL`, or any other
  /// character that is invalid even in verbatim-component paths.
  public init?(verbatim codeUnits: Span<FilePath.CodeUnit>)
}
#endif


```

#### `FilePath.ComponentView`

`FilePath.ComponentView` is a `BidirectionalCollection` and `RangeReplaceableCollection` of the relative path components that comprise a path. It covers everything after the anchor in a path and until the suffix. It presents a normalized view of the components:

- Repeated separators are ignored (i.e. no empty components)
  - `a///b` yields components `[a, b]`
- On non-verbatim-component Windows paths, `/` is treated as `\`
  - `a/b` and `a\b` yield components `[a, b]`
- A `.` component is ignored unless it is the first component of a rootless path:
  - `a/./b`, `/./a/b`, and `a/b/.` yield components `[a, b]`
  - `./foo` yields `[., foo]` where the first component has `kind == .currentDirectory`
- `..` components are always presented: `a/../b` yields `[a, .., b]`

On Windows verbatim-component paths (`\\?\`), `.` and `..` are not special directory references and are not dropped from the component view. They are presented as components with `kind == .regular`. Classification of a component as `.currentDirectory`, `.parentDirectory`, or `.regular` therefore depends on the anchor of the path it originated from, not on its bytes alone.

```swift
extension FilePath {
  /// A bidirectional, range-replaceable collection of the
  /// components that make up a file path.
  ///
  /// Example:
  ///
  ///     var path: FilePath = "/home/username/scripts/tree"
  ///     let scriptIdx = path.components.lastIndex(of: "scripts")!
  ///     path.components.insert("bin", at: scriptIdx)
  ///     // path is "/home/username/bin/scripts/tree"
  ///
  public struct ComponentView:
    BidirectionalCollection, RangeReplaceableCollection, Sendable,
    Hashable, Comparable
  { }

  /// View the relative path components that make up this path.
  public var components: ComponentView { get set }
}
```

#### Suffixes

A *suffix* is a platform directive that appears after the final relative component of a path and instructs the kernel what to do once the rest of the path has been resolved. Suffixes are not components and are not returned by `ComponentView`, but they are semantically meaningful and affect equality.

Two suffix forms exist. *Trailing separators* (on Linux, Darwin, and Windows) assert that the path's final component names a directory and request symlink resolution at that final component. *Resource fork suffixes* (`/..namedfork/rsrc`, Darwin-only) select the resource fork of the named file. The two forms are mutually exclusive: a path has at most one suffix.

##### Trailing separators

A trailing separator is a directory separator at the end of a path that is not syntactically part of the path anchor. Trailing separators carry meaning at the syscall level: on POSIX, a trailing `/` is equivalent to appending `.`, which forces symlink resolution at the final component and asserts that the result is a directory. For example, if `/tmp/link` is a symlink to a directory, `lstat("/tmp/link")` examines the symlink itself, while `lstat("/tmp/link/")` follows it. And `open("/tmp/foo/", O_RDONLY)` will fail with `ENOTDIR` if `foo` is a regular file, whereas `open("/tmp/foo", O_RDONLY)` will succeed. Similar semantics apply on Windows.

`FilePath` preserves trailing separators. This is a behavioral change from `System.FilePath`, which stripped them on construction. Python's `pathlib` made the same choice to strip trailing separators and this is widely considered a mistake.

Because trailing separators are semantically meaningful, they are significant for equality: `FilePath("/tmp/foo") != FilePath("/tmp/foo/")`. Code that wants to treat these as equivalent can explicitly remove the trailing separator before comparison.

```swift
extension FilePath {
  /// Whether this path ends with a directory separator that is
  /// not structurally required by the path's anchor.
  ///
  /// `/tmp/foo/` returns `true`. `/tmp/foo` returns `false`.
  /// `/` and `C:\` return `false` because their separators are
  /// part of the anchor syntax. `\\server\share\` and
  /// `/.vol/1234/5678/` return `true` because the named volume
  /// is complete without the trailing separator.
  ///
  /// Setting this to `true` appends a trailing separator if one
  /// is not already present. Setting it to `false` removes the
  /// trailing separator if present. On Darwin, setting `true`
  /// on a path with a resource fork suffix replaces the suffix
  /// with a trailing separator.
  public var hasTrailingSeparator: Bool { get set }

  /// Returns a copy of this path with a trailing separator added.
  /// If the path already has a trailing separator, or is empty,
  /// returns the path unchanged. On Darwin, if the path has a resource
  /// fork suffix, the suffix is replaced by the trailing separator.
  public func withTrailingSeparator() -> FilePath

  /// Returns a copy of this path with the trailing separator removed.
  /// If the path has no trailing separator, returns the path unchanged.
  public func withoutTrailingSeparator() -> FilePath
}
```

##### (Darwin-only) Resource forks

On Darwin, a file may have both a data fork (its ordinary content) and a resource fork (an auxiliary data stream). The XNU kernel addresses a resource fork by appending the fixed suffix `/..namedfork/rsrc` to a path during path lookup. For example, given a file at `/foo/bar`, the path `/foo/bar/..namedfork/rsrc` identifies the resource fork of that file. The kernel recognizes this suffix only when it appears verbatim at the end of the path, right up to the null terminator.

This suffix is directly analogous to a trailing separator: it is not a relative component but a directive to the kernel about what to do after resolving the final component. Like a trailing separator, it is semantically meaningful (it selects a different byte stream) and affects `==`. It is mutually exclusive with a trailing separator.

`FilePath` recognizes this suffix during parsing and does not present `..namedfork` and `rsrc` as relative components, because they are part of the suffix directive rather than names on the filesystem.

```swift
#if canImport(Darwin)
extension FilePath {
  /// Whether this path ends with a resource fork reference
  /// (`/..namedfork/rsrc`).
  ///
  /// When true, the path identifies the resource fork of the
  /// entity named by the final component. The `/..namedfork/rsrc`
  /// suffix is consumed by the XNU kernel during path lookup
  /// and is not presented as components in `ComponentView`.
  ///
  /// Mutually exclusive with `hasTrailingSeparator`. Setting this
  /// to `true` appends the resource fork suffix; if the path has
  /// a trailing separator, the separator is replaced by the suffix.
  /// Setting it to `false` removes the suffix if present.
  ///
  ///     FilePath("/foo/..namedfork/rsrc").isResourceFork  // true
  ///     FilePath("/foo").isResourceFork                    // false
  ///     FilePath("/foo/..namedfork/rsrc/").isResourceFork // false
  ///
  public var isResourceFork: Bool { get set }

  /// Returns a copy of this path with `/..namedfork/rsrc` appended.
  ///
  /// If the path is already a resource fork reference, returns self.
  /// If the path has a trailing separator, the trailing separator
  /// is replaced by the resource fork suffix.
  public func withResourceFork() -> FilePath

  /// Returns a copy of this path with the resource fork suffix removed.
  ///
  /// If the path is not a resource fork reference, returns self.
  public func withoutResourceFork() -> FilePath
}
#endif
```

> Note: Resource forks are a relatively obscure Darwin feature, so this proposal provides only the minimal API needed to observe and manipulate the suffix. No cross-platform surface area is proposed. The essential requirement is that `FilePath` parse these suffixes correctly (they are not relative components) and that developers have some way to observe and remove them, mirroring the trailing-separator API.

#### Path reconstruction

An inverse of decomposition: construct a path from an anchor, a sequence of components, and a suffix (a trailing separator or, on Darwin, a resource fork). Useful when transplanting an anchor onto existing components, when assembling a path from independently-computed parts, or when a developer wants explicit control over each axis of the decomposition.

The reconstructed path parses and normalizes exactly as if the equivalent string literal had been provided. Duplicate separators between components are not possible (components cannot contain separators); interior `.` components, if any, are dropped by normalization in non-verbatim paths; `..` components are preserved.

```swift
extension FilePath {
  /// Creates a file path from a decomposed form.
  ///
  /// If `anchor` is nil, the resulting path is relative. Otherwise, its
  /// anchor is set to the provided anchor.
  ///
  /// If `hasTrailingSeparator` is `true` and the resulting path is
  /// non-empty and does not already end in a separator structurally
  /// required by the anchor, a trailing separator is appended.
  public init(
    anchor: Anchor?,
    _ components: some Sequence<Component>,
    hasTrailingSeparator: Bool = false
  )
}

#if canImport(Darwin)
extension FilePath {
  /// Creates a file path from a decomposed form with a
  /// resource fork suffix.
  ///
  /// If `resourceFork` is `true`, the resulting path ends with the
  /// resource fork suffix (`/..namedfork/rsrc`). Resource forks are
  /// mutually exclusive with trailing separators; to construct a
  /// path with a trailing separator, use the cross-platform
  /// initializer.
  public init(
    anchor: Anchor?,
    _ components: some Sequence<Component>,
    resourceFork: Bool
  )
}
#endif
```

#### Decomposition examples

The following table illustrates path decomposition.

**Linux and Darwin:**

| Input | Anchor | Components | Trailing separator? |
|-------|--------|------------|:---:|
| `/usr/local/bin` | `/` | `[usr, local, bin]` | no |
| `/tmp/foo/` | `/` | `[tmp, foo]` | yes |
| `foo/bar` | -- | `[foo, bar]` | no |
| `.` | -- | `[.]` | no |
| `./foo/bar` | -- | `[., foo, bar]` | no |
| `/` | `/` | `[]` | no |
| (empty) | -- | `[]` | no |
| `/./foo` | `/` | `[foo]` | no |
| `foo/./bar` | -- | `[foo, bar]` | no |
| `foo/.` | -- | `[foo]` | yes |
| `a///b` | -- | `[a, b]` | no |
| `..` | -- | `[..]` | no |
| `a/b/../c` | -- | `[a, b, .., c]` | no |

**Darwin-specific:**

| Input | Anchor | Components | Trailing separator or resource fork? |
|-------|--------|------------|:---:|
| `/.nofollow/foo/bar` | `/.nofollow/` | `[foo, bar]` | no |
| `/.resolve/1/foo/bar` | `/.nofollow/` (canonicalized) | `[foo, bar]` | no |
| `/.resolve/3/foo/bar` | `/.resolve/3/` | `[foo, bar]` | no |
| `/.vol/1234/5678/foo/bar` | `/.vol/1234/5678` | `[foo, bar]` | no |
| `/.vol/1234/2/foo` | `/.vol/1234/@` (canonicalized) | `[foo]` | no |
| `/.vol/1234/5678/` | `/.vol/1234/5678` | `[]` | yes (trailing separator) |
| `foo/bar/file/..namedfork/rsrc` | -- | `[foo, bar, file]` | yes (resource fork) |

**Windows:**

| Input | Anchor | Components | Trailing separator? |
|-------|--------|------------|:---:|
| `C:\foo\bar` | `C:\` | `[foo, bar]` | no |
| `C:foo\bar` | `C:` | `[foo, bar]` | no |
| `\foo` | `\` | `[foo]` | no |
| `\\server\share\foo` | `\\server\share` | `[foo]` | no |
| `\\server\share\` | `\\server\share` | `[]` | yes |
| `\\.\pipe\name` | `\\.\pipe` | `[name]` | no |
| `\\.\NUL` | `\\.\NUL` | `[]` | no |
| `\\.\PhysicalDrive0\foo` | `\\.\PhysicalDrive0` | `[foo]` | no |
| `\\.\C:\foo\.\bar` | `\\.\C:\` | `[foo, bar]` | no |
| `\\?\pictures\kittens` | `\\?\pictures` | `[kittens]` | no |
| `\\?\UNC\server\share\foo` | `\\?\UNC\server\share` | `[foo]` | no |
| `\\?\C:\foo\.\bar` | `\\?\C:\` | `[foo, ., bar]` | no |
| `\\.\UNC\server\share\foo` | `\\.\UNC` | `[server, share, foo]` | no |

In the last Windows example, `.` appears as a component with `kind == .regular` because it is inside a verbatim-component path where `.` has no special meaning.

Note that the `\` in `\\server\share\` or other UNC forms is a trailing separator on Windows, because the named volume itself (`\\server\share`) is considered a complete root (see `PathCchIsRoot` on Windows). Similarly, the final `/` in `/.vol/1234/5678/` on Darwin is a trailing separator, as the named volume (`/.vol/1234/5678`) is also a complete root.


### Resolution

Resolution is the process of producing an absolute form of a path by consulting the filesystem. A resolved path is absolute, contains no symbolic links, and contains no current-directory (`.`) or parent-directory (`..`) components.

Because resolution requires filesystem access, it is a throwing operation and all intermediate components must exist. The result of resolution is a snapshot: subsequent changes to the filesystem (such as creating or removing symbolic links) may invalidate the resolution status.

> Note: Windows verbatim-component paths (`\\?\`) treat `.` and `..` as literal component names rather than special directory references. Such components may remain in a resolved path. The `Component` and `ComponentView` types described above correctly handle these as regular components.

```swift
extension FilePath {
  /// Resolve this path against the filesystem, producing an absolute
  /// path with all symbolic links and `.`/`..` components resolved.
  ///
  /// All intermediate components must exist. Throws if the path
  /// cannot be resolved.
  public func resolve() throws -> FilePath
}
```

> Note: On Darwin, resolution may insert resolve flags into the anchor: `/.nofollow/foo/bar` means do-not-follow-symlinks for `/foo/bar`. Future API includes ways to suppress or modify this behavior.

Lexical resolution (collapsing `..` without consulting the filesystem) and lexical resolve-beneath (ensuring a subpath does not escape a base directory) were part of the [original pitch](https://forums.swift.org/t/pitch-add-filepath-to-the-standard-library/84812). They are deferred to future work.

True snapshot-in-time path equivalence (operations that account for things like hardlinks and volume mounts) is also deferred as future work. (For example, the Darwin paths `/foo/bar` and `/.vol/1234/5678` might refer to the exact same entity.)


### Printing, comparing, and hashing

`FilePath` conforms to `CustomStringConvertible`. Its `description` prints the anchor (if any), followed by the components joined by the platform separator, followed by a trailing separator or resource fork suffix if present. You can also make a `FilePath` from a `String` or string literal expression.

`FilePath.Anchor` and `FilePath.Component` also conform. Their unlabeled `String` initializers are failable, as the developer might not have passed in valid anchors or components. String literal inits will trap (currently at runtime, future work is to expose more of this as compile-time errors) if given invalid anchors or components.

```swift
extension FilePath:
  Hashable, Comparable,
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

  /// Creates a file path from a string literal.
  public init(stringLiteral: String)

  /// Creates a file path from a string.
  public init(_ string: String)
}

extension FilePath.Anchor:
  Hashable, Comparable,
  CustomStringConvertible, CustomDebugStringConvertible,
  ExpressibleByStringLiteral
{
  /// A textual representation of the anchor.
  ///
  /// If the content isn't well-formed Unicode, invalid bytes
  /// are replaced with U+FFFD. See `String.init(decoding:)`.
  public var description: String { get }

  /// A textual representation of the anchor, suitable for debugging.
  public var debugDescription: String { get }

  /// Creates an anchor from a string literal.
  ///
  /// Precondition: the literal is non-empty and forms a
  /// valid anchor.
  public init(stringLiteral: String)

  /// Creates an anchor from a string.
  ///
  /// Returns `nil` if `string` is empty or is not a valid anchor.
  public init?(_ string: String)
}

extension FilePath.Component:
  Hashable, Comparable,
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

  /// Creates a file path component from a string literal.
  ///
  /// Precondition: `stringLiteral` is non-empty and has only one component in it.
  public init(stringLiteral: String)

  /// Creates a file path component from a string.
  ///
  /// Returns `nil` if `string` is empty, a root, or has more than one component
  /// in it.
  public init?(_ string: String)
}

```


Two `FilePath` values are equal when they have identical anchors, their component views yield identical sequences, and they agree on the presence of a trailing separator or resource fork suffix.

```swift
// Printing reflects the normalized component view
print(FilePath("a///b"))      // "a/b"
print(FilePath("a/./b"))      // "a/b"
print(FilePath("/./foo"))     // "/foo"
print(FilePath("/tmp/foo/"))  // "/tmp/foo/"
print(FilePath("."))          // "."

// Comparison compares anchors, then normalized components, then suffix information (i.e. trailing separator or resource fork)
FilePath("a///b") == FilePath("a/b")          // true: both print as "a/b"
FilePath("a/./b") == FilePath("a/b")          // true: both print as "a/b"
FilePath("/./foo") == FilePath("/foo")        // true: both print as "/foo"
FilePath("/tmp/foo/") == FilePath("/tmp/foo/") // true

FilePath("/tmp/foo") != FilePath("/tmp/foo/") // true: trailing separator differs
FilePath(".") != FilePath("")                 // true: "." vs ""

FilePath("/.nofollow/foo/bar") != FilePath("/foo/bar")    // true: differing anchors (Darwin)
FilePath(#"\\.\C:\foo\bar"#) != FilePath(#"C:\foo\bar"#)  // true: differing anchors (Windows)
```

`FilePath.==` tells you whether two paths are spelled the same way, after accounting for meaningless encoding differences like repeated separators and interior `.` components. It is purely syntactic and does not consult the filesystem. This makes it useful for storage and retrieval in data structures such as `Dictionary` or a sorted array. FilePath's comparison semantics provide an ergonomic and intuitive sense of substitutability: two paths compare equal precisely when they print the same (modulo Unicode error correction via `U+FFFD`).

A file path is analogous to a sequence of directions that instruct the kernel on how to traverse the virtual file system in conjunction with the file system driver. Two different sets of directions compare as unequal, even if they might reach the same destination (e.g. due to hardlinks, symlinks, parent-directory resolution, etc.). For example, the XNU path `/.nofollow/foo/bar` is different from `/foo/bar` because the former's directions to the kernel include a provision that the kernel error out if it encounters a symlink along the way. Similarly, trailing slashes are semantically meaningful because they instruct the kernel to follow any symlink at the final component and to verify that the result is a directory.

`Comparable` provides a deterministic ordering suitable for sorted collections. The ordering is lexicographic over the path's normalized byte representation, which is platform-specific (see "Path decomposition" above): anchor bytes first, then component bytes in sequence, with trailing separator or resource fork suffix as a final tiebreaker.

`ComponentView` also conforms to `Hashable` and `Comparable`. Its comparison and hashing consider only the relative component portion of the path, not the anchor or suffix.

Support for other comparison modes (case-insensitive, filesystem-aware equivalence) is future work and likely belongs in a dedicated library or as a comparator parameter. `FilePath` is a resilient type and comparison is non-inlinable, so the ABI accommodates changes to internal representation if they prove necessary.

### Paths and strings

`FilePath`, `FilePath.Anchor`, and `FilePath.Component` can be decoded/validated into a Swift `String`.

```swift
extension String {
  /// Creates a string by interpreting the path's content as UTF-8 on Linux
  /// and Darwin and UTF-16 on Windows.
  ///
  /// If the content of the path isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public init(decoding path: FilePath)

  /// Creates a string from a file path, validating its content as UTF-8
  /// on Linux and Darwin and UTF-16 on Windows.
  ///
  /// If the content of the path isn't well-formed Unicode,
  /// this initializer returns `nil`.
  public init?(validating path: FilePath)

  /// Creates a string by interpreting the anchor's content as UTF-8 on Linux
  /// and Darwin and UTF-16 on Windows.
  ///
  /// If the content of the anchor isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public init(decoding anchor: FilePath.Anchor)

  /// Creates a string from an anchor, validating its content as UTF-8
  /// on Linux and Darwin and UTF-16 on Windows.
  ///
  /// If the content of the anchor isn't well-formed Unicode,
  /// this initializer returns `nil`.
  public init?(validating anchor: FilePath.Anchor)

  /// Creates a string by interpreting the path component's content as UTF-8 on
  /// Linux and Darwin and UTF-16 on Windows.
  ///
  /// If the content of the path component isn't well-formed Unicode,
  /// this replaces invalid bytes with U+FFFD. See `String.init(decoding:)`.
  public init(decoding component: FilePath.Component)

  /// Creates a string from a path component, validating its content as UTF-8
  /// on Linux and Darwin and UTF-16 on Windows.
  ///
  /// If the content of the path component isn't well-formed Unicode,
  /// this initializer returns `nil`.
  public init?(validating component: FilePath.Component)
}
```

> NOTE: This API is severable; we could instead have developers extract a string via `.description` or alternatively defer string creation to the code units themselves (noting this would require `#if` due to `CChar/UInt16` differences).

### Access to underlying bytes and C interop

`FilePath` provides access to the underlying null-terminated platform bytes for C interoperability.

```swift
extension FilePath {
#if !os(Windows)
  /// The type used to represent a "character" in the platform's
  /// native path encoding
  public typealias CodeUnit = CChar
#else
  /// The type used to represent a "character" in the platform's
  /// native path encoding
  public typealias CodeUnit = UInt16
#endif

  /// A span of the platform code units, including the null terminator, comprising this path.
  ///
  /// This is useful for C interoperability. For just the path-relevant bytes, see `var codeUnits`.
  public var nullTerminatedCodeUnits: Span<FilePath.CodeUnit> { get }
}
```

`FilePath`, `FilePath.Anchor`, `FilePath.Component`, and `FilePath.ComponentView` provide `Span`-based access to their underlying bytes. Components do not contain directory separators or null terminators.

```swift
extension FilePath.Component {
  /// A span of the platform code units comprising this component.
  public var codeUnits: Span<FilePath.CodeUnit> { get }

  /// Creates a file path component from a span of platform code units.
  ///
  /// Returns `nil` if the code units are empty or invalid (e.g. has more than one component
  /// in it).
  public init?(codeUnits: Span<FilePath.CodeUnit>)
}

extension FilePath.ComponentView {
  /// A span of the platform code units comprising the relative
  /// components portion of the path.
  public var codeUnits: Span<FilePath.CodeUnit> { get }
}

extension FilePath.Anchor {
  /// A span of the platform code units comprising this anchor.
  public var codeUnits: Span<FilePath.CodeUnit> { get }
}

extension FilePath {
  /// A span of the platform code units comprising this path, not including the null terminator.
  public var codeUnits: Span<FilePath.CodeUnit> { get }

  /// Creates a file path from a span of platform code units.
  ///
  /// The span should not include a null terminator.
  public init(codeUnits: Span<FilePath.CodeUnit>)

  /// Creates a file path with the specified capacity, and then calls the
  /// given closure with an output span covering the path's uninitialized
  /// memory.
  ///
  /// Capacity does not include the null terminator.
  public init<E: Error>(
    capacity: Int,
    initializingCodeUnitsWith initializer: (inout OutputSpan<FilePath.CodeUnit>) throws(E) -> Void
  ) throws(E)

}
```

> **Note**: There is no corresponding code units init on `FilePath.ComponentView`. That would be redundant with the code units init on `FilePath` for relative path code units, and would probably want to return `nil` for paths that have anchors. Instead, you can init a `FilePath` and ask for its component view.

Future work includes adopting whatever standard library pattern emerges for null-terminated byte sequences.

## Source compatibility

All changes are additive.

`SystemPackage.FilePath` and/or `System.FilePath` can migrate to the standard library's `FilePath` via a conditional typealias:

```swift
#if compiler(>=6.4) // or whichever version this lands in
public typealias FilePath = Swift.FilePath
#else
public struct FilePath { ... }
#endif
```

Existing functionality from `SystemPackage.FilePath` (such as syntactic convenience methods) can be added as extensions on `Swift.FilePath` on toolchain versions that include this change. This enables a smooth source-compatible migration path.

swift-system's `FilePath.Root` should be formally deprecated in favor of `FilePath.Anchor` as the cross-platform abstraction.

## ABI compatibility

This proposal is purely an extension of the ABI of the standard library and does not change any existing features.

On Darwin, `System.FilePath` currently has ABI commitments. Migration from the System module on Darwin can be handled through ABI-level redirection so that existing binaries linked against `System.FilePath` continue to work.

## Implications on adoption

Adopters will need a toolchain that includes this change. The type cannot be back-deployed to older runtimes without additional work.

For existing users of swift-system, `SystemPackage` (the SwiftPM package) can use `#if` conditionals as described above. `System` (the Darwin framework) can perform ABI migration, redirecting the existing `System.FilePath` symbol to the standard library implementation, preserving binary compatibility for existing Darwin binaries.

## Future directions

### Syntactic operations

Future API for `FilePath` could include additional syntactic operations, such as [originally pitched](https://forums.swift.org/t/pitch-add-filepath-to-the-standard-library/84812). This includes convenience accessors like `lastComponent`, `stem`, `extension`, `removingLastComponent()`, and mutation methods like `append`, `push`, `removePrefix`. These can be expressed in terms of the `ComponentView` and are back-deployable.

### Lexical resolution and resolve-beneath

Lexical operations that collapse `..` components without consulting the filesystem, and operations that ensure a subpath does not escape a base directory, are important for sandboxing and security-sensitive code. These were part of the original pitch and are planned as future additions. Real resolution (via `resolve()`) is provided in this proposal to ensure developers have the correct tool available from day one.


### Platform-specific Anchor API

`Anchor` is well-positioned for further platform-specific decomposition and analysis, such as in this [strawperson](https://gist.github.com/milseman/c76f878ad58ed6d2463c935f58233184).

### Platform string APIs and `CInterop`

swift-system defines a `CInterop` namespace with typealiases for platform-specific character types (`PlatformChar`, `PlatformUnicodeEncoding`) and provides `init(platformString:)` APIs on `FilePath` and its subtypes. This proposal provides `nullTerminatedCodeUnits` for passing paths to C APIs, and `Span`-based access on each of the path subtypes (`FilePath`, `Anchor`, `Component`, and `ComponentView`). Future work could include a `PlatformChar` typealias and more functionality along these lines.

### Path parsing APIs and verbatim storage modes

Future work includes exposing `FilePath`'s internal parser for uses over borrowed storage (such as `Span`), allowing developers to parse paths in-place without copying into a `FilePath`.

Some use cases (logging, diagnostics) benefit from preserving the exact bytes of a path as originally provided, without any normalization. These would be better handled by referring to the actual original data, possibly facilitated with path parsing API over borrowed storage. But, if it proves to be an essential use case, `FilePath` as pitched is sufficiently resilient that we could add a verbatim storage mode in the future.


### `SystemString`

swift-system internally uses a `SystemString` type that handles the underlying storage for `FilePath`. A similar type may be independently useful as a public type for working with null-terminated platform-encoded strings with opaque contents.

### More path types and filesystem-specific functionality

Future work could include a paths library or package that adds:

- Type-enforced invariants: `AbsolutePath`, `ResolvedPath`, etc.
- Platform-specific foreign path types: `XNUPath`, `Win32Path`, `WinNTPath`, etc.
- File-system specific (and configuration specific) functionality over components: case conversion, Unicode normalization, etc.

Testing Windows path behavior on Linux/macOS (and vice versa) is a known gap that platform-specific path types could address; these could conform to a common protocol while each implementing the semantics of its target platform.

### Legacy device name handling

On Windows, legacy device names (`CON`, `NUL`, `COM1`, etc.) receive special treatment from the Win32 layer, and their exact handling varies across Windows versions. Future work could add detection or mitigation for these names, potentially as part of a resolve-beneath or sandboxing API.

## Alternatives considered

### Do more in Swift 6.4

The [original pitch](https://forums.swift.org/t/pitch-add-filepath-to-the-standard-library/84812) included a `FilePath.Root` type, convenience methods (`lastComponent`, `stem`, `extension`, `starts(with:)`, `append`, `push`), and lexical resolution operations. We chose to defer these in favor of shipping the essential core: the type, its conformances, the component view, and real resolution. The deferred API can be added as extensions on `FilePath` and is back-deployable where expressed in terms of the component view. Shipping the type and conformances first is critical because those cannot be added retroactively without migration costs (e.g. someone conforming `FilePath` to `Hashable` themselves).

### Include `Codable` conformance

`FilePath` intentionally does not conform to `Codable`. Serialized paths are inherently platform-specific: a path serialized on Linux or Darwin is not meaningful on Windows. Furthermore, even if paths on the same platform may parse the same in different versions, the meaning of paths can differ version-to-version of the OS: Windows 10 and 11 differ in device name recognition and Darwin may add new resolve flag values. The existing `Codable` conformance on `System.FilePath` uses an awkward binary encoding that has been a source of friction. Rather than commit the standard library to a serialization format, we leave serialization to application-level code that can choose a format appropriate to its needs. `String(decoding:)` and `init(_ string:)` provide the necessary conversion.

### Do more: bring all of swift-system into the toolchain

As discussed in [system-in-the-toolchain](https://forums.swift.org/t/pitch-system-in-the-toolchain/84247), it may also make sense to have a `System` module in the toolchain for low-level OS interfaces and low-level currency types (like `FileDescriptor`, `Errno`, etc).

`FilePath` is different from these other types in that it transcends the entire tech stack, from kernel-level programming to high level scripts and automation. Note that we are not pulling in syscalls such as `FilePath.stat`, those will remain in System/SystemPackage.

### Add `FilePath` to a separate standard library module

`FilePath` could live in a new module (e.g. `FilePaths`, `Path`, `Files`, ...) that ships with the toolchain but requires an explicit import. Currency types lose much of their value when they require an import. `String`, `Array`, `Int`, and `Result` are all in the `Swift` module; it is our opinion `FilePath` should be too.

### Use Foundation's `URL`

Foundation's `URL` is designed for URI semantics, including scheme parsing and percent-encoding. File system paths and URIs have different structure and different invariants. For example, `URL(fileURLWithPath:)` and `URL.appendingPathComponent` make blocking file system calls, which is surprising for what appears to be a pure data type. On Linux and Darwin, paths containing bytes that are not valid UTF-8 cannot survive conversion to a `file://` URL, which requires percent-encoding. Foundation also sits high in the dependency stack; the Swift runtime and toolchain components cannot depend on it.

### Do nothing

Every new API that needs to name a file will continue using `String`, perpetuating the loss of structure, platform correctness, and type safety that `FilePath` was designed to address.

## Acknowledgments

Thanks to [Saleem Abdulrasool](https://github.com/compnerd) for co-authoring the original `FilePath` syntactic operations design and implementation in swift-system. Thanks to the participants in the [System-in-toolchain discussion](https://forums.swift.org/t/pitch-system-in-the-toolchain/84247), the [SE-0513 review](https://forums.swift.org/t/se-0513-api-to-get-the-path-to-the-current-executable/84800), and the [first pitch thread](https://forums.swift.org/t/pitch-add-filepath-to-the-standard-library/84812) for helping shape this proposal.
