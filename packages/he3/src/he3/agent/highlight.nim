## Streaming-safe syntax highlighting for fenced code and tool output.
##
## One line is tokenized at a time; the only state carried between lines is
## an open block comment or block string, so committed lines never need to
## be reparsed and unknown languages simply stay in the plain code style.

import std/strutils
import ../[style, text]
import theme

type
  HighlightState* = object
    ## Carries an unterminated block comment or string to the next line.
    blockEnd: string
    blockIsString: bool

  TokenKind = enum
    tokPlain
    tokKeyword
    tokLiteral
    tokComment
    tokNumber
    tokType
    tokFunction
    tokOperator
    tokAttribute

  LanguageSpec = object
    lineComments: seq[string]
    blockComments: seq[(string, string)]
    keywords: seq[string]
    quotes: set[char]
    tripleQuotes: bool
    typesCapitalized: bool
    attributePrefix: set[char]
    caseInsensitive: bool

const
  cKeywords = @["auto", "break", "case", "char", "const", "continue",
    "default", "do", "double", "else", "enum", "extern", "float", "for",
    "goto", "if", "inline", "int", "long", "register", "restrict", "return",
    "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
    "union", "unsigned", "void", "volatile", "while", "bool", "true",
    "false", "NULL", "nullptr", "class", "namespace", "template",
    "typename", "public", "private", "protected", "virtual", "override",
    "new", "delete", "this", "using", "constexpr", "noexcept", "try",
    "catch", "throw", "operator", "friend", "explicit", "mutable"]
  jsKeywords = @["async", "await", "break", "case", "catch", "class",
    "const", "continue", "debugger", "default", "delete", "do", "else",
    "enum", "export", "extends", "false", "finally", "for", "function",
    "if", "implements", "import", "in", "instanceof", "interface", "let",
    "new", "null", "of", "package", "private", "protected", "public",
    "return", "static", "super", "switch", "this", "throw", "true", "try",
    "type", "typeof", "undefined", "var", "void", "while", "with", "yield",
    "readonly", "declare", "namespace", "abstract", "as", "from", "keyof",
    "satisfies", "number", "string", "boolean", "any", "unknown", "never"]
  pyKeywords = @["False", "None", "True", "and", "as", "assert", "async",
    "await", "break", "class", "continue", "def", "del", "elif", "else",
    "except", "finally", "for", "from", "global", "if", "import", "in",
    "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return",
    "try", "while", "with", "yield", "match", "case", "self", "print"]
  nimKeywords = @["addr", "and", "as", "asm", "bind", "block", "break",
    "case", "cast", "concept", "const", "continue", "converter", "defer",
    "discard", "distinct", "div", "do", "elif", "else", "end", "enum",
    "except", "export", "finally", "for", "from", "func", "if", "import",
    "in", "include", "interface", "is", "isnot", "iterator", "let",
    "macro", "method", "mixin", "mod", "nil", "not", "notin", "object",
    "of", "or", "out", "proc", "ptr", "raise", "ref", "return", "shl",
    "shr", "static", "template", "try", "tuple", "type", "using", "var",
    "when", "while", "xor", "yield", "true", "false", "result", "echo"]
  goKeywords = @["break", "case", "chan", "const", "continue", "default",
    "defer", "else", "fallthrough", "for", "func", "go", "goto", "if",
    "import", "interface", "map", "package", "range", "return", "select",
    "struct", "switch", "type", "var", "nil", "true", "false", "int",
    "string", "bool", "error", "byte", "rune", "float64", "int64", "uint",
    "make", "new", "len", "cap", "append", "panic", "recover"]
  rustKeywords = @["as", "async", "await", "break", "const", "continue",
    "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
    "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
    "ref", "return", "self", "Self", "static", "struct", "super", "trait",
    "true", "type", "unsafe", "use", "where", "while", "i32", "i64", "u8",
    "u32", "u64", "usize", "isize", "f32", "f64", "bool", "str", "String",
    "Vec", "Option", "Result", "Some", "None", "Ok", "Err", "Box"]
  javaKeywords = @["abstract", "assert", "boolean", "break", "byte", "case",
    "catch", "char", "class", "const", "continue", "default", "do",
    "double", "else", "enum", "extends", "final", "finally", "float",
    "for", "if", "implements", "import", "instanceof", "int", "interface",
    "long", "native", "new", "package", "private", "protected", "public",
    "return", "short", "static", "super", "switch", "synchronized", "this",
    "throw", "throws", "transient", "try", "void", "volatile", "while",
    "true", "false", "null", "var", "record", "sealed", "fun", "val",
    "when", "object", "data", "override", "suspend", "lateinit"]
  swiftKeywords = @["associatedtype", "class", "deinit", "enum",
    "extension", "fileprivate", "func", "import", "init", "inout",
    "internal", "let", "operator", "private", "protocol", "public",
    "static", "struct", "subscript", "typealias", "var", "break", "case",
    "continue", "default", "defer", "do", "else", "fallthrough", "for",
    "guard", "if", "in", "repeat", "return", "switch", "where", "while",
    "as", "catch", "false", "is", "nil", "rethrows", "self", "Self",
    "super", "throw", "throws", "true", "try", "async", "await", "some",
    "any", "actor"]
  rubyKeywords = @["alias", "and", "begin", "break", "case", "class",
    "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
    "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
    "rescue", "retry", "return", "self", "super", "then", "true", "undef",
    "unless", "until", "when", "while", "yield", "require", "attr_reader",
    "attr_accessor", "puts", "lambda", "proc"]
  shellKeywords = @["if", "then", "else", "elif", "fi", "for", "while",
    "until", "do", "done", "case", "esac", "in", "function", "return",
    "exit", "export", "local", "readonly", "declare", "set", "unset",
    "shift", "source", "alias", "echo", "cd", "test", "true", "false",
    "select", "time", "trap", "eval", "exec"]
  sqlKeywords = @["select", "from", "where", "insert", "into", "values",
    "update", "set", "delete", "create", "table", "drop", "alter", "add",
    "column", "primary", "key", "foreign", "references", "index", "unique",
    "not", "null", "default", "and", "or", "in", "is", "like", "between",
    "join", "inner", "left", "right", "outer", "full", "on", "as", "order",
    "by", "group", "having", "limit", "offset", "union", "all", "distinct",
    "count", "sum", "avg", "min", "max", "case", "when", "then", "else",
    "end", "exists", "begin", "commit", "rollback", "transaction", "with",
    "returning", "integer", "text", "varchar", "boolean", "timestamp",
    "true", "false", "view", "if", "cascade", "constraint", "check"]
  luaKeywords = @["and", "break", "do", "else", "elseif", "end", "false",
    "for", "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while", "self"]
  zigKeywords = @["const", "var", "fn", "pub", "struct", "enum", "union",
    "return", "if", "else", "while", "for", "switch", "break", "continue",
    "defer", "errdefer", "try", "catch", "unreachable", "comptime",
    "inline", "export", "extern", "packed", "align", "and", "or",
    "orelse", "null", "undefined", "true", "false", "test", "usingnamespace",
    "u8", "u32", "u64", "i32", "i64", "usize", "isize", "f32", "f64",
    "bool", "void", "anytype", "type", "error"]
  haskellKeywords = @["case", "class", "data", "default", "deriving", "do",
    "else", "foreign", "if", "import", "in", "infix", "infixl", "infixr",
    "instance", "let", "module", "newtype", "of", "then", "type", "where",
    "forall", "qualified", "as", "hiding"]
  elixirKeywords = @["def", "defp", "defmodule", "defmacro", "defstruct",
    "do", "end", "if", "else", "unless", "case", "cond", "fn", "when",
    "with", "receive", "after", "raise", "rescue", "try", "catch", "true",
    "false", "nil", "and", "or", "not", "in", "import", "alias", "use",
    "require", "quote", "unquote", "for", "into"]
  cssKeywords = @["important", "px", "em", "rem", "vh", "vw", "auto",
    "none", "inherit", "initial", "flex", "grid", "block", "inline",
    "absolute", "relative", "fixed", "sticky", "solid", "bold", "center",
    "hidden", "visible", "transparent", "media", "import", "keyframes"]
  yamlKeywords = @["true", "false", "null", "yes", "no", "on", "off"]
  makeKeywords = @["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif",
    "include", "define", "endef", "export", "unexport", "override",
    "PHONY", "SHELL", "MAKE", "CC", "CFLAGS", "LDFLAGS"]
  dockerKeywords = @["FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD",
    "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD",
    "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS"]
  operatorChars = {'+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|',
    '^', '~', '?', ':', ';', ',', '.', '(', ')', '[', ']', '{', '}'}

