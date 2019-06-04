// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation

// MARK: - HTML Protocol and base implementations

/// An object that is capable of rendering itself and its children as HTML, with
/// the provided list of attributes.
public protocol HTML {
  /// Renders the contents of this object as HTML to the provided output stream
  /// as formatted HTML text.
  /// - Parameters:
  ///   - stream: The stream to print the resulting HTML to.
  ///   - attributes: Attributes from `AttributedNode`s higher in the node
  ///                 hierarchy.
  func renderAsHTML(into stream: HTMLOutputStream, attributes: [Attribute])
}

/// Strings are HTML nodes that escape their contents and print on a line.
extension String: HTML {
  public func renderAsHTML(
    into stream: HTMLOutputStream,
    attributes: [Attribute]
  ) {
    for line in split(separator: "\n") {
      stream.writeIndent()
      stream.writeEscaped(line)
      stream.write("\n")
    }
  }
}

/// Optionals are HTML nodes if their underlying values are HTML nodes. If the
/// wrapped value is `nil`, it renders to nothing.
extension Optional: HTML where Wrapped: HTML {
  public func renderAsHTML(
    into stream: HTMLOutputStream,
    attributes: [Attribute]
  ) {
    if let html = self {
      html.renderAsHTML(into: stream, attributes: attributes)
    }
  }
}

/// MultiNode is an implementation detail for representing multiple sequenced
/// HTML nodes
struct MultiNode: HTML {
  let children: [HTML]
  func renderAsHTML(
    into stream: HTMLOutputStream,
    attributes: [Attribute]
  ) {
    for child in children {
      child.renderAsHTML(into: stream, attributes: attributes)
    }
  }
}

/// Represents an HTML tag like `<div>{{content}}</div>`, with a tag and an
/// optional HTML child.
struct HTMLNode: HTML {
  var tag: String
  var child: HTML?

  func renderAsHTML(
    into stream: HTMLOutputStream,
    attributes: [Attribute]
  ) {

    // Write the opening of the tag, e.g. `<div`
    stream.writeIndent()
    stream.write("<")
    stream.write(tag)

    // Write each attribute, e.g. `class="my-class"`.
    for attr in attributes {
      stream.write(" ")
      stream.write(attr.key)

      // Some attributes do not have values, and instead use the presence of the
      // for its effects, such as `<input disabled>`.
      if let value = attr.value {
        stream.write("=")
        stream.writeDoubleQuoted(value)
      }
    }

    // If this node has no children, end the tag without introducing a second
    // closing tag, e.g. `<br />`.
    guard let child = child else {
      stream.write("/>\n")
      return
    }

    // Otherwise, add a newline and render the child indented.
    stream.write(">\n")
    stream.withIndent {
      // Explicitly do not pass any attributes to children.
      child.renderAsHTML(into: stream, attributes: [])
    }

    // Write the closing tag on its own line.
    stream.writeIndent()
    stream.write("</")
    stream.write(tag)
    stream.write(">\n")
  }
}

// MARK: - Concatenative HTML Attributes

public struct Attribute {
  let key: String
  let value: String?
}

/// Wraps an HTML object with a given attribute. these attributes are collected
/// while walking the node hierarchy and finally printed when printing an
/// `HTMLNode`.
struct AttributedNode: HTML {
  let attribute: Attribute
  let child: HTML

  func renderAsHTML(into stream: HTMLOutputStream, attributes: [Attribute]) {
    var fullAttrs = attributes
    fullAttrs.append(attribute)
    child.renderAsHTML(into: stream, attributes: fullAttrs)
  }
}

/// Iterates over a collection of data and applies a transformation to each
/// piece of data that creates an HTML node.
public func forEach<Coll: Collection>(
  _ data: Coll,
  @HTMLBuilder content: @escaping (Coll.Element) -> HTML
) -> HTML {
  return MultiNode(children: data.map(content))
}

// MARK: - HTMLBuilder

/// A function builder that provides transformations for control flow concepts
/// into HTML components.
@_functionBuilder
public struct HTMLBuilder {
  /// If there are no children in an HTMLBuilder closure, then return an empty
  /// MultiNode.
  public static func buildBlock() -> HTML {
    return MultiNode(children: [])
  }

  /// If there is one child, return it directly.
  public static func buildBlock(_ content: HTML) -> HTML {
    return content
  }

