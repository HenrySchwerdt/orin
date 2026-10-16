import Orin.Check

/-!
# Executable front end of the ownership checker (differential testing, `docs/formal.md`)

`orin_check` reads programs of the structured MIR fragment in a line-based text format and prints
one verdict line per program.  The verdict is computed by `Orin.check`, the very function that
`check_sound` is about; nothing is re-implemented here except the parser and a *reason* report
(`diag`), which reuses `stepA` and `joinS` and is cross-checked against `check` at run time.

Input format (one token group per line, `#` starts a comment line):

    prog NAME N PARAMS      N locals; PARAMS = string over r (reference) / s (scalar), or -
    const D | move D S | borrow D S | dup D S | release X
    structNew D Y*          getField D O I r|s   (r: D is a reference local, s: a scalar)
    setField X I V | takeField D X I | putField X I S | makeUnique X
    arrayLen D A | arrayGet D A I r|s | arraySet X I V | arrayNew D N   (index/length are scalar locals)
    if C / else / end       structured branch; the code after `end` is the continuation
    loop C / end            while: the body (up to `end`) runs while the scalar local C is 0
    endprog

Output: `NAME ACCEPT` or `NAME REJECT <reason>`; a malformed program gives `NAME ERROR <why>`.
-/

namespace Orin.Exec

open Orin

def describe : MI → String
  | .const d _ => s!"const l{d}"
  | .move d s => s!"move l{d} <- l{s}"
  | .borrow d s => s!"borrow l{d} <- l{s}"
  | .dup d s => s!"dup l{d} <- l{s}"
  | .release x => s!"release l{x}"
  | .alloc d n => s!"alloc l{d} {n}"
  | .getField d o i _ => s!"getField l{d} <- l{o}.{i}"
  | .setField x i v => s!"setField l{x}.{i} <- l{v}"
  | .takeField d x i => s!"takeField l{d} <- l{x}.{i}"
  | .putField x i s => s!"putField l{x}.{i} <- l{s}"
  | .makeUnique x => s!"makeUnique l{x}"
  | .arrayLen d a => s!"arrayLen l{d} <- l{a}"
  | .arrayGet d a i _ => s!"arrayGet l{d} <- l{a}[l{i}]"
  | .arraySet x i v => s!"arraySet l{x}[l{i}] <- l{v}"
  | .arrayNew d n => s!"arrayNew l{d} len l{n}"

/-- Same shape as `chk`, but names the first rejected instruction.  Uses `stepA`/`joinS`. -/
def diag (np : Nat) : AState → Code → Except String AState
  | a, .nil => .ok a
  | a, .op i k =>
    match stepA np a i with
    | none => .error s!"instruction rejected: {describe i}"
    | some a1 => diag np a1 k
  | a, .ite c t e k =>
    if c < a.ls.length ∧ gk a.ls c = .init then
      match diag np a t with
      | .error m => .error s!"then-branch: {m}"
      | .ok at' =>
        match diag np a e with
        | .error m => .error s!"else-branch: {m}"
        | .ok ae =>
          match joinS at' ae with
          | none => .error "join rejected (hole sets differ)"
          | some aj => diag np aj k
    else .error s!"if condition l{c} is not an initialised scalar"
  | a, .loop c t k =>
    match loopFix (fun b => chk np b t) c (loopFuel a) a with
    | none => .error s!"loop: no invariant (condition l{c} not an initialised scalar, body rejected, or no fixpoint)"
    | some b => diag np b k

def reason (p : Prog) : String :=
  match diag p.params.length p.entry p.code with
  | .error m => m
  | .ok af => if af.holes.isEmpty then "?" else "open hole at return"

/-! ### parser -/

inductive Item where
  | op (i : MI)
  | sn (d : Nat) (ys : List Nat)
  | ite (c : Nat) (t e : Code)
  | lp (c : Nat) (t : Code)

def toCode (rev : List Item) : Code :=
  rev.foldl (fun k it =>
    match it with
    | .op i => Code.op i k
    | .sn d ys => Code.structNew d ys k
    | .ite c t e => Code.ite c t e k
    | .lp c t => Code.loop c t k) Code.nil

structure Frame where
  c : Nat
  thn : Option Code
  isLoop : Bool := false
  saved : List Item

structure PS where
  name : String := ""
  n : Nat := 0
  params : List Bool := []
  frames : List Frame := []
  cur : List Item := []

def nat (s : String) : Except String Nat :=
  match s.toNat? with
  | some n => .ok n
  | none => .error s!"bad number '{s}'"

def nats (ws : List String) : Except String (List Nat) := ws.mapM nat

def parseParams (s : String) : Except String (List Bool) :=
  if s == "-" then .ok []
  else s.toList.mapM fun c =>
    if c == 'r' then .ok true else if c == 's' then .ok false else .error s!"bad param class '{c}'"

