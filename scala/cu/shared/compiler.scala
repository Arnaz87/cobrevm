package arnaud.culang

class CompileError(msg: String, node: Ast.Node) extends Exception (
  if (node.hasSrcpos) msg + s". At line ${node.line + 1} column ${node.column}" else msg
)

class Compiler {
  import scala.collection.mutable.{ArrayBuffer, Map}
  import arnaud.cobre.format.{Program => CGProgram, meta => Meta}
  import Meta.implicits._
  import Ast._

  def error(_msg: String)(implicit node: Node): Nothing =
    throw new CompileError(_msg, node)

  val program = new CGProgram()

  val modules = Map[String, program.Module]()
  val types = Map[String, program.Type]()
  val rutines = Map[String, program.Rutine]()

  val rutine_defs = Map[String, Scope]()

  object meta {
    val srcpos = new ArrayBuffer[Meta.Item]()
    val srcnames = new ArrayBuffer[Meta.Item]

    program.metadata += new Meta.SeqItem(srcpos)
    program.metadata += new Meta.SeqItem(srcnames)
  }

  val prelude: program.Module = program.Module("Prelude", Nil)

  val binaryType = prelude.Type("Binary")
  val intType = prelude.Type("Int")
  val strType = prelude.Type("String")
  val boolType = prelude.Type("Bool")
  types("String") = strType
  types("Int") = intType
  types("Bool") = boolType

  val makeint = prelude.Rutine("makeint",
    Array(binaryType),
    Array(intType)
  )
  val makestr = prelude.Rutine("makestr",
    Array(binaryType),
    Array(strType)
  )

  val iadd = prelude.Rutine("iadd",
    Array(intType, intType), Array(intType)
  )

  val isub = prelude.Rutine("isub",
    Array(intType, intType), Array(intType)
  )

  val igt = prelude.Rutine("gt",
    Array(intType, intType), Array(boolType)
  )

  val ieq = prelude.Rutine("eq",
    Array(intType, intType), Array(boolType)
  )

  val concat = prelude.Rutine("concat",
    Array(strType, strType), Array(strType)
  )

  rutines("itos") = prelude.Rutine("itos",
    Array(types("Int")),
    Array(types("String"))
  )
  rutines("print") = prelude.Rutine("print",
    Array(types("String")),
    Nil
  )

  val srcmap = new ArrayBuffer[Meta.Item]()
  srcmap += "source map"

  class SrcInfo (val rutine: program.RutineDef, name: String, line: Int, column: Int) {
    val buffer = new ArrayBuffer[Meta.Item]
    import Meta._

    // Instruction Index => (Line, Column)
    val insts = Map[rutine.Inst, (Int, Int)]()

    // Register Index => Name
    val vars = Map[rutine.Reg, (Int, Int, String)]()

    def build () {
      import arnaud.cobre.format.meta.implicits._
      buffer += SeqItem("name", name)
      buffer += SeqItem("line", line)
      buffer += SeqItem("column", column)

      buffer += new SeqItem(("regs":Item) +: vars.map{
        case (reg, (line, column, name)) =>
          SeqItem(reg.index, line, column, name)
      }.toSeq)
      buffer += new SeqItem(("insts":Item) +: insts.map{
        case (inst, (line, column)) =>
          SeqItem(inst.index, line, column)
      }.toSeq)
      srcmap += new SeqItem(buffer)
    }
  }

  class Scope (val rutine: program.RutineDef, val srcinfo: SrcInfo) {
    type Reg = rutine.Reg

    val map = Map[String, Reg]()

    val outs = ArrayBuffer[Reg]()

    def get (k: String) = map.get(k)
    def update (k: String, v: Reg) = map(k) = v

    class SubScope(parent: Scope) extends Scope(rutine, srcinfo) {
      override def get (k: String) = this.map get k match {
        case None => parent.get(k).asInstanceOf[Option[this.rutine.Reg]]
        case somereg => somereg
      }
    }

    def apply (k: String)(implicit node: Node) = get(k) match {
      case Some(reg) => reg
      case None => error(s"Variable $k not in scope")
    }

    def Scope = new SubScope(this)
  }

  def genSyms (stmt: Toplevel) { stmt match {
    case Import(modname) => 
    case node@Proc(Id(name), params, rets, body) =>
      val rutine = program.Rutine(name)
      val srcInfo = new SrcInfo(rutine, name, node.line, node.column)
      val scope = new Scope(rutine, srcInfo)
      for ( (Id(ident), Type(tp)) <- params ) {
        scope(ident) = scope.rutine.InReg(types(tp))
      }
      for (Type(tp) <- rets) {
        scope.outs += scope.rutine.OutReg(types(tp))
      }
      rutine_defs(name) = scope
      rutines(name) = scope.rutine
  } }

