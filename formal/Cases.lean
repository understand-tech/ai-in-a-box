import Rotation

open Rotation

def Rotation.Pw.json : Pw → String
  | .old => "old"
  | .new => "new"

def Rotation.LocalEnv.json : LocalEnv → String
  | .holds pw => pw.json
  | .empty => "empty"

def Rotation.Outcome.json : Outcome → String
  | .settled => "settled"
  | .stopped => "stopped"

def main : IO Unit :=
  for (name, path) in paths do
    for k in List.range (path.length + 1) do
      let (outcome, s) := recover (crashAt path k)
      IO.println s!"{name} {k} {outcome.json} {s.db.json} {s.localEnv.json} {s.record}"
