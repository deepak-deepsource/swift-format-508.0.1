//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftFormatCore
import SwiftSyntax

/// Each variable declaration, with the exception of tuple destructuring, should
/// declare 1 variable.
///
/// Lint: If a variable declaration declares multiple variables, a lint error is
/// raised.
///
/// Format: If a variable declaration declares multiple variables, it will be
/// split into multiple declarations, each declaring one of the variables, as
/// long as the result would still be syntactically valid.
public final class OneVariableDeclarationPerLine: SyntaxFormatRule {
  public override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
    guard node.contains(where: codeBlockItemHasMultipleVariableBindings) else {
      return super.visit(node)
    }

    var newItems = [CodeBlockItemSyntax]()
    for codeBlockItem in node {
      guard let varDecl = codeBlockItem.item.as(VariableDeclSyntax.self),
        varDecl.bindings.count > 1
      else {
        // It's not a variable declaration with multiple bindings, so visit it
        // recursively (in case it's something that contains bindings that need
        // to be split) but otherwise do nothing.
        let newItem = super.visit(codeBlockItem)
        newItems.append(newItem)
        continue
      }

      diagnose(.onlyOneVariableDeclaration, on: varDecl)

      // Visit the decl recursively to make sure nested code block items in the
      // bindings (for example, an initializer expression that contains a
      // closure expression) are transformed first before we rewrite the decl
      // itself.
      let visitedDecl = super.visit(varDecl).as(VariableDeclSyntax.self)!
      var splitter = VariableDeclSplitter {
        CodeBlockItemSyntax(
          item: .decl(DeclSyntax($0)),
          semicolon: nil,
          errorTokens: nil)
      }
      newItems.append(contentsOf: splitter.nodes(bySplitting: visitedDecl))
    }

    return CodeBlockItemListSyntax(newItems)
  }

  /// Returns true if the given `CodeBlockItemSyntax` contains a `let` or `var`
  /// declaration with multiple bindings.
  private func codeBlockItemHasMultipleVariableBindings(
    _ node: CodeBlockItemSyntax
  ) -> Bool {
    if let varDecl = node.item.as(VariableDeclSyntax.self),
      varDecl.bindings.count > 1
    {
      return true
    }
    return false
  }
}

extension Finding.Message {
  public static let onlyOneVariableDeclaration: Finding.Message =
    "split this variable declaration to have one variable per declaration"
}

/// Splits a variable declaration with multiple bindings into individual
/// declarations.
///
/// Swift's grammar allows each identifier in a variable declaration to have a
/// type annotation, an initializer expression, both, or neither. Stricter
/// checks occur after parsing, however; a lone identifier may only be followed
/// by zero or more other lone identifiers and then an identifier with *only* a
/// type annotation (and the type annotation is applied to all of them). If we
/// have something else, we should handle them gracefully (i.e., not destroy
/// them) but we don't need to try to fix them since they didn't compile in the
/// first place so we can't guess what the user intended.
///
/// So, this algorithm works by scanning forward and collecting lone identifiers
/// in a queue until we reach a binding that has an initializer or a type
/// annotation. If we see a type annotation (without an initializer), we can
/// create individual variable declarations for each entry in the queue by
/// projecting that type annotation onto each of them. If we reach a case that
/// isn't valid, we just flush the queue contents as a single declaration, to
/// effectively preserve what the user originally had.
private struct VariableDeclSplitter<Node: SyntaxProtocol> {
  /// A function that takes a `VariableDeclSyntax` and returns a new node, such
  /// as a `CodeBlockItemSyntax`, that wraps it.
  private let generator: (VariableDeclSyntax) -> Node

  /// Bindings that have been collected so far.
  private var bindingQueue = [PatternBindingSyntax]()

  /// The variable declaration being split.
  ///
  /// This is an implicitly-unwrapped optional because it isn't initialized
  /// until `nodes(bySplitting:)` is called.
  private var varDecl: VariableDeclSyntax!

  /// The list of nodes generated by splitting the variable declaration into
  /// individual bindings.
  private var nodes = [Node]()

  /// Tracks whether the trivia of `varDecl` has already been fixed up for nodes
  /// after the first.
  private var fixedUpTrivia = false

  /// Creates a new variable declaration splitter.
  ///
  /// - Parameter generator: A function that takes a `VariableDeclSyntax` and
  ///   returns a new node, such as a `CodeBlockItemSyntax`, that wraps it.
  init(generator: @escaping (VariableDeclSyntax) -> Node) {
    self.generator = generator
  }

  /// Returns an array of nodes generated by splitting the given variable
  /// declaration into individual bindings.
  mutating func nodes(bySplitting varDecl: VariableDeclSyntax) -> [Node] {
    self.varDecl = varDecl
    self.nodes = []

    for binding in varDecl.bindings {
      if binding.initializer != nil {
        // If this is the only initializer in the queue so far, that's ok. If
        // it's an initializer following other un-flushed lone identifier
        // bindings, that's not valid Swift. But in either case, we'll flush
        // them as a single decl.
        bindingQueue.append(binding.withTrailingComma(nil))
        flushRemaining()
      } else if let typeAnnotation = binding.typeAnnotation {
        bindingQueue.append(binding)
        flushIndividually(typeAnnotation: typeAnnotation)
      } else {
        bindingQueue.append(binding)
      }
    }
    flushRemaining()

    return nodes
  }

  /// Replaces the original variable declaration with a copy of itself with
  /// updates trivia appropriate for subsequent declarations inserted by the
  /// rule.
  private mutating func fixOriginalVarDeclTrivia() {
    guard !fixedUpTrivia else { return }

    // We intentionally don't try to infer the indentation for subsequent
    // lines because the pretty printer will re-indent them correctly; we just
    // need to ensure that a newline is inserted before new decls.
    varDecl = replaceTrivia(
      on: varDecl, token: varDecl.firstToken, leadingTrivia: .newlines(1))
    fixedUpTrivia = true
  }

  /// Flushes any remaining bindings as a single variable declaration.
  private mutating func flushRemaining() {
    guard !bindingQueue.isEmpty else { return }

    let newDecl =
      varDecl.withBindings(PatternBindingListSyntax(bindingQueue))
    nodes.append(generator(newDecl))

    fixOriginalVarDeclTrivia()

    bindingQueue = []
  }

  /// Flushes any remaining bindings as individual variable declarations where
  /// each has the given type annotation.
  private mutating func flushIndividually(
    typeAnnotation: TypeAnnotationSyntax
  ) {
    assert(!bindingQueue.isEmpty)

    for binding in bindingQueue {
      assert(binding.initializer == nil)

      let newBinding =
        binding.withTrailingComma(nil).withTypeAnnotation(typeAnnotation)
      let newDecl =
        varDecl.withBindings(PatternBindingListSyntax([newBinding]))
      nodes.append(generator(newDecl))

      fixOriginalVarDeclTrivia()
    }

    bindingQueue = []
  }
}

