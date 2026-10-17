import Orin.CallTop

/-!
# Examples for calls

`pcheck` accepts the intended call patterns (owned argument moved into the callee and its result
returned, borrowed argument, scalar result) and rejects the classic mistakes (use after the move into
a call, an owned and a borrowed operand rooted at the same object, wrong arity, unknown callee).
-/

namespace Orin

/-- `fn idf(own x) -> own { x }` -/
def fId : Fn :=
  { params := [.owned], retRef := true, n := 1, ret := 0, code := .nil }

/-- `fn len(borrow a) -> int { array_len a }` -/
def fLen : Fn :=
  { params := [.borrowed], retRef := false, n := 2, ret := 1,
    code := .op (.arrayLen 1 0) .nil }

/-- `fn two(borrow a, own b) -> int { release b; 0 }` -/
def fTwo : Fn :=
  { params := [.borrowed, .owned], retRef := false, n := 3, ret := 2,
    code := .op (.release 1) <| .op (.const 2 0) .nil }

/-- allocate an array, ask its length through a borrow, pass it through `idf`, release it -/
def fMain : Fn :=
  { params := [], retRef := false, n := 4, ret := 3,
    code :=
      .op (.const 1 3) <| .op (.arrayNew 0 1) <|
      .call 2 2 [0] <| .call 0 1 [0] <| .op (.release 0) <| .op (.const 3 0) .nil }

/-- using the array after it was moved into the call -/
def fBadUse : Fn :=
  { params := [], retRef := false, n := 4, ret := 3,
    code :=
      .op (.const 1 3) <| .op (.arrayNew 0 1) <|
      .call 2 1 [0] <| .op (.release 0) <| .op (.const 3 0) .nil }

/-- an owned and a borrowed operand rooted at the same local -/
def fBadAlias : Fn :=
  { params := [], retRef := false, n := 4, ret := 3,
    code :=
      .op (.const 1 3) <| .op (.arrayNew 0 1) <|
      .call 2 3 [0, 0] <| .op (.const 3 0) .nil }

def fBadArity : Fn :=
  { params := [], retRef := false, n := 4, ret := 3,
    code := .op (.const 1 3) <| .op (.arrayNew 0 1) <| .call 2 2 [0, 0] <|
    .op (.release 0) <| .op (.const 3 0) .nil }

def fBadCallee : Fn :=
  { params := [], retRef := false, n := 2, ret := 1,
    code := .call 0 9 [] <| .op (.const 1 0) .nil }

/-- the result is a borrowed alias: not returnable -/
def fBadRet : Fn :=
  { params := [.borrowed], retRef := true, n := 2, ret := 1,
    code := .op (.getField 1 0 0 true) .nil }

example : pcheck [fMain, fId, fLen, fTwo] = true := by decide
example : pcheck [fBadUse, fId, fLen, fTwo] = false := by decide
example : pcheck [fBadAlias, fId, fLen, fTwo] = false := by decide
example : pcheck [fBadArity, fId, fLen, fTwo] = false := by decide
example : pcheck [fBadCallee, fId, fLen, fTwo] = false := by decide
example : pcheck [fBadRet] = false := by decide

end Orin
