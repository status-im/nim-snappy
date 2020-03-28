import 
  unittest, os,
  ../snappy/framing
  
proc main() =
  suite "framing":
    test "uncompress":
      check true
      
main()
