import os
# Package

version       = "0.1.0"
author        = "Jake Leahy"
description   = "Simple ORM for sqlite"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 1.6.0"
requires "https://github.com/PhilippMDoerner/ndb.nim#59043f7"

task checkDocs, "Runs documentation generator to make sure nothing is wrong":
  exec "nimble doc --errorMax:1 --warningAsError:BrokenLink:on --project --outdir:docs src/ponairi.nim"

task test, "Runs all tests":
  # Run the unittest files
  for file in ["All", "Macros"]:
    selfExec "r tests/test" & file
  # Run testament
  exec "nim r tests/errorChecker tests/errors/t*.nim"
