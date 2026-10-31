import Settings

open Settings

def Settings.Key.label : Key → String
  | .operatorOnly => "a setting only the operator has"
  | .operatorDiffers => "a setting the operator changed"
  | .sameAsRelease => "a setting equal to the release's"
  | .releaseDecides => "an image the release decides"
  | .logLevel => "LOG_LEVEL=DEBUG main shipped"

def Settings.Event.label : Event → String
  | .copyBefore => "keeping the old file as env.before-split"
  | .createLocal => "creating local.env"
  | .appendLine (key, _) => s!"carrying over {key.label}"
  | .writeLocal _ => "writing local.env"
  | .renderEnv => "rendering .env"

def lost (s : State) : List Key := keys.filter fun key => effective s.localEnv key != expected key

def rows : List (String × Bool) :=
  (List.range (migration.length + 1)).map fun k =>
    let cut := match migration[k]? with
      | some e => s!"cut while {e.label}"
      | none => "no cut"
    let after := nextRun (crashAt k)
    let missing := lost after
    if missing.isEmpty then (s!"| ✅ | {cut} | every setting as expected |", true)
    else (s!"| ❌ | {cut} | lost: {", ".intercalate (missing.map Key.label)} |", false)

def main : IO UInt32 := do
  IO.println "### Settings migrated from main: every cut, then the next run\n"
  IO.println "| | Cut | After the next run |"
  IO.println "|---|---|---|"
  for (line, _) in rows do IO.println line
  return if rows.all (·.2) then 0 else 1
