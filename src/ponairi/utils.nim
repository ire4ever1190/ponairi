func seperateBy*[T](items: openArray[T], sep: string,
                   handler: proc (x: T): string): string {.effectsOf: handler.} =
  ## Runs `handler` on every `item` and seperates all the items.
  ## Doesn't add seperator to the end though
  for i in 0..<items.len:
    result &= handler(items[i])
    if i < items.len - 1:
      result &= sep
