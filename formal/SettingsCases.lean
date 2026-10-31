import Settings

open Settings

def main : IO Unit :=
  for k in List.range (migration.length + 1) do
    let after := nextRun (crashAt k)
    let values := keys.map fun key => (effective after.localEnv key).getD "unset"
    IO.println s!"{k} {" ".intercalate values}"