def addOp (ps : PS) (i : MI) : PS := { ps with cur := .op i :: ps.cur }

/-- One instruction line (already split into words). -/
def instr (ps : PS) : List String → Except String PS
  | ["const", d] => do return addOp ps (.const (← nat d) 0)
  | ["move", d, s] => do return addOp ps (.move (← nat d) (← nat s))
  | ["borrow", d, s] => do return addOp ps (.borrow (← nat d) (← nat s))
  | ["dup", d, s] => do return addOp ps (.dup (← nat d) (← nat s))
  | ["release", x] => do return addOp ps (.release (← nat x))
  | "structNew" :: d :: ys => do
      return { ps with cur := .sn (← nat d) (← nats ys) :: ps.cur }
  | ["getField", d, o, i, c] => do
      let r ← (if c == "r" then pure true else if c == "s" then pure false
               else throw s!"bad class '{c}'")
      return addOp ps (.getField (← nat d) (← nat o) (← nat i) r)
  | ["setField", x, i, v] => do return addOp ps (.setField (← nat x) (← nat i) (← nat v))
  | ["takeField", d, x, i] => do return addOp ps (.takeField (← nat d) (← nat x) (← nat i))
  | ["putField", x, i, s] => do return addOp ps (.putField (← nat x) (← nat i) (← nat s))
  | ["makeUnique", x] => do return addOp ps (.makeUnique (← nat x))
  | ["arrayLen", d, a] => do return addOp ps (.arrayLen (← nat d) (← nat a))
  | ["arrayGet", d, a, i, c] => do
      let r ← (if c == "r" then pure true else if c == "s" then pure false
               else throw s!"bad class '{c}'")
      return addOp ps (.arrayGet (← nat d) (← nat a) (← nat i) r)
  | ["arraySet", x, i, v] => do return addOp ps (.arraySet (← nat x) (← nat i) (← nat v))
  | ["arrayNew", d, n] => do return addOp ps (.arrayNew (← nat d) (← nat n))
  | ["if", c] => do
      return { ps with frames := ⟨← nat c, none, false, ps.cur⟩ :: ps.frames, cur := [] }
  | ["loop", c] => do
      return { ps with frames := ⟨← nat c, none, true, ps.cur⟩ :: ps.frames, cur := [] }
  | ["else"] =>
      match ps.frames with
      | f :: fs =>
        if f.isLoop then .error "else in a loop"
        else if f.thn.isSome then .error "second else"
        else .ok { ps with frames := { f with thn := some (toCode ps.cur) } :: fs, cur := [] }
      | [] => .error "else without if"
  | ["end"] =>
      match ps.frames with
      | f :: fs =>
        if f.isLoop then
          .ok { ps with frames := fs, cur := .lp f.c (toCode ps.cur) :: f.saved }
        else
        match f.thn with
        | some t => .ok { ps with frames := fs, cur := .ite f.c t (toCode ps.cur) :: f.saved }
        | none => .error "if without else"
      | [] => .error "end without if"
  | ws => .error s!"unknown line '{" ".intercalate ws}'"

def finish (ps : PS) : String :=
  if !ps.frames.isEmpty then s!"{ps.name} ERROR unclosed if or loop"
  else
    let p : Prog := ⟨ps.n, ps.params, toCode ps.cur⟩
    let v := check p
    let r := reason p
    if v then
      (if r == "?" then s!"{ps.name} ACCEPT" else s!"{ps.name} ERROR diag disagrees with check")
    else
      (if r == "?" then s!"{ps.name} ERROR diag disagrees with check" else s!"{ps.name} REJECT {r}")

/-- Process all lines; returns the output lines. -/
def run (lines : List String) : List String := Id.run do
  let mut out : Array String := #[]
  let mut ps : PS := {}
  let mut bad : Option String := none
  for raw in lines do
    let ws := (raw.trimAscii.toString.splitOn " ").filter (· ≠ "")
    if ws.isEmpty || (ws.head!.startsWith "#") then continue
    match ws with
    | ["prog", name, n, params] =>
      match nat n, parseParams params with
      | .ok n, .ok pr => ps := { name := name, n := n, params := pr }; bad := none
      | _, _ => ps := { name := name }; bad := some "bad prog header"
    | ["endprog"] =>
      match bad with
      | some m => out := out.push s!"{ps.name} ERROR {m}"
      | none => out := out.push (finish ps)
      ps := {}
      bad := none
    | _ =>
      if bad.isNone then
        match instr ps ws with
        | .ok ps' => ps := ps'
        | .error m => bad := some m
  return out.toList

end Orin.Exec

open Orin.Exec in
def main (args : List String) : IO UInt32 := do
  let text ← match args with
    | [path] => IO.FS.readFile path
    | _ => do
      let stdin ← IO.getStdin
      stdin.readToEnd
  for l in run (text.splitOn "\n") do
    IO.println l
  return 0
