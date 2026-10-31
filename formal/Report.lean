import Rotation

open Rotation

def Rotation.Pw.label : Pw → String
  | .old => "old"
  | .new => "new"

def Rotation.Event.label : Event → String
  | .createRecord => "creating the change record"
  | .syncRecord => "syncing the change record"
  | .changeDb to => s!"moving the database to the {to.label} password"
  | .attemptChange => "the database refusing the change"
  | .writeLocal pw => s!"writing the {pw.label} password to local.env"
  | .writeEnv => "rendering .env"
  | .removeRecord => "removing the change record"

def describe : Outcome × State → String
  | (.settled, s) => s!"settled on the {s.db.label} password"
  | (.stopped, s) =>
    let localEnv := if s.localEnv == .empty then "local.env empty" else "local.env intact"
    s!"stopped, {localEnv}, change record {if s.record then "kept" else "removed"}"

def rows : List (String × Bool) := Id.run do
  let mut out := []
  for (name, path) in paths do
    for k in List.range (path.length + 1) do
      let cut := match path[k]? with
        | some e => s!"cut while {e.label}"
        | none => "no cut"
      let after := recover (crashAt path k)
      let ok := good after
      out := out.concat (s!"| {if ok then "✅" else "❌"} | `{name}` | {cut} | {describe after} |", ok)
  return out

def main : IO UInt32 := do
  IO.println "### Database password rotation: every cut, then the next run\n"
  IO.println "| | Run | Cut | After the next run |"
  IO.println "|---|---|---|---|"
  for (line, _) in rows do IO.println line
  return if rows.all (·.2) then 0 else 1
