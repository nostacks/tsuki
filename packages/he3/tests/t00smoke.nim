import common
import he3/private/writer

proc main =
  var t = initFakeTty()
  var o = t.wr
  o.write cast[seq[byte]]("hello")
  doAssert t.bytes == cast[seq[byte]]("hello")
  echo "smoke ok"

main()
