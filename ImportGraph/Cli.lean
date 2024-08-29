/-
Copyright (c) 2023 Kim Morrison. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Kim Morrison
-/
import Cli.Basic
import Batteries.Lean.IO.Process
import ImportGraph.CurrentModule
import ImportGraph.Imports
import ImportGraph.Lean.Name
import ImportGraph.Unused

open Cli

open Lean
open ImportGraph

/--
Write an import graph, represented as a `NameMap (Array Name)` to the ".dot" graph format.
* Nodes in the `unused` set will be shaded light gray.
* Nodes which start with the `markedModule` and edges into them will be highlighted in green.
-/
def asDotGraph
    (graph : NameMap (Array Name))
    (unused : NameSet := {})
    (header := "import_graph")
    (markedModule : Option Name := none) :
    String := Id.run do

  let mut lines := #[s!"digraph \"{header}\" " ++ "{"]
  for (n, is) in graph do
    if unused.contains n then
      lines := lines.push s!"  \"{n}\" [style=filled, fillcolor=\"#e0e0e0\"];"
    else if isInModule markedModule n then
      -- mark node
      lines := lines.push s!"  \"{n}\" [style=filled, fillcolor=\"#96ec5b\"];"
    else
      lines := lines.push s!"  \"{n}\";"
    -- Then add edges
    for i in is do
      if isInModule markedModule n then
        if isInModule markedModule i then
          -- draw the main project close together
          lines := lines.push s!"  \"{i}\" -> \"{n}\" [weight=100];"
        else
          -- mark edges into the main project
          lines := lines.push s!"  \"{i}\" -> \"{n}\" [penwidth=4, color=\"#71b144\"];"
      else
        lines := lines.push s!"  \"{i}\" -> \"{n}\";"
  lines := lines.push "}"
  return "\n".intercalate lines.toList

open Lean Core System

open IO.FS IO.Process Name in
/-- Implementation of the import graph command line program. -/
def importGraphCLI (args : Cli.Parsed) : IO UInt32 := do
  let to ← match args.flag? "to" with
  | some to => pure <| to.as! ModuleName
  | none => getCurrentModule
  let from? := match args.flag? "from" with
  | some fr => some <| fr.as! ModuleName
  | none => none
  searchPathRef.set compile_time_search_path%
  let dotFile ← try unsafe withImportModules #[{module := to}] {} (trustLevel := 1024) fun env => do
    let p := ImportGraph.getModule to
    let mut graph := env.importGraph
    let unused ←
      match args.flag? "to"  with
      | some _ =>
        let ctx := { options := {}, fileName := "<input>", fileMap := default }
        let state := { env }
        let used ← Prod.fst <$> (CoreM.toIO (env.transitivelyRequiredModules to) ctx state)
        pure <| graph.fold (fun acc n _ => if used.contains n then acc else acc.insert n) NameSet.empty
      | none => pure NameSet.empty
    if let Option.some f := from? then
      graph := graph.downstreamOf (NameSet.empty.insert f)
    if ¬(args.hasFlag "include-deps") then
      graph := graph.filterMap (fun n i =>
        if p.isPrefixOf n then (i.filter (isPrefixOf p)) else none)
    if args.hasFlag "exclude-meta" then
      -- Mathlib-specific exclusion of tactics
      let filterMathlibMeta : Name → Bool := fun n => (
        isPrefixOf `Mathlib.Tactic n ∨
        isPrefixOf `Mathlib.Lean n ∨
        isPrefixOf `Mathlib.Mathport n ∨
        isPrefixOf `Mathlib.Util n)
      graph := graph.filterGraph filterMathlibMeta (replacement := `«Mathlib.Tactics»)
    if args.hasFlag "reduce" then
      graph := graph.transitiveReduction

    let markedModule : Option Name := if args.hasFlag "mark-module" then p else none

    return asDotGraph graph (unused := unused) (markedModule := markedModule)
  catch err =>
    -- TODO: try to build `to` first, so this doesn't happen
    throw <| IO.userError <| s!"{err}\nIf the error above says `unknown package`, " ++
      s!"try if `lake build {to}` fixes the issue"
    throw err

  match args.variableArgsAs! String with
  | #[] => writeFile "import_graph.dot" dotFile
  | outputs => for o in outputs do
     let fp : FilePath := o
     match fp.extension with
     | none
     | "dot" => writeFile fp dotFile
     | some ext => try
        _ ← runCmdWithInput "dot" #["-T" ++ ext, "-o", o] dotFile
      catch ex =>
        IO.eprintln s!"Error occurred while writing out {fp}."
        IO.eprintln s!"Make sure you have `graphviz` installed and the file is writable."
        throw ex
  return 0
