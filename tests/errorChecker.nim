##[
  Simple program to run a file and check errors are in the right file/column/line.
  This uses similar syntax to testament for specifying errors (Except no need for the tt. prefix).
  ```nim
  discard true == 9 #[Error
               ^ type mistmatch]#
  ```
  This was built since testament had some issues when trying to check multiple errors (the template/generic instatiation broke it).
  I didn't know enough about testament to write a PR, and I think it might be intended behaviour
]##

import std/[
  os,
  strutils,
  strformat,
  osproc,
  tables,
  strscans,
  sets,
  macros,
  sugar,
  terminal
]

import ponairi/utils

type
  TestKind = enum # TODO: Support warnings and hints
    Error

  Test = object
    kind: TestKind
    message: string
    file: string
    line, column: int

  ResultKind = enum
    Passed
    LineWrong
    ColumnWrong
    MessageWrong
    FileWrong
    NotFound

  TestResult = object
    test: Test
    case result: ResultKind
    of Passed, NotFound: discard
    of FileWrong:
      loc: LineInfo
    of LineWrong:
      line: int
    of ColumnWrong:
      column: int
    of MessageWrong:
      message: string

proc parseTests(file: string): seq[Test] =
  ## Parses all the tests in a file. Uses similar syntax to testament
  runnableExamples:
    # We drop the tt. prefix
    # Rest is the same
    discard someProc(9 + true) #[Error
                       ^ type mismatch]#
  #==#
  var
    findCarat = false # In finding carat state
    test: Test
    lineNum = 1# Current line in file
  for line in file.lines:
    if findCarat:
      # Find the carlineat that specifies where the column is and then add the test
      let column = line.find("^")
      if column == -1:
        raise (ref CatchableError)(msg: fmt"Couldn't find carat for {file.extractFileName()}:{lineNum}")
      test.message = line[column + 1 .. ^3].strip() # Remove the ]# from the end
      test.column = column + 1
      result &= test
      findCarat = false
    elif line.endsWith("#[Error"):
      findCarat = true
      test.file = file
      test.line = lineNum
      test.kind = Error
    lineNum += 1

iterator parseErrors(process: Process): Test =
  ## Returns all the errors from the output
  for line in process.lines:
    var test: Test
    if line.scanf("$+($i, $i) Error: $+$.", test.file, test.line, test.column, test.message):
      yield test

var files: seq[string]
# Build list of files that we will parse.
# We allow the use of patterns
for pattern in commandLineParams():
  for file in walkFiles(pattern):
    files &= file

var results = newSeq[seq[TestResult]](files.len)

proc handleFile(idx: int, process: Process) =
  ## Handles testing the output of a check. Puts the result in `results`
  var tests = files[idx].parseTests()
  for error in process.parseErrors:
    # Try and find the error first by message. Then try line/file if we can't find it.
    # This is done since sometimes the message might be there but be in the wrong file
    var i = tests.findIt(it.message == error.message)
    if i == -1:
      i = tests.findIt(it.file == error.file and it.line == error.line)
    # We found it, check it all lines up
    if i != -1:
      var res: TestResult
      let test = tests[i]
      if not test.file.sameFile(error.file):
        res = TestResult(result: FileWrong, loc: LineInfo(filename: error.file, line: error.line, column: error.column))
      elif test.line != error.line:
        res = TestResult(result: LineWrong, line: error.line)
      elif test.column != error.column:
        res = TestResult(result: ColumnWrong, column: error.column)
      elif test.message != error.message:
        res = TestResult(result: MessageWrong, message: error.message)
      else:
        res = TestResult(result: Passed)
      res.test = test
      results[idx] &= res
      tests.del(i) # Ignore the test after this
  # Any left over tests will fail since the error wasn't found
  results[idx].add collect do:
    for test in tests:
      TestResult(test: test, result: NotFound)

# Run the checks in parallel. We collect the results and output them after
let commands = collect:
  for file in files:
    fmt"nim check '{file}'"

discard execProcesses(commands, options = {poStdErrToStdOut, poUsePath}, afterRunEvent = handleFile)

var
  passed = 0
  total = 0

for i in 0..<results.len:
  let file = files[i]
  stdout.styledWriteLine(fgBlue, file, resetStyle)
  for result in results[i]:
    let test = result.test
    stdout.write("  " & result.test.message & ": ")
    total += 1
    case result.result
    of Passed:
      stdout.styledWriteLine(fgGreen, "Passed", resetStyle)
      passed += 1
    of LineWrong:
      stdout.styledWriteLine(fgRed, fmt"Expected line {test.line} but got {result.line}", resetStyle)
    of ColumnWrong:
      stdout.styledWriteLine(fgRed, fmt"Expected column {test.column} but got {result.column}", resetStyle)
    of FileWrong:
      stdout.styledWriteLine(fgRed, fmt"Expected error at {test.file}:({test.line}, {test.column}) but got {result.loc}", resetStyle)
    of MessageWrong:
      stdout.styledWriteLine(fgRed, fmt"Got '{result.message}'", resetStyle)
    of NotFound:
      stdout.styledWriteLine(fgRed, "Not found", resetStyle)

echo fmt"{passed}/{total} passed"

quit(if passed == total: QuitSuccess else: QuitFailure)
