namespace Settings

-- One key of each kind main's .env holds, against what the release ships.
inductive Key
  | operatorOnly
  | operatorDiffers
  | sameAsRelease
  | releaseDecides
  | logLevel
deriving DecidableEq, Repr

abbrev Line := Key × String

def release : List Line :=
  [(.operatorDiffers, "release"), (.sameAsRelease, "release"),
   (.releaseDecides, "release"), (.logLevel, "INFO")]

def mainEnv : List Line :=
  [(.operatorOnly, "mine"), (.operatorDiffers, "mine"), (.sameAsRelease, "release"),
   (.releaseDecides, "main's"), (.logLevel, "DEBUG")]

def keptByMigration : Line → Bool
  | (.sameAsRelease, _) | (.releaseDecides, _) | (.logLevel, "DEBUG") => false
  | line => !release.contains line

def migrated : List Line := mainEnv.filter keptByMigration

structure State where
  localEnv : List Line
deriving Repr

inductive Event
  | copyBefore
  | writeLocal (lines : List Line)
  | renderEnv
deriving Repr

def apply (s : State) : Event → State
  | .writeLocal lines => { localEnv := lines }
  | .copyBefore | .renderEnv => s

def migration : List Event :=
  [.copyBefore, .writeLocal migrated, .renderEnv]

def initial : State := ⟨[]⟩

-- A cut before step k leaves the steps before it done and nothing of step k:
-- the split writes local.env in one rename.
def crashAt (k : Nat) : State := (migration.take k).foldl apply initial

-- The next run migrates again only while local.env is empty.
def nextRun (s : State) : State :=
  if s.localEnv.isEmpty then migration.foldl apply s else s

def effective (localEnv : List Line) (key : Key) : Option String :=
  match localEnv.reverse.find? (·.1 == key) with
  | some (_, value) => some value
  | none => (release.find? (·.1 == key)).map (·.2)

def keys : List Key := [.operatorOnly, .operatorDiffers, .sameAsRelease, .releaseDecides, .logLevel]

def expected : Key → Option String := effective migrated

def settled (s : State) : Bool := keys.all fun key => effective s.localEnv key == expected key

def everyCutKeepsTheOperatorsSettings : Bool :=
  (List.range (migration.length + 1)).all fun k => settled (nextRun (crashAt k))

end Settings
