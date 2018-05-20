
let anyT*: Type = Type(name: "any")

block:
  var modules = initTable[Type, Module](32)

  type AnyVal = ref object of RootObj
    tp: Type
    v: Value

  let baseModule = createModule("cobre.any"):
    self["any"] = anyT

  globalFunctor("cobre.any"):
    var argitem = argument["0"]
    if argitem.kind == nilItem: return baseModule
    if argitem.kind != tItem:
      raise newException(Exception, "argument 0 for cobre.any is not a type")
    var base = argitem.t

    if modules.hasKey(base):
      return modules[base]

    result = createModule("any(" & base.name & ")"):
      self.addfn("new", mksig(@[base], @[anyT])):
        let val = AnyVal(tp: base, v: args[0])
        args.ret Value(kind: objV, obj: val)

      self.addfn("get", mksig(@[anyT], @[base])):
        let val = AnyVal(args[0].obj)
        if val.tp != base:
          raise newException(Exception, "Any type was " & val.tp.name)
        args.ret val.v

      self.addfn("test", mksig(@[anyT], @[boolT])):
        let val = AnyVal(args[0].obj)
        args.ret Value(kind: boolV, b: val.tp == base)

    modules[base] = result