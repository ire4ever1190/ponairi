import std/[
  strformat,
  macros,
  strutils
]

func seperateBy*[T](items: openArray[T], sep: string,
                   handler: proc (x: T): string): string {.effectsOf: handler.} =
  ## Runs `handler` on every `item` and seperates all the items.
  ## Doesn't add seperator to the end though
  for i in 0..<items.len:
    result &= handler(items[i])
    if i < items.len - 1:
      result &= sep

template currentLine*(): LineInfo =
  ## Returns the current line as a LineInfo
  const (filename, line, column) = instantiationInfo(-2, fullPaths = true)
  LineInfo(filename: filename, line: line, column: column)

template findIt*(s, pred: untyped): int =
  ## Like `find` except you can pass a custom checker
  var result = 0
  for it {.inject.} in s:
    if pred:
      break
    inc result
  # Retain semantics that -1 means it couldn't find it
  if result == s.len:
    result = -1
  result

func doesntExistErr*(field, table: string): string =
  ## Returns formatted error for when a field doesn't exist
  fmt"{field} doesn't exist in {table}"

func escapeQuoteSQL*(x: string): string =
  ## Escapes quotes (') in a string so that SQLite will treat them as a character
  runnableExamples:
    assert "Hello 'world'".escapeQuoteSQL() == "Hello ''world''"
  #==#
  x.replace("'", "''")