  /// If there are multiple children, return them all as a MultiNode.
  public static func buildBlock(_ content: HTML...) -> HTML {
    return MultiNode(children: content)
  }

  /// If the provided child is `nil`, build an empty MultiNode. Otherwise,
  /// return the wrapped value.
  public static func buildIf(_ content: HTML?) -> HTML {
    if let content = content { return content }
    return MultiNode(children: [])
  }

  /// If the condition of an `if` statement is `true`, then this method will
  /// be called and the result of evaluating the expressions in the `true` block
  /// will be returned unmodified.
  /// - note: We do not need to preserve type information
  ///         from both the `true` and `false` blocks, so this function does
  ///         not wrap its passed value.
  public static func buildEither(first: HTML) -> HTML {
    return first
  }

  /// If the condition of an `if` statement is `false`, then this method will
  /// be called and the result of evaluating the expressions in the `false`
  /// block will be returned unmodified.
  /// - note: We do not need to preserve type information
  ///         from both the `true` and `false` blocks, so this function does
  ///         not wrap its passed value.
  public static func buildEither(second: HTML) -> HTML {
    return second
  }
}

// MARK: - Some HTML shorthand functions

public func div(@HTMLBuilder child: () -> HTML) -> HTML {
  return HTMLNode(tag: "div", child: child())
}

public func head(@HTMLBuilder child: () -> HTML) -> HTML {
  return HTMLNode(tag: "head", child: child())
}

public func body(@HTMLBuilder child: () -> HTML) -> HTML {
  return HTMLNode(tag: "body", child: child())
}

public func html(@HTMLBuilder child: () -> HTML) -> HTML {
  return HTMLNode(tag: "html", child: child())
}

public func title(_ text: String) -> HTML {
  return HTMLNode(tag: "title", child: text)
}

public func br() -> HTML {
  return HTMLNode(tag: "br", child: nil)
}

extension HTML {
  public func attr(_ key: String, _ value: String? = nil) -> HTML {
    return AttributedNode(attribute: Attribute(key: key, value: value),
                          child: self)
  }

  public func `class`(_ value: String) -> HTML {
    return attr("class", value)
  }
}

// MARK: - HTMLOutputStream

/// A helper class for rendering formatted HTML to a given `TextOutputStream`.
public class HTMLOutputStream {
  var output: TextOutputStream

  /// Create an `HTMLOutputStream` that will render `HTML` nodes as HTML text.
  public init(_ output: TextOutputStream) {
    self.output = output
  }
  var indentation: Int = 0
  func withIndent(_ f: () -> Void) {
    indentation += 2
    f()
    indentation -= 2
  }
  func writeIndent() {
    write(String(repeating: " ", count: indentation))
  }
  func line<Str: StringProtocol>(_ line: Str) {
    writeIndent()
    write(line)
    write("\n")
  }
  func write<Str: StringProtocol>(_ text: Str) {
    output.write(String(text))
  }
  func writeDoubleQuoted(_ string: String) {
    write("\"")
    write(string)
    write("\"")
  }
  func writeEscaped<Str: StringProtocol>(_ string: Str) {
    for c in string {
      switch c {
      case "\"": write("&quot;")
      case "&": write("&amp;")
      case "<": write("&lt;")
      case ">": write("&gt;")
      default: write(String(c))
      }
    }
  }

  /// Renders the provided `HTML` node as HTML text to the receiver's stream.
  public func render(_ content: HTML) {
    content.renderAsHTML(into: self, attributes: [])
  }
}

// MARK: - Examples

func simplePage() -> HTML {
  html {
    head {
      title("A simple page!")
    }
    body {
      div {
        "This is the page's body"
      }
    }
  }
}

func pageWithManyElements() -> HTML {
  html {
    head {
      title("A page with a bunch of elements")
    }
    body {
      forEach(0..<10) { i in
        div {
          "This is element number \(i)"

          br()

          if i.isMultiple(of: 2) {
            "It's even!"
          } else {
            "It's odd!"
          }
        }.class("custom-class")
      }
    }
  }
}

extension FileHandle: TextOutputStream {
  public func write(_ string: String) {
    write(Data(string.utf8))
  }
}

var stdout = FileHandle.standardOutput
let stream = HTMLOutputStream(stdout)
stream.render(pageWithManyElements())
