import Orin.Top

/-!
# Examples: the checker accepts the intended ownership patterns and rejects the classic mistakes

All by kernel evaluation (`decide`), so they also document the concrete syntax of the model.
-/

namespace Orin

open Code in
/-- `fn f(p: borrowed) { let b = p.0; let o = dup b; release o }` -/
def exBorrowDup : Prog :=
  { n := 3, params := [true],
    code := .op (.getField 1 0 0 true) (.op (.dup 2 1) (.op (.release 2) .nil)) }

/-- build `S(inner)`, copy-on-write update through `make_unique`, release both -/
def exCow : Prog :=
  { n := 5, params := [],
    code :=
      .op (.alloc 0 0) <|
      Code.structNew 1 [0] <|
      .op (.dup 2 1) <|
      .op (.makeUnique 2) <|
      .op (.alloc 3 0) <|
      .op (.setField 2 0 3) <|
      .op (.release 1) <|
      .op (.release 2) .nil }

/-- the take/put protocol on a unique object -/
def exTakePut : Prog :=
  { n := 4, params := [],
    code :=
      .op (.alloc 0 0) <|
      Code.structNew 1 [0] <|
      .op (.takeField 2 1 0) <|
      .op (.makeUnique 2) <|
      .op (.putField 1 0 2) <|
      .op (.release 1) .nil }

/-- an `if` whose branches agree -/
def exIf : Prog :=
  { n := 3, params := [false],
    code :=
      .op (.alloc 1 0) <|
      .ite 0 (.op (.release 1) .nil) (.op (.release 1) .nil) .nil }

/-- double release -/
def badDoubleRelease : Prog :=
  { n := 1, params := [], code := .op (.alloc 0 0) (.op (.release 0) (.op (.release 0) .nil)) }

/-- in-place store into an object that was duplicated (not unique) -/
def badSharedStore : Prog :=
  { n := 3, params := [],
    code := .op (.alloc 0 0) <| .op (.dup 1 0) <| .op (.alloc 2 0) <|
      .op (.setField 0 0 2) .nil }

/-- use of a borrowed alias after its root was released -/
def badBorrowAfterRelease : Prog :=
  { n := 4, params := [],
    code := .op (.alloc 0 1) <| .op (.alloc 1 0) <| .op (.setField 0 0 1) <|
      .op (.getField 2 0 0 true) <| .op (.release 0) <| .op (.dup 3 2) .nil }

/-- releasing a parameter -/
def badReleaseParam : Prog :=
  { n := 1, params := [true], code := .op (.release 0) .nil }

/-- `if` branches disagreeing about a local that is used afterwards -/
def badJoin : Prog :=
  { n := 3, params := [false],
    code :=
      .op (.alloc 1 0) <|
      .ite 0 (.op (.release 1) .nil) .nil <|
      .op (.release 1) .nil }

example : check exBorrowDup = true := by decide
example : check exCow = true := by decide
example : check exTakePut = true := by decide
example : check exIf = true := by decide
example : check badDoubleRelease = false := by decide
example : check badSharedStore = false := by decide
example : check badBorrowAfterRelease = false := by decide
example : check badReleaseParam = false := by decide
example : check badJoin = false := by decide

end Orin