  def %% (node: Expr, scope: Scope): scope.rutine.Reg = {
    implicit val _node = node
    node match {
    case Var(Id(nm)) => scope(nm)
    case Num(dbl) =>
      val n = dbl.asInstanceOf[Int]
      val bytes = new Array[Int](4)
      bytes(0) = (n >> 24) & 0xFF
      bytes(1) = (n >> 16) & 0xFF
      bytes(2) = (n >> 8 ) & 0xFF
      bytes(3) = (n >> 0 ) & 0xFF
      val bin = program.BinConstant(bytes)
      val const = program.CallConstant(makeint, Array(bin))

      val reg = scope.rutine.Reg(intType)
      scope.rutine.Cns(reg, const)
      reg
    case Str(str) =>
      val bytes = str.getBytes("UTF-8")
      val bin = program.BinConstant(
        bytes map (_.asInstanceOf[Int])
      )
      val const = program.CallConstant(makestr, Array(bin))

      val reg = scope.rutine.Reg(strType)
      scope.rutine.Cns(reg, const)
      reg
    case Call(Id(fname), args) =>
      val rutine = rutines(fname)
      if (args.size != rutine.ins.size) error(
        s"Expected ${rutine.ins.size} arguments, found ${args.size}"
      )
      val reg = scope.rutine.Reg(rutine.outs(0))

      val call = scope.rutine.Call(rutine, Array(reg), args map (%%(_, scope)))

      scope.srcinfo.insts(call.asInstanceOf[scope.srcinfo.rutine.Inst]) =
        (node.line, node.column)
      reg
    case Binop(op, _a, _b) =>
      val a = %%(_a, scope)
      val b = %%(_b, scope)
      val (rutine, rtp) = op match {
        case Add => 
          (a.t, b.t) match {
            case (`intType`, `intType`) => (iadd, intType)
            case (`strType`, `strType`) => (concat, strType)
          }
        case Sub => (isub, intType)
        case Gt  => (igt, boolType)
        case Eq  => (ieq, boolType)
        case _ => error(s"Unknown overload for $op with types")
      }
      val reg = scope.rutine.Reg(rtp)
      val call = scope.rutine.Call(rutine, Array(reg), Array(a, b))

      scope.srcinfo.insts(call.asInstanceOf[scope.srcinfo.rutine.Inst]) =
        (node.line, node.column)

      reg
  } }

  def %% (node: Stmt, scope: Scope) {
    implicit val _node = node;
    node match {
    case Decl(Type(_tp), ps) =>
      val tp = types(_tp)
      for ( decl@DeclPart(Id(nm), vl) <- ps ) {
        val reg = scope.rutine.Reg(tp)
        scope(nm) = reg
        vl match {
          case Some(expr) =>
            val result = %%(expr, scope)
            scope.rutine.Cpy(reg, result)
          case None =>
        }

        scope.srcinfo.vars(reg.asInstanceOf[scope.srcinfo.rutine.Reg]) =
          (node.line, node.column, nm)
      }
    case Call(Id(fname), args) =>
      val rutine = rutines(fname)
      if (args.size != rutine.ins.size) error(
        s"Expected ${rutine.ins.size} arguments, found ${args.size}"
      )
      var call = scope.rutine.Call(rutine, Nil, args map (%%(_, scope)))

      scope.srcinfo.insts(call.asInstanceOf[scope.srcinfo.rutine.Inst]) =
        (node.line, node.column)
    case While(cond, Block(stmts)) =>
      val $start = scope.rutine.Lbl
      val $end = scope.rutine.Lbl

      scope.rutine.Ilbl($start)
      val $cond = %%(cond, scope)
      scope.rutine.Ifn($end, $cond)

      val scoped = scope.Scope
      for (stmt <- stmts) { %%(stmt, scoped) }

      scope.rutine.Jmp($start)
      scope.rutine.Ilbl($end)
    case If(cond, Block(stmts), orelse) =>
      val $else = scope.rutine.Lbl
      val $end  = scope.rutine.Lbl

      val $cond = %%(cond, scope)
      scope.rutine.Ifn($else, $cond)

      val scoped = scope.Scope
      for (stmt <- stmts) { %%(stmt, scoped) }
      scope.rutine.Jmp($end)
      scope.rutine.Ilbl($else)
      orelse match {
        case Some(Block(stmts)) =>
          val scoped = scope.Scope
          for (stmt <- stmts) { %%(stmt, scoped) }
        case None =>
      }
      scope.rutine.Ilbl($end)
    case Assign(Id(nm), expr) =>
      val reg = scope(nm)
      val result = %%(expr, scope)
      val inst = scope.rutine.Cpy(reg, result)

      scope.srcinfo.insts(inst.asInstanceOf[scope.srcinfo.rutine.Inst]) =
        (node.line, node.column)
    case Return(exprs) =>
      if (exprs.size != scope.outs.size) error(
        s"Expected ${scope.outs.size} return values, found ${exprs.size}"
      )
      for ( (reg, expr) <- scope.outs zip exprs ) {
        val result = %%(expr, scope)
        scope.rutine.Cpy(reg, result)
      }
      scope.rutine.End()
  } }

  def %% (node: Toplevel) { node match {
    case Import(modname) => 
    case Proc(Id(name), params, rets, body) =>
      val scope = rutine_defs(name)
      for (stmt <- body.stmts) { %%(stmt, scope) }
      scope.rutine.End()
      scope.srcinfo.build()
  } }

  def binary: Seq[Int] = {
    val buffer = new ArrayBuffer[Int]()
    val writer = new arnaud.cobre.format.Writer(buffer)
    writer.write(program)
    buffer
  }

  def writeMetadata () {
    program.metadata += new Meta.SeqItem(srcmap)
  }
}

object Compiler {
  def apply (prg: Ast.Program): Compiler = {
    val compiler = new Compiler

    prg.stmts foreach (compiler.genSyms(_))

    for (stmt <- prg.stmts) {
      compiler %% stmt
    }
    compiler.writeMetadata()
    return compiler
  }
}