func spec(language: string): LanguageSpec =
  ## Returns the tokenizer rules for a fence language label.
  let lang = language.toLowerAscii
  case lang
  of "nim", "nims":
    LanguageSpec(lineComments: @["#"], blockComments: @[("#[", "]#")],
      keywords: nimKeywords, quotes: {'"', '\''}, tripleQuotes: true,
      typesCapitalized: true, attributePrefix: {})
  of "python", "py":
    LanguageSpec(lineComments: @["#"], keywords: pyKeywords,
      quotes: {'"', '\''}, tripleQuotes: true, typesCapitalized: true,
      attributePrefix: {'@'})
  of "javascript", "js", "jsx", "typescript", "ts", "tsx", "mjs", "cjs":
    LanguageSpec(lineComments: @["//"], blockComments: @[("/*", "*/")],
      keywords: jsKeywords, quotes: {'"', '\'', '`'}, typesCapitalized: true,
      attributePrefix: {'@'})
  of "go", "golang":
    LanguageSpec(lineComments: @["//"], blockComments: @[("/*", "*/")],
      keywords: goKeywords, quotes: {'"', '\'', '`'}, typesCapitalized: true)
  of "rust", "rs":
    LanguageSpec(lineComments: @["//"], blockComments: @[("/*", "*/")],
      keywords: rustKeywords, quotes: {'"'}, typesCapitalized: true,
      attributePrefix: {'#'})
  of "c", "h", "cpp", "cc", "cxx", "hpp", "c++", "objc", "cs", "csharp":
    LanguageSpec(lineComments: @["//"], blockComments: @[("/*", "*/")],
      keywords: cKeywords, quotes: {'"', '\''}, typesCapitalized: true,
      attributePrefix: {'#'})
  of "java", "kotlin", "kt", "scala", "dart", "groovy":
    LanguageSpec(lineComments: @["//"], blockComments: @[("/*", "*/")],
      keywords: javaKeywords, quotes: {'"', '\''}, typesCapitalized: true,
      attributePrefix: {'@'})
  of "swift":
    LanguageSpec(lineComments: @["//"], blockComments: @[("/*", "*/")],
      keywords: swiftKeywords, quotes: {'"'}, typesCapitalized: true,
      attributePrefix: {'@'})
  of "ruby", "rb":
    LanguageSpec(lineComments: @["#"], keywords: rubyKeywords,
      quotes: {'"', '\''}, typesCapitalized: true, attributePrefix: {'@'})
  of "sh", "bash", "zsh", "shell", "fish", "console":
    LanguageSpec(lineComments: @["#"], keywords: shellKeywords,
      quotes: {'"', '\''}, attributePrefix: {'$'})
  of "sql", "postgresql", "postgres", "mysql", "sqlite":
    LanguageSpec(lineComments: @["--"], blockComments: @[("/*", "*/")],
      keywords: sqlKeywords, quotes: {'\'', '"'}, caseInsensitive: true)
  of "lua":
    LanguageSpec(lineComments: @["--"], blockComments: @[("--[[", "]]")],
      keywords: luaKeywords, quotes: {'"', '\''})
  of "zig":
    LanguageSpec(lineComments: @["//"], keywords: zigKeywords,
      quotes: {'"', '\''}, typesCapitalized: true, attributePrefix: {'@'})
  of "haskell", "hs", "elm", "purescript":
    LanguageSpec(lineComments: @["--"], blockComments: @[("{-", "-}")],
      keywords: haskellKeywords, quotes: {'"', '\''}, typesCapitalized: true)
  of "elixir", "ex", "exs", "erlang":
    LanguageSpec(lineComments: @["#"], keywords: elixirKeywords,
      quotes: {'"', '\''}, tripleQuotes: true, typesCapitalized: true,
      attributePrefix: {'@'})
  of "css", "scss", "less":
    LanguageSpec(blockComments: @[("/*", "*/")], lineComments: @["//"],
      keywords: cssKeywords, quotes: {'"', '\''}, attributePrefix: {'@', '#'})
  of "json", "jsonc", "json5":
    LanguageSpec(lineComments: @["//"], keywords: @["true", "false", "null"],
      quotes: {'"'})
  of "yaml", "yml":
    LanguageSpec(lineComments: @["#"], keywords: yamlKeywords,
      quotes: {'"', '\''}, attributePrefix: {'&', '*'})
  of "toml", "ini", "cfg", "conf", "properties":
    LanguageSpec(lineComments: @["#", ";"], keywords: @["true", "false"],
      quotes: {'"', '\''}, tripleQuotes: true)
  of "html", "xml", "svg", "vue", "svelte":
    LanguageSpec(blockComments: @[("<!--", "-->")], quotes: {'"', '\''},
      keywords: @["html", "head", "body", "div", "span", "script", "style",
        "link", "meta", "title", "a", "p", "ul", "li", "img", "table", "tr",
        "td", "th", "form", "input", "button", "section", "header", "footer",
        "nav", "main", "h1", "h2", "h3", "template", "slot"],
      attributePrefix: {'<', '/', '>'})
  of "makefile", "make", "mk":
    LanguageSpec(lineComments: @["#"], keywords: makeKeywords,
      quotes: {'"', '\''}, attributePrefix: {'$'})
  of "dockerfile", "docker":
    LanguageSpec(lineComments: @["#"], keywords: dockerKeywords,
      quotes: {'"', '\''}, attributePrefix: {'$'})
  of "r", "julia", "jl", "matlab", "octave":
    LanguageSpec(lineComments: @["#", "%"], keywords: @["function", "if",
      "else", "elseif", "end", "for", "while", "return", "true", "false",
      "NULL", "NA", "in", "break", "continue", "struct", "mutable", "using",
      "import", "export", "const", "let", "begin", "do", "try", "catch",
      "finally", "module", "macro", "quote", "nothing", "missing"],
      quotes: {'"', '\''}, typesCapitalized: true, attributePrefix: {'@'})
  of "php":
    LanguageSpec(lineComments: @["//", "#"], blockComments: @[("/*", "*/")],
      keywords: jsKeywords & @["echo", "function", "fn", "match",
        "foreach", "endforeach", "use", "namespace", "array", "isset",
        "unset", "require", "include", "elseif", "endif", "final"],
      quotes: {'"', '\''}, typesCapitalized: true, attributePrefix: {'$', '#'})
  else:
    LanguageSpec()

