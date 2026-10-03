defmodule Mix.Tasks.Tla.Stamp do
  @shortdoc "Report or update `spec_version:` stamps on refinement mappings"

  @moduledoc """
  Report the state of every `spec_version:` stamp, and update the stale ones.

      mix tla.stamp             # report every mapping's stamp
      mix tla.stamp --check     # report, and exit 1 if a stamp is unverified
      mix tla.stamp --restamp   # rewrite stale stamps in source

  ## It reads source, and that is not an implementation detail

  A stale stamp is a **compile error** — that is the point of it. So a task that needed the
  project to compile before it could report or fix a stale stamp would be unusable in exactly
  the situation it exists for. This reads `.ex` files directly and loads nothing.

  ## What `--restamp` is for, and what it is not

  A stale stamp means the spec a mapping was written against has changed. The work that
  resolves it is **re-reading the mapping** — confirming each variable and action it names
  still means what it did — and only then recording that you have.

  `--restamp` performs the recording. It cannot perform the judgement, and it is deliberately a
  separate command rather than a suggestion inside the compile error: an error message offering
  a one-key fix trains people to take the fix, and a stamp applied without reading is worse
  than no stamp, because it manufactures assurance.

  Run it after the review, never instead of it.

  ## What `--check` fails on, and why it is not a CI job

  One question: **is this stamp verified by something?**

      :fresh                              yes, by this task
      :stale                              no -- it is checked, and it is WRONG
      :unstamped                          there is no stamp; the mechanism is opt-in
      :unverifiable, spec not on disk     no. Nothing verifies it
      :unverifiable, spec: not an alias   yes, by the COMPILER

  `--check` exits **1** on the two that answer no, and 0 on the rest.

  The last row is the one worth stating, because it looks like a finding and is not. A
  `spec:` given as `@an_attribute` cannot be resolved by a task that reads source without
  compiling — but `use ExTLA.GenServer` has the attribute's *value* at expansion, so the
  compile-time check verifies that stamp completely. Measured: a mapping with an attribute
  `spec:` and a wrong stamp raises `ExTLA.Spec.CompileError` exactly as a literal one does.
  Failing a build on it would be a false finding about a mapping that is fully checked.

  **And there is deliberately no CI job for this task.** A stale stamp is already a compile
  error, and a spec whose source is not on disk already emits a compile warning — so on any
  project whose CI compiles with `--warnings-as-errors`, both failures arrive from the
  `compile` job, earlier and with better messages. A job here would add a second way to
  learn the same thing and two places to keep in step (D-37).

  `--check` is for the workflow the compiler cannot serve: the project **does not compile**,
  and a script wants the list of mappings to re-read rather than one error at a time. That
  is the situation this task was built for, and the exit code is what lets a script act on
  it.

  ## Exit codes

      0  every stamp is verified by something, or `--check` was not given
      1  with `--check`: a stamp is stale, or its spec's source is not on disk,
         so nothing verifies it. Without `--check` the report is a report
  """

  use Mix.Task

  alias ExTLA.Spec.Hash

  @switches [check: :boolean, restamp: :boolean]

  # A stamp that is wrong, or that nothing verifies. See the moduledoc; D-37 has the
  # reasoning, including why `:unstamped` and an attribute `spec:` are not here.
  defp unverified?(%{status: :stale}), do: true
  defp unverified?(%{status: :unverifiable, reason: :spec_source_not_found}), do: true
  defp unverified?(_state), do: false

  @impl Mix.Task
  def run(argv), do: run(argv, roots())

  @doc false
  # The roots are an argument so a test can point the whole task at a fixture tree (#308).
  # `:stale` and `:unverifiable` cannot be produced by this project's own sources -- a
  # genuinely stale stamp in `lib/` would redden the stamp check for everyone, which is why
  # none exists -- so the only way to exercise them is a tree outside the ones scanned here.
  # A `--root` flag would be surface added for a test; this is a seam, said to be one.
  def run(argv, roots) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    stamps = states(roots)

    if opts[:restamp] do
      restamp(stamps)
    else
      report(stamps)
      if opts[:check], do: check(stamps), else: :ok
    end
  end

  defp check(stamps) do
    case Enum.filter(stamps, &unverified?/1) do
      [] ->
        :ok

      unverified ->
        Mix.shell().info(
          "\n#{length(unverified)} stamp(s) are not verified by anything: " <>
            "#{unverified |> Enum.map_join(", ", &inspect(&1.module))}."
        )

        exit({:shutdown, 1})
    end
  end

  @doc """
  Every mapping's stamp state: `%{module, spec, stamp, current, status, path}`.

  `status` is `:fresh`, `:stale`, `:unstamped` or `:unverifiable`. Read from source, so this
  answers even when a stale stamp is stopping the project from compiling.
  """
  def states(roots \\ roots()) do
    index = module_index(roots)

    index
    |> mappings()
    |> Enum.map(&state(&1, index))
    |> Enum.sort_by(& &1.module)
  end

  @doc """
  The directories this scans: the project's own `elixirc_paths`, and `lib` as a floor.

  It used to append `["lib", "test", "ledger"]` unconditionally. `ledger` is a directory of
  THIS repository, and a consumer running `mix tla.stamp` got it scanned along with their
  whole `test` tree -- a library reaching for directory names that are not its business.
  `elixirc_paths` is the project's own answer to "where is my code", and for this repository
  it already names `ledger` and the compiled test trees, so nothing is lost by asking it.
  """
  def roots do
    Mix.Project.config()
    |> Keyword.get(:elixirc_paths, ["lib"])
    |> Kernel.++(["lib"])
    |> Enum.uniq()
  end

  @doc "Every `.ex` file under `roots`."
  def sources(roots \\ roots()) do
    roots
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.uniq()
  end

  @doc "A `module => source path` index built by parsing `defmodule` declarations."
  def module_index(roots \\ roots()) do
    for path <- sources(roots),
        module <- modules_in(File.read!(path)),
        into: %{},
        do: {module, path}
  end

  defp modules_in(source) do
    source
    |> Code.string_to_quoted!()
    |> collect_modules([])
  end

  defp collect_modules({:defmodule, _, [{:__aliases__, _, segs}, [do: body]]}, prefix) do
    here = prefix ++ segs
    [Module.concat(here) | collect_modules(body, here)]
  end

  defp collect_modules({:__block__, _, nodes}, prefix),
    do: Enum.flat_map(nodes, &collect_modules(&1, prefix))

  defp collect_modules(nodes, prefix) when is_list(nodes),
    do: Enum.flat_map(nodes, &collect_modules(&1, prefix))

  defp collect_modules(_other, _prefix), do: []

  @doc "Every `use ExTLA.GenServer` site, as `%{module, spec, stamp, path}`."
  def mappings(index) do
    index
    |> Map.values()
    |> Enum.uniq()
    |> Enum.flat_map(fn path -> path |> File.read!() |> uses(path, []) end)
  end

  defp uses({:defmodule, _, [{:__aliases__, _, segs}, [do: body]]}, path, prefix) do
    here = prefix ++ segs

    own =
      body |> use_opts() |> Enum.map(&Map.merge(&1, %{module: Module.concat(here), path: path}))

    own ++ uses(body, path, here)
  end

  defp uses({:__block__, _, nodes}, path, prefix),
    do: Enum.flat_map(nodes, &uses(&1, path, prefix))

  defp uses(nodes, path, prefix) when is_list(nodes),
    do: Enum.flat_map(nodes, &uses(&1, path, prefix))

  defp uses(source, path, prefix) when is_binary(source),
    do: source |> Code.string_to_quoted!() |> uses(path, prefix)

  defp uses(_other, _path, _prefix), do: []

  # Only THIS module's own `use`, never a nested module's — the recursion visits those with
  # their own name, and counting them twice would report one mapping under two modules.
  defp use_opts(body) do
    body
    |> List.wrap()
    |> then(fn
      [{:__block__, _, nodes}] -> nodes
      nodes -> nodes
    end)
    |> Enum.flat_map(fn
      {:use, _, [{:__aliases__, _, [:ExTLA, :GenServer]}, opts]} when is_list(opts) ->
        [%{spec: spec_of(opts), stamp: Keyword.get(opts, :spec_version)}]

      _ ->
        []
    end)
  end

  # A `spec:` that is not a literal alias -- `@spec_module`, a variable, anything the AST
  # does not name outright -- cannot be resolved without compiling, which this task
  # deliberately does not do (a stale stamp means the project may not compile).
  #
  # It used to be `nil` and the whole mapping was then REJECTED (#173), so the task could go
  # on to say "no refinement mappings found" about a file it had read and could not
  # understand. That collapses *cannot be checked* into *absent*, which is the one thing the
  # four-status design exists to prevent. It is `:unresolvable` now and reaches `state/2`.
  defp spec_of(opts) do
    case Keyword.get(opts, :spec) do
      {:__aliases__, _, segs} -> Module.concat(segs)
      _ -> :unresolvable
    end
  end

  defp state(%{spec: :unresolvable} = mapping, _index) do
    Map.merge(mapping, %{current: nil, status: :unverifiable, reason: :spec_not_a_literal_alias})
  end

  defp state(mapping, index) do
    current = current_version(mapping.spec, index)

    status =
      cond do
        # Four states, four different facts. Folding `unverifiable` into `unstamped` would
        # report a stamp that cannot be checked as an absence; folding it into `fresh` would
        # report it as verified.
        current == nil -> :unverifiable
        mapping.stamp == nil -> :unstamped
        mapping.stamp == current -> :fresh
        true -> :stale
      end

    reason = if status == :unverifiable, do: :spec_source_not_found

    Map.merge(mapping, %{current: current, status: status, reason: reason})
  end

  # The one formula, from `ExTLA.Spec.Hash` — this used to re-derive it from `Hash.scan/2`, so
  # widening what the version covers (#194) in one place would have made every stamp stale in
  # the other. A version the compile-time check and this task compute differently is not a
  # version.
  defp current_version(spec, index) do
    case Map.get(index, spec) do
      path when is_binary(path) -> Hash.module_version(File.read!(path), spec)
      nil -> nil
    end
  end

  defp report(stamps) do
    shell = Mix.shell()

    if stamps == [] do
      shell.info("no refinement mappings found.")
    else
      Enum.each(stamps, fn s ->
        shell.info("#{pad(s.status)} #{inspect(s.module)} → #{inspect(s.spec)} #{detail(s)}")
      end)

      stale = Enum.count(stamps, &(&1.status == :stale))

      if stale > 0 do
        shell.info(
          "\n#{stale} stale. Re-read each mapping against its spec, then: mix tla.stamp --restamp"
        )
      end
    end
  end

  defp pad(status), do: status |> to_string() |> String.pad_trailing(13)

  defp detail(%{status: :stale} = s), do: "#{s.stamp} → #{s.current}"
  defp detail(%{status: :fresh} = s), do: s.current

  # Two ways to be unverifiable, and they call for different fixes: one is a missing file,
  # the other is a `spec:` this task cannot read. Saying only "unverifiable" would send a
  # reader looking for the wrong thing.
  defp detail(%{status: :unverifiable, reason: :spec_not_a_literal_alias}),
    do: "(spec: is not a literal alias, so it cannot be resolved without compiling)"

  defp detail(%{status: :unverifiable}), do: "(spec source not found)"
  defp detail(_), do: ""

  # ONE REWRITE PER `{path, stamp}`, not one per mapping (#173).
  #
  # `rewrite!/1` uses `String.replace/3`, which replaces every occurrence by design -- and
  # two mappings in one file sharing a stale stamp is the NORMAL case, since they share a
  # spec and therefore a resolution. The first call fixed both and the second found nothing,
  # so `Mix.raise` fired: it told the user to hand-edit something already done, and aborted
  # before any other file was processed.
  #
  # The guard is not weakened. It still catches a stamp that genuinely is not there, which
  # is a real fault and the only thing it was ever for.
  @doc false
  # Public for the same reason `run/2` and `switches/0` are: a test seam, said to be one.
  # Two properties here are only reachable with a hand-built list of states — the guard on a
  # stamp that is not in the file, and the refusal to rewrite a group whose members resolve
  # to different versions. Both are safety properties of a tool that edits source, and
  # neither can be produced by a fixture tree.
  def restamp(stamps) do
    shell = Mix.shell()
    stale = Enum.filter(stamps, &(&1.status == :stale))

    if stale == [] do
      shell.info("nothing to restamp.")
    else
      stale
      |> Enum.group_by(&{&1.path, &1.stamp})
      |> Enum.sort_by(fn {key, _group} -> key end)
      |> Enum.each(fn {_key, group} -> rewrite_group!(group, shell) end)
    end
  end

  defp rewrite_group!([first | _] = group, shell) do
    # Every mapping in the group shares a file and a stamp, so one rewrite serves them all --
    # unless they resolve to DIFFERENT current hashes, which needs an 8-hex collision between
    # two specs in one file. Astronomically unlikely and not silently wrong: rewriting the
    # group to one of the two would put a stamp on a mapping that was never read against it,
    # which is the one thing `--restamp` must not do.
    case group |> Enum.map(& &1.current) |> Enum.uniq() do
      [_one] ->
        rewrite!(first)

        Enum.each(group, fn s ->
          shell.info("restamped #{inspect(s.module)}: #{s.stamp} → #{s.current}")
        end)

      many ->
        Mix.raise(
          "#{first.path} has #{length(group)} mappings stamped #{first.stamp} that resolve to " <>
            "different versions (#{Enum.join(many, ", ")}) — two specs share an 8-hex stamp " <>
            "here. Edit them by hand: rewriting them together would stamp a mapping against " <>
            "a spec nobody read it against."
        )
    end
  end

  # Replace the exact `spec_version: "<old>"` this mapping carries, everywhere in the file.
  defp rewrite!(s) do
    source = File.read!(s.path)
    from = ~s(spec_version: "#{s.stamp}")

    unless String.contains?(source, from) do
      Mix.raise("#{s.path} does not contain #{from} — edit #{inspect(s.module)}'s stamp by hand.")
    end

    File.write!(s.path, String.replace(source, from, ~s(spec_version: "#{s.current}")))
  end

  @doc false
  # Exposed for `ExTLA.SpecOptionsTest`, which holds this and the specification's documented
  # option list to each other (#163). `tla.check` gained this at #134 and nothing else did, so
  # for six work items its section was the only flag list in the spec that stayed correct.
  def switches, do: @switches
end
