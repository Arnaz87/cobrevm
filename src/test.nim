

import machine


import parse
import compile

import metadata

import unittest
import macros
import options

import aurolib

from strutils import multiReplace

# JS Compatibility
proc `$` (x: uint8): string = $int(x)

# Posible ejemplo para structs:
# http://rosettacode.org/wiki/Tree_traversal#C

## Macro to create binary data. Accepts a list of expressions.
## 
## - An integer literal gets converted into a single byte, no matter the size.
## - An integer literal prepended with $ formats the value as a varint
## - A string literal gets converted into it's sequence of bytes.
## - A string literal prepended with $ is the string prepended with it's size as a varint
## - Any other expression gets converted into it's result as a single byte.

macro bin* (xs: varargs[untyped]): untyped =
  var items = newNimNode(nnkBracket)

  for x in xs:

    proc addByte (n: BiggestInt) =
      var node = newNimNode(nnkUInt8Lit, x)
      node.intVal = n
      items.add(node)

    proc addStr (str: string) =
      for i in 0..str.high:
        addByte( BiggestInt(str[i]) )

    proc addInt (n: BiggestInt) =
      proc helper (n: BiggestInt) =
        if n > 0:
          helper(n shr 7)
          addByte(n and 0x7f or 0x80)
      helper(n shr 7)
      addByte(n and 0x7f)

    proc otherwise = items.add(newCall(newIdentNode("uint8"), x))

    case x.kind
    of nnkCharLit..nnkUInt64Lit:
      addByte(x.intVal)
    of nnkStrLit:
      addStr(x.strVal)
    of nnkPrefix:
      if x[0].eqIdent("$"):
        case x[1].kind
        of nnkCharLit..nnkUInt64Lit:
          addInt( x[1].intVal )
        of nnkStrLit:
          addInt( x[1].strVal.len )
          addStr( x[1].strVal.multiReplace({".": "\x1f", ":": "\x1d"}))
        else: otherwise()
      else: otherwise()
    else: otherwise()

  return if items.len > 0: prefix(items, "@")
    else: parseExpr("newSeq[uint8](0)")

suite "binary":
  test "basics":
    check bin() == newSeq[uint8](0)
    check bin(0) == @[0u8]
    check bin(1) == @[1u8]
    check bin(127, 128, 129) == @[127u8, 128u8, 129u8]
    check bin('A', 'B', 32) == @[65u8, 66u8, 32u8]
    check bin(2+3) == bin(5)
  test "ints":
    check bin($127) == bin(127)
    check bin($128) == bin(0x81, 0)
    check bin($129) == bin(0x81, 1)
    check bin($0x0808) == bin(0x90, 0x08)
  test "strings":
    check bin("") == bin()
    check bin($"") == bin(0)
    check bin(7, "ab") == bin(7, 'a', 'b')
    check bin($"abcde") == bin(5, "abcde")
    check bin($"a.b:c") == bin(5, "a\x1fb\x1dc")

proc get_function (m: machine.Module, name: string): machine.Function =
  let item = m[name]
  if item.kind != machine.fItem: raise newException(Exception, "Function " & name & "not found in module" & m.name)
  return item.f