func knownLanguage*(language: string): bool =
  ## True when the label selects highlighting rules; other labels render in
  ## the plain code style.
  let rules = spec(language)
  rules.keywords.len > 0 or rules.lineComments.len > 0 or
    rules.blockComments.len > 0

func tokenStyle(kind: TokenKind, base: Style, colors: AgentTheme): Style =
  case kind
  of tokPlain: base
  of tokKeyword: colors.syntax.keyword
  of tokLiteral: colors.syntax.literal
  of tokComment: colors.syntax.comment
  of tokNumber: colors.syntax.number
  of tokType: colors.syntax.typeName
  of tokFunction: colors.syntax.function
  of tokOperator: colors.syntax.operator
  of tokAttribute: colors.syntax.attribute

proc emit(line: var Line, text: string, kind: TokenKind, base: Style,
    colors: AgentTheme) =
  if text.len == 0:
    return
  let style = tokenStyle(kind, base, colors)
  if line.spans.len > 0 and line.spans[^1].style == style:
    line.spans[^1].text.add text
  else:
    line.spans.add Span(text: text, style: style)

func startsAt(value: string, at: int, prefix: string): bool =
  if prefix.len == 0 or at + prefix.len > value.len:
    return false
  for index in 0 ..< prefix.len:
    if value[at + index] != prefix[index]:
      return false
  true

