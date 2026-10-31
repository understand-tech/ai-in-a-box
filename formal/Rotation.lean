namespace Rotation

inductive Pw | old | new
deriving DecidableEq, Repr

inductive LocalEnv | holds (pw : Pw) | empty
deriving DecidableEq, Repr

inductive Outcome | settled | stopped
deriving DecidableEq, Repr

structure State where
  db : Pw
  localEnv : LocalEnv
  record : Bool
deriving DecidableEq, Repr

inductive Event
  | createRecord
  | syncRecord
  | changeDb (to : Pw)
  | attemptChange
  | writeLocal (pw : Pw)
  | writeEnv
  | removeRecord
deriving DecidableEq, Repr

def apply (s : State) : Event → State
  | .createRecord => { s with record := true }
  | .changeDb to => { s with db := to }
  | .writeLocal pw => { s with localEnv := .holds pw }
  | .removeRecord => { s with record := false }
  | .syncRecord | .attemptChange | .writeEnv => s

def initial : State := ⟨.old, .holds .old, false⟩

-- A cut before step k leaves the steps before it done and nothing of step k:
-- local.env and .env are replaced by renaming a synced copy over them.
def crashAt (path : List Event) (k : Nat) : State :=
  (path.take k).foldl apply initial

def recover (s : State) : Outcome × State :=
  if !s.record then (.settled, s)
  else match s.localEnv with
    | .empty => (.stopped, s)
    | .holds _ => (.settled, { s with localEnv := .holds s.db, record := false })

def good : Outcome × State → Bool
  | (.settled, s) => !s.record && s.localEnv == .holds s.db
  | (.stopped, s) => s.record && s.localEnv != .empty

def succeeds : List Event :=
  [.createRecord, .syncRecord, .changeDb .new, .writeLocal .new, .writeEnv, .removeRecord]

def servicesDoNotComeBack : List Event :=
  [.createRecord, .syncRecord, .changeDb .new, .writeLocal .new, .writeEnv,
   .changeDb .old, .writeLocal .old, .writeEnv, .removeRecord]

def changeIsRefused : List Event :=
  [.createRecord, .syncRecord, .attemptChange, .writeLocal .old, .writeEnv, .removeRecord]

def paths : List (String × List Event) :=
  [("succeeds", succeeds), ("services_do_not_come_back", servicesDoNotComeBack),
   ("change_is_refused", changeIsRefused)]

def everyCutIsRecovered : Bool :=
  paths.all fun (_, path) => (List.range (path.length + 1)).all fun k => good (recover (crashAt path k))

end Rotation