suite "Full Tests":

  test "Simple add":
    #[ Features
      type/function import
      function definition
      function call
      static ints
    ]#
    let code = bin(
      "Auro 0.6", 0,
      2, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          2, 1, $"myadd",
        1, $"auro.int", #2 Import
      1, # Types
        (2+1), $"int", #0 import "int" from module 2
      2, # Functions
        (2+2), #0 from module 2
          2, 0, 0, # 2 inputs: int int
          1, 0, # 1 outputs: int
          $"add",
        1, #1 Defined Function (myadd)
          0, # 0 inputs
          1, 0, # 1 outputs: int
      2, # Constants
        1, $4, #2 int 4
        1, $5, #3 int 5
      4, # Block for #1 (myadd)
        (16 + 2), #0 = const 4
        (16 + 3), #1 = const 5
        (16 + 0), 0, 1, #2 = add(#0, #1)
        0, 2, #return #2
      0, # No metadata
    )

    let parsed = parseData(code)
    let compiled = compile(parsed, "Simple add")
    let function = compiled.get_function("myadd")

    let result = function.run(@[])
    check(result == @[Value(kind: intV, i: 9)])

  test "Factorial":
    #[ Features
      recursive function call
    ]#
    let data = bin(
      "Auro 0.6", 0,
      3,
        #0 is the argument module
        2, 1, #1 Define (exports)
          2, 1, $"factorial",
        1, $"auro.int", #2 Import auro.int
        1, $"auro.bool", #3 import auro.bool
      2, # Types
        (2+1), $"int",
        (3+1), $"bool",
      5, # Functions
        (2+2), #0 import module[0].add
          2, 0, 0, # 2 ins: int int
          1, 0, # 1 outs: int
          $"add",
        1, #1 Defined Function (factorial)
          1, 0, # 1 ins: int
          1, 0, # 1 outs: int
        (2+2), #2
          2, 0, 0, # 2 ins: int int
          1, 1, # 1 outs: bool
          $"gt",
        (2+2), #3
          1, 0, 1, 0,
          $"dec",
        (2+2), #4
          2, 0, 0, 1, 0,
          $"mul",
      2, # Constants
        1, $0, #5 int 0
        1, $1, #6 int 1
      9, # Block for #1
        #0 = ins[0]
        (16 + 5), #1 = const_5 (0)
        (16 + 6), #2 = const_6 (1)
        (16 + 2), 0, 1, #3 = gt(#0, #1)
        6, 5, 3, # goto 5 if #3
        0, 2, # return #2 (1)
        (16 + 3), 0, #4 = dec(#0)
        (16 + 1), 4, #5 = factorial(#4)
        (16 + 4), 0, 5, #6 = #0 * #5
        0, 6, # return #6
      0, # No metadata
    )

    let parsed = parseData(data)
    let compiled = compile(parsed, "Factorial")
    let function = compiled.get_function("factorial")
    let result = function.run(@[Value(kind: intV, i: 5)])
    check(result == @[Value(kind: intV, i: 120)])

  test "Constant Call":
    #[ Features
      constant function calls
    ]#
    let code = bin(
      "Auro 0.6", 0,
      2, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          2, 1, $"main",
        1, $"auro.int", #2 Import
      1, # Types
        (2+1), $"int", #0 import "int" from module 2
      2, # Functions
        (2+2), #0 from module 2
          1, 0, # 2 inputs: int int
          1, 0, # 1 outputs: int
          $"neg",
        1, #1 Defined Function (myadd)
          0, # 0 inputs
          1, 0, # 1 outputs: int
      2, # Constants
        1, $4, #2 int 4
        (16 + 0), 2, #3 auro.int.neg(const_2 (4))
      2, # Block for #1 (myadd)
        (16 + 3), #0 = const_3 (-4)
        0, 0, #return #0
      0, # No metadata
    )

    let parsed = parseData(code)
    let compiled = compile(parsed, "Constant Call")
    let function = compiled.get_function("main")

    let result = function.run(@[])
    check(result == @[Value(kind: intV, i: -4)])

  test "Simple Pair":

    #[ Features
      Product type and operations
    ]#

    let data = bin(
      "Auro 0.6", 0,
      5,
        #0 is the argument module
        2, 1, #1 Define (exports)
          2, 0, $"main",
        1, $"auro.prim", #2 Import

        2, 2, #3 Define (arguments for auro.tuple)
          1, 0, $"0", # type_0 (int)
          1, 0, $"1", # type_2 (int)
        1, $"auro.tuple", #4 Import functor
        4, 4, 3, #5 Build auro.tuple
      2, # Types
        (2+1), $"int", #0
        (5+1), $"", #1 tuple(int, #2)
      3, # Functions
        1, #0 Defined Function (main)
          0,
          1, 1,
        (5+2), #1 auro.tuple.get1
          1, 1,
          1, 2,
          $"get1",
        (5+2),  #2 auro.tuple.new
          2, 0, 2,
          1, 1,
          $"new",
      2, # Constants
        1, $4, #3 int 4
        1, $5, #4 int 5
      5, # Block for #1 (main)
        (16+3), #0 = const_3 (4)
        (16+4), #1 = const_4 (5)
        (16 + 2), 2, 1, #2 = tuple.new(#0, #1)
        (16 + 1), 2, #3 = tuple.get1(#2)
        0, 3, #return #3
      0, # No metadata
    )

    let parsed = parseData(data)
    # Infinite loop, because of an infinite type definition
    #let compiled = compile(parsed)
    #let function = compiled.get_function("main")

    #let result = function.run(@[])
    #check(result == @[Value(kind: intV, i: 5)])

  test "Linked List":
    # Use typeshells to break type recursion, the type won't be evaluated
    # until the functions are used

    #[ Features
      Product type and operations
      Nullable type
      Shell type
      Recursive types
    ]#

    let data = bin(
      "Auro 0.6", 0,
      12,
        #0 is the argument module
        2, 1, #1 Define (exports)
          2, 1, $"main",
        1, $"auro.int", #2 Import

        2, 2, #3 Define (arguments for auro.tuple)
          1, 0, $"0", # type_0 (int)
          1, 2, $"1", # type_2 (nullable tuple)
        1, $"auro.record", #4 Import functor
        4, 4, 3, #5 Build auro.record

        2, 1, #6 Define(arguments for auro.null)
          1, 3, $"0", # type_1 (typeshell)
        1, $"auro.null", #7 Import functor
        4, 7, 6, #8 Build auro.null

        2, 1, #9 Define(arguments for auro.typeshell)
          1, 1, $"0", # type_1 (tuple)
        1, $"auro.typeshell", #10 Import functor
        4, 10, 9, #11 Build auro.null

        1, $"auro.core", #12 Import
      5, # Types
        (2+1), $"int", #0
        (5+1), $"", #1 tuple(int, #2)
        (8+1), $"", #2 nullable(#3)
        (11+1), $"", #3 typeshell(#1)
        (12+1), $"bool", #4 typeshell(#1)
      11, # Functions
        1, #0 Defined Function (second)
          1, 1, # 1 ins: tuple
          1, 0, # 1 outs: int
        1, #1 Defined Function (main)
          0,
          1, 0,
        (5+2), #2 value
          1, 1,
          1, 0,
          $"get0",
        (5+2), #3 next
          1, 1,
          1, 2,
          $"get1",
        (5+2), #4 new tuple
          2, 0, 2,
          1, 1,
          $"new",
        (11+2), #5 new typeshell
          1, 1,
          1, 3,
          $"new",
        (11+2), #6 get from typeshell
          1, 3,
          1, 1,
          $"get",
        (8+2), #7 null() -> null
          0, 1, 2,
          $"null",
        (8+2), #8 null.new(shell) -> null
          1, 3,
          1, 2,
          $"new",
        (8+2), #9 null.get(null) -> shell
          1, 2,
          1, 3,
          $"get",
        (8+2), #10 null.isnull(shell) -> bool
          1, 2,
          1, 4,
          $"isnull",
      4, # Constants
        1, $4, #11 int 4
        1, $5, #12 int 5
        1, $6, #13 int 6
        1, $0, #14 int 0
      5, # Block for #0 (second)
        #0 = arg_0: tuple (first)
        (16 + 3), 0, #1 = #0.next: null(shell(tuple))
        (16 + 9), 1, #2 = #1.get: shell(tuple)
        (16 + 6), 2, #3 = #2.get: tuple (second)
        (16 + 2), 3, #4 = #3.value
        0, 4,
      13, # Block for #1 (main)
        (16+13), #0 = const_2 (6)
        (16 + 7), #1 = null()
        (16 + 4), 0, 1, #2 = type_1(#0, #1)
        (16 + 5), 2, #3 = shell(#2)

        (16+12), #4 = const_1 (5)
        (16 + 8), 3, #5 = null(#3)
        (16 + 4), 4, 5, #6 = type_1(#4, #5)
        (16 + 5), 6, #7 = shell(#6)

        (16+11), #8 = const_0 (4)
        (16 + 8), 7, #9 = null(#7)
        (16 + 4), 8, 9, #10 = type_1(#8, #9)
        
        (16 + 0), 10, #11 = second(#10)
        0, 11, #return #11
      0, # No metadata
    )

    let parsed = parseData(data)
    let compiled = compile(parsed, "Linked List")
    let function = compiled.get_function("main")

    let result = function.run(@[])
    check(result == @[Value(kind: intV, i: 5)])

  test "Recursive Type":
    # The linked list test without typeshells crashes

    #[ Features
      Product type and operations
      Nullable type
      Shell type
      Recursive types
    ]#

    let data = bin(
      "Auro 0.6", 0,
      8,
        #0 is the argument module
        2, 1, #1 Define (exports)
          2, 1, $"main",
        1, $"auro.int", #2 Import

        2, 2, #3 Define (arguments for auro.tuple)
          1, 0, $"0", # type_0 (int)
          1, 2, $"1", # type_2 (nullable tuple)
        1, $"auro.record", #4 Import functor
        4, 4, 3, #5 Build auro.tuple

        2, 1, #6 Define(arguments for auro.null)
          1, 2, $"0", # type_1 (tuple)
        1, $"auro.null", #7 Import functor
        4, 7, 6, #8 Build auro.null
      3, # Types
        (2+1), $"int", #0
        (5+1), $"", #1 tuple(int, #2)
        (8+1), $"", #2 nullable(#1)
      5, # Functions
        1, #0 Defined Function (second)
          1, 2, # 1 ins: type_2
          1, 0, # 1 outs: int
        1, #1 Defined Function (main)
          0,
          1, 1,
        (5+2), #2
          1, 1,
          1, 0,
          $"get0",
        (5+2), #3
          1, 1,
          1, 2,
          $"get1",
        (5+2), #4
          2, 0, 2,
          1, 1,
          $"new",
      4, # Statics
        1, $4, #5 int 4
        1, $5, #6 int 5
        1, $6, #7 int 6
        1, $0, #8 int 0
      5, # Block for #0 (second)
        #0 = arg_0
        #9, 5, 0, #1 = #0 or goto 5
        (16 + 3), 1, #2 = get_1(#1)
        #9, 5, 2, #3 = #2 or goto 5
        (16 + 2), 3, #4 = get_0(#3)
        0, 4, #return #4
        (16+8), #5 = const_3 (0)
        0, 5, #return #5
      9, # Block for #1 (main)
        1, #0 = null
        (16+7), #1 = const_2 (6)
        (16 + 4), 1, 0, #2 = type_1(#1, #0)
        (16+6), #3 = const_1 (5)
        (16 + 4), 3, 2, #4 = type_1(#3, #2)
        (16+5), #5 = const_0 (4)
        (16 + 4), 5, 4, #6 = type_1(#5, #4)
        (16 + 0), 6, #7 = second(#6)
        0, 7, #return #7
      0, # No metadata
    )

    expect CompileError:
      let parsed = parseData(data)
      let compiled = compile(parsed, "Recursive Type")

  test "Function Object":

    #[ Features
      Function objects
      Function object application function
    ]#

    let data = bin(
      "Auro 0.6", 0,
      8,
        #0 is the argument module
        2, 1, #1 Define (exports)
          2, 4, $"main",
        1, $"auro.int", #2

        1, $"auro.function", #3 Import functor
        2, 2, #4 Define (argument)
          1, 0, $"in0",
          1, 0, $"out0",
        4, 3, 4, #5 Build auro.function with #4 (int -> int)

        3, 5, $"new", #6 Import functor auro.function.new
        2, 1, #7 Define module
          2, 1, $"0", # 0: function_1 (add4)
        4, 6, 7, #8 build auro.function.new(add4 as `0`)
      2, # Types
        (2+1), $"int", #0 import auro.int.int
        (5+1), $"", #1 type of function(int -> int)
      6, # Functions
        (2+2), #0
          2, 0, 0, 1, 0, $"add",
        1, #1 Defined add4
          1, 0, # 1 ins: int
          1, 0, # 1 out: int
        1, #2 Defined apply5
          1, 1, # 1 in:  (int -> int)
          1, 0, # 1 out: int
        (5+2), #3 Apply to ( int -> int )
          2, 1, 0, # 2 ins: (int->int) int
          1, 0, # 1 out: int
          $"apply",
        1, #4 Defined main
          0, # 0 ins
          1, 0, # 1 outs: int
        (8+2), #5 auro.function.new(add4).``
          0, 1, 1, # void -> (int->int)
          $"",
      2, # Statics
        1, $4, #6 int 4
        1, $5, #7 int 5
      3, # Block for #1 (add4)
        #0 = arg_0
        (16+6), #1 = const_6 (4)
        (16 + 0), 0, 1, #2 c = add(#0, #1)
        0, 2, #return #2
      3, # Block for #2 (apply5)
        #0 = arg_0
        (16+7), #1 = const_7 (5)
        (16 + 3), 0, 1, #2 = apply(#0, #1)
        0, 2,
      3, # Block for #4 (main)
        (16+5), #0 = add4
        (16 + 2), 0, #1 = apply5(#0)
        0, 1,
      0, # No metadata
    )

    let parsed = parseData(data)
    let compiled = compile(parsed, "Function Object")
    let function = compiled.get_function("main")

    let result = function.run(@[])
    check(result == @[Value(kind: intV, i: 9)])

  test "Metadata fail 1":

    #[ Equivalent Cu
      // Type string not found in auro.core
      import auro.core { type string; }
    ]#

    let code = bin(
      "Auro 0.6", 0,
      2, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          1, 0, $"string", # export type #0 as "string"
        1, $"auro.int", #2 Import
      1, # Types
        (2+1), $"string", #0 import "string" from auro.int, should fail
      0, # Functions
      0, # Constants
      (1 shl 2), # Metadata, 1 toplevel node
        (4 shl 2), # 3 nodes (+ header)
          (10 shl 2 or 2), "source map",
          (2 shl 2),
            (4 shl 2 or 2), "file",
            (4 shl 2 or 2), "test",
          (4 shl 2),
            (6 shl 2 or 2), "module",
            (2 shl 1 or 1), # module at index #2
            (2 shl 2),
              (4 shl 2 or 2), "line",
              (2 shl 1 or 1), # at line 2
            (2 shl 2),
              (6 shl 2 or 2), "column",
              (7 shl 1 or 1), # at column 7
          (4 shl 2),
            (4 shl 2 or 2), "type",
            (0 shl 1 or 1), # at index #0
            (2 shl 2),
              (4 shl 2 or 2), "line",
              (2 shl 1 or 1), # at line 2
            (2 shl 2),
              (6 shl 2 or 2), "column",
              (25 shl 1 or 1), # at column 25
    )



    try:
      let parsed = parseData(code)
      let compiled = compile(parsed, "Metadata fail 1")
      let item = compiled["string"]

      checkpoint("Expected TypeNotFoundError")
      fail()
    except TypeNotFoundError:
      let exception = (ref TypeNotFoundError) getCurrentException()
      let typeinfo = exception.typeinfo
      check(typeinfo.line == some(2))
      check(typeinfo.column == some(25))

  test "Typecheck fail":

    #[ Equivalent Cu
      // Type string not found in auro.core
      import auro.prim { type int; }
      import auro.string { type string; }
      import auro.system { void println(string); }
      void main () {
        println(42); // Should fail typecheck
      }
    ]#

    let code = bin(
      "Auro 0.6", 0,
      4, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          2, 1, $"main",
        1, $"auro.int", #2
        1, $"auro.string", #3
        1, $"auro.system", #4
      2, # Types
        (2+1), $"int",    #0 from auro.core import int
        (3+1), $"string", #1 from auro.core import string
      2, # Functions
        (4+2), #0 from auro.system
          1, 1, 0,      #  void println(string)
          $"println",
        1, 0, 0,        #1 void main ()
      1, # Constants
        1, 42, #2 int 42
      3, # Block for #1 (main)
        (16+2), #0 const_2 (42)
        (16 + 0), 0, # println #0 (Shouldn't typecheck)
        0,
      (1 shl 2), # Metadata, 1 toplevel node
        (3 shl 2), # 2 nodes (+ header)
          (10 shl 2 or 2), "source map",
          (2 shl 2),
            (4 shl 2 or 2), "file",
            (4 shl 2 or 2), "test",
          (4 shl 2),
            (8 shl 2 or 2), "function",
            (1 shl 1 or 1), # function #1

            (2 shl 2),
              (4 shl 2 or 2), "line",
              (5 shl 1 or 1),
            
            (3 shl 2), # 2 instructions (+ header)
              (4 shl 2 or 2), "code",
              (3 shl 2),
                (0 shl 1 or 1), # code[0] (sgt 42)
                (6 shl 1 or 1), # line 6
                (8 shl 1 or 1), # column 8
              (3 shl 2),
                (1 shl 1 or 1), # code[1] (call println)
                (6 shl 1 or 1), # line 6
                (2 shl 1 or 1), # column 2
    )

    try:
      let parsed = parseData(code)
      let compiled = compile(parsed, "Typecheck fail")
      let fn = compiled.get_function("main")

      checkpoint("Expected TypeError")
      fail()
    except TypeError:
      let exception = (ref TypeError) getCurrentException()
      let instinfo = exception.instinfo
      check(instinfo.line == some(6))
      check(instinfo.column == some(2))

  test "Incorrect Signature":

    #[ Equivalent Cu
      import auro.system {
        void println(); // It's actually void println(string)
      }
    ]#

    let code = bin(
      "Auro 0.6", 0,
      2, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          2, 0, $"println",
        1, $"auro.system", #2 Import
      0, # Types
      1, # Functions
        (2+2), #0 from auro.system import string
          0, 0, #  void println () (wrong, it really is void println(string))
          $"println",
      0, # Constants
      (1 shl 2), # Metadata, 1 toplevel node
        (4 shl 2), # 3 nodes (+ header)
          (10 shl 2 or 2), "source map",
          (2 shl 2),
            (4 shl 2 or 2), "file",
            (4 shl 2 or 2), "test",
          (4 shl 2),
            (6 shl 2 or 2), "module",
            (0 shl 1 or 1), # module at index #0
            (2 shl 2),
              (4 shl 2 or 2), "line",
              (1 shl 1 or 1),
            (2 shl 2),
              (6 shl 2 or 2), "column",
              (7 shl 1 or 1),
          (4 shl 2),
            (8 shl 2 or 2), "function",
            (0 shl 1 or 1), # at index #0
            (2 shl 2),
              (4 shl 2 or 2), "line",
              (2 shl 1 or 1),
            (2 shl 2),
              (6 shl 2 or 2), "column",
              (7 shl 1 or 1),
    )

    try:
      let parsed = parseData(code)
      let compiled = compile(parsed, "Incorrect Signature")
      let fn = compiled.get_function("println")

      checkpoint("Expected Incorrect Signature Error")
      fail()
    except IncorrectSignatureError:
      let exception = (ref IncorrectSignatureError) getCurrentException()
      let codeinfo = exception.codeinfo
      check(codeinfo.line == some(2))
      check(codeinfo.column == some(7))

  test "Module Type Arguments":
    #[ Features
      type module argument
    ]#

    let code = bin(
      "Auro 0.6", 0,
      4, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          1, 1, $"T",

        2, 1, #2 Define(arguments for auro.typeshell)
          1, 0, $"0", # type_0 (T)
        1, $"auro.typeshell", #3 Import auro.typeshell
        4, 3, 2, #4 Build auro.typeshell(T)

      2, # Types
        (0+1), $"T", #0 import "T" from module 0 (argument)
        (4+1), $"", #1 import "" from typeshell(T)
      0, # Functions
      0, # Constants
      0, # No metadata
    )

    let parsed = parseData(code)
    let compiled = compile(parsed, "Module Type Arguments")

    proc newArg (name: string, tp: machine.Type): machine.Module =
      machine.SimpleModule(name, [machine.TypeItem("T", tp)])

    let modint1 = compiled.build(newArg("int argument 1", aurolib.intT))
    let modint2 = compiled.build(newArg("int argument 1", aurolib.intT))
    let modstr = compiled.build(newArg("string argument 1", aurolib.strT))

    # Even though modint1 and modint2 are built with different arguments
    # they return the same module because it's the same type used as argument
    check(modint1["T"].t == modint2["T"].t)
    check(modint1["T"].t != modstr["T"].t)

  test "Other Module Arguments":
    #[ Features
      module argument
      same module if arguments are equal (same types)
    ]#

    let code = bin(
      "Auro 0.6", 0,
      5, # Modules
        # module #0 is the argument
        2, 1, #1 Define (exports)
          1, 1, $"T",

        2, 1, #2 Define(arguments for auro.typeshell)
          1, 0, $"0", # type_0 (T)
        1, $"auro.typeshell", #3 import
        4, 3, 2, #4 Build auro.typeshell(T)

        1, $"auro.int", #5 import

      3, # Types
        (0+1), $"T", #0 import "T" from module 0 (argument)
        (4+1), $"", #1 import "" from typeshell(T)
        (5+1), $"int", #2
      1, # Functions
        # HERE: A function from argument is used
        (0+2), $"f", #0 import "f" from module 0 (argument)
          1, 2, 0, # void f (int)
      0, # Constants
      0, # No metadata
    )

    let parsed = parseData(code)
    let compiled = compile(parsed, "Other Module Arguments")

    let argument = machine.SimpleModule("int argument", [
      machine.TypeItem("T", aurolib.intT)
    ])

    let modint1 = compiled.build(argument)
    let modint2 = compiled.build(argument)

    # Even if all the arguments are the same, the returned modules are
    # different because one of the used arguments is not a type.
    check(modint1["T"].t != modint2["T"].t)

  test "Name Matching":
    #[ Features
      complex name matchinv
    ]#

    let code = bin(
      "Auro 0.6", 0,
      1, # Modules
        # module #0 is the argument
        2, 5, #1 Every one of these just exports the argument
          0, 0, $"a",
          0, 0, $"a\x1db",
          0, 0, $"a\x1db\x1db\x1dc",
          0, 0, $"a\x1dc\x1dd",
          0, 0, $"a\x1dc\x1de",
      0, # Types
      0, # Functions
      0, # Constants
      0, # No metadata
    )

    let parsed = parseData(code)
    let compiled = compile(parsed, "Name Matching")

    check(compiled[parseName("b")].kind == nilItem)
    check(compiled[parseName("a")].kind != nilItem)
    check(compiled[parseName("a\x1db")].kind != nilItem)
    check(compiled[parseName("a\x1dc")].kind == nilItem)
    check(compiled[parseName("a\x1dd")].kind != nilItem)
    check(compiled[parseName("a\x1db\x1dc")].kind != nilItem)
    check(compiled[parseName("a\x1db\x1dc\x1dc")].kind == nilItem)