func isIdentStart(ch: char): bool =
  ch in {'a' .. 'z', 'A' .. 'Z', '_'} or ord(ch) >= 0x80

func isIdentChar(ch: char): bool =
  ch.isIdentStart or ch in {'0' .. '9'}

func nextNonSpace(value: string, at: int): char =
  var index = at
  while index < value.len and value[index] in {' ', '\t'}:
    inc index
  if index < value.len: value[index] else: '\0'

proc highlightLine*(line, language: string, state: var HighlightState,
    colors: AgentTheme, base = agentTheme().base.code): Line =
  ## Tokenizes one already-sanitized source line into styled spans. `state`
  ## carries an open block comment or string from previous lines.
  let rules = spec(language)
  if rules.keywords.len == 0 and rules.lineComments.len == 0 and
      rules.blockComments.len == 0:
    result.spans.add Span(text: line, style: base)
    return
  var index = 0
  if state.blockEnd.len > 0:
    let close = line.find(state.blockEnd)
    let kind = if state.blockIsString: tokLiteral else: tokComment
    if close < 0:
      result.emit(line, kind, base, colors)
      return
    index = close + state.blockEnd.len
    result.emit(line[0 ..< index], kind, base, colors)
    state.blockEnd.setLen 0
  var plainStart = index
  template flushPlain(until: int) =
    if until > plainStart:
      result.emit(line[plainStart ..< until], tokPlain, base, colors)
  while index < line.len:
    let ch = line[index]
    var matched = false
    for marker in rules.lineComments:
      if line.startsAt(index, marker):
        if marker == "#" and index + 1 < line.len and line[index + 1] == '[' and
            rules.blockComments.len > 0:
          break
        flushPlain(index)
        result.emit(line[index ..< line.len], tokComment, base, colors)
        return
    for pair in rules.blockComments:
      if line.startsAt(index, pair[0]):
        flushPlain(index)
        let close = line.find(pair[1], index + pair[0].len)
        if close < 0:
          result.emit(line[index ..< line.len], tokComment, base, colors)
          state.blockEnd = pair[1]
          state.blockIsString = false
          return
        let stop = close + pair[1].len
        result.emit(line[index ..< stop], tokComment, base, colors)
        index = stop
        plainStart = index
        matched = true
        break
    if matched:
      continue
    if ch in rules.quotes:
      flushPlain(index)
      let triple = rules.tripleQuotes and index + 2 < line.len and
        line[index + 1] == ch and line[index + 2] == ch
      let start = index
      if triple:
        let close = line.find(repeat(ch, 3), index + 3)
        if close < 0:
          result.emit(line[start ..< line.len], tokLiteral, base, colors)
          state.blockEnd = repeat(ch, 3)
          state.blockIsString = true
          return
        index = close + 3
      else:
        inc index
        while index < line.len and line[index] != ch:
          if line[index] == '\\' and index + 1 < line.len:
            inc index
          inc index
        index = min(line.len, index + 1)
      result.emit(line[start ..< index], tokLiteral, base, colors)
      plainStart = index
      continue
    if ch in {'0' .. '9'} or (ch == '.' and index + 1 < line.len and
        line[index + 1] in {'0' .. '9'} and
        (index == 0 or not line[index - 1].isIdentChar)):
      if index > 0 and line[index - 1].isIdentChar:
        inc index
        continue
      flushPlain(index)
      let start = index
      inc index
      while index < line.len and (line[index].isIdentChar or
          line[index] == '.' or (line[index] in {'+', '-'} and
          line[index - 1] in {'e', 'E'} and
          not line[start ..< index].startsWith("0x"))):
        inc index
      result.emit(line[start ..< index], tokNumber, base, colors)
      plainStart = index
      continue
    if ch.isIdentStart:
      let start = index
      inc index
      while index < line.len and (line[index].isIdentChar or
          (line[index] in {'?', '!'} and rules.keywords == rubyKeywords)):
        inc index
      let word = line[start ..< index]
      let key = if rules.caseInsensitive: word.toLowerAscii else: word
      var kind = tokPlain
      if key in rules.keywords:
        kind = tokKeyword
      elif start > 0 and line[start - 1] in rules.attributePrefix and
          line[start - 1] != '<' and line[start - 1] != '>':
        kind = tokAttribute
      elif line.nextNonSpace(index) == '(' or (index + 1 < line.len and
          line[index] == '*' and line[index + 1] == '(' and
          rules.keywords == nimKeywords):
        kind = tokFunction
      elif rules.typesCapitalized and word[0] in {'A' .. 'Z'} and
          word.len > 1 and word != word.toUpperAscii:
        kind = tokType
      if kind != tokPlain:
        flushPlain(start)
        result.emit(word, kind, base, colors)
        plainStart = index
      continue
    if ch in rules.attributePrefix and ch in {'@', '#', '$', '&', '*'} and
        index + 1 < line.len and line[index + 1].isIdentStart:
      flushPlain(index)
      let start = index
      inc index
      while index < line.len and line[index].isIdentChar:
        inc index
      result.emit(line[start ..< index], tokAttribute, base, colors)
      plainStart = index
      continue
    if ch in operatorChars:
      flushPlain(index)
      let start = index
      while index < line.len and line[index] in operatorChars:
        inc index
      result.emit(line[start ..< index], tokOperator, base, colors)
      plainStart = index
      continue
    inc index
  flushPlain(line.len)
