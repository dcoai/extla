defmodule Mix.Tasks.Tla.Stamp do
  @shortdoc "Report or update `spec_version:` stamps on refinement mappings"

  @moduledoc """
  Report the state of every `spec_version:` stamp, and update the stale ones.

      mix tla.stamp             # report every mapping's stamp
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
  """

  use Mix.Task

  alias TLA.Spec.Hash

  @switches [restamp: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    stamps = states()

    if opts[:restamp], do: restamp(stamps), else: report(stamps)
  end

  @doc """
  Every mapping's stamp state: `%{module, spec, stamp, current, status, path}`.

  `status` is `:fresh`, `:stale`, `:unstamped` or `:unverifiable`. Read from source, so this
  answers even when a stale stamp is stopping the project from compiling.
  """
  def states do
    index = module_index()

    index
    |> mappings()
    |> Enum.map(&state(&1, index))
    |> Enum.sort_by(& &1.module)
  end

  @doc "Every `.ex` file on the project's compile paths, plus its test support trees."
  def sources do
    Mix.Project.config()
    |> Keyword.get(:elixirc_paths, ["lib"])
    |> Kernel.++(["lib", "test", "ledger"])
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
    |> Enum.uniq()
  end

  @doc "A `module => source path` index built by parsing `defmodule` declarations."
  def module_index do
    for path <- sources(),
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

  @doc "Every `use TLA.GenServer` site, as `%{module, spec, stamp, path}`."
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
      {:use, _, [{:__aliases__, _, [:TLA, :GenServer]}, opts]} when is_list(opts) ->
        [%{spec: spec_of(opts), stamp: Keyword.get(opts, :spec_version)}]

      _ ->
        []
    end)
    |> Enum.reject(&(&1.spec == nil))
  end

  defp spec_of(opts) do
    case Keyword.get(opts, :spec) do
      {:__aliases__, _, segs} -> Module.concat(segs)
      _ -> nil
    end
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

    Map.merge(mapping, %{current: current, status: status})
  end

  defp current_version(spec, index) do
    with path when is_binary(path) <- Map.get(index, spec),
         versions when versions != %{} <- Hash.scan(File.read!(path), spec) do
      versions
      |> Enum.sort()
      |> Enum.map_join("\n", fn {{kind, name}, version} -> "#{kind} #{name} #{version}" end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)
    else
      _ -> nil
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
  defp detail(%{status: :unverifiable}), do: "(spec source not found)"
  defp detail(_), do: ""

  defp restamp(stamps) do
    shell = Mix.shell()
    stale = Enum.filter(stamps, &(&1.status == :stale))

    if stale == [] do
      shell.info("nothing to restamp.")
    else
      Enum.each(stale, fn s ->
        rewrite!(s)
        shell.info("restamped #{inspect(s.module)}: #{s.stamp} → #{s.current}")
      end)
    end
  end

  # Replace only the exact `spec_version: "<old>"` this mapping carries. Two mappings in one
  # file sharing a stale stamp share a spec and a resolution, so replacing both is right;
  # anything else needs an 8-hex collision between different specs.
  defp rewrite!(s) do
    source = File.read!(s.path)
    from = ~s(spec_version: "#{s.stamp}")

    unless String.contains?(source, from) do
      Mix.raise("#{s.path} does not contain #{from} — edit #{inspect(s.module)}'s stamp by hand.")
    end

    File.write!(s.path, String.replace(source, from, ~s(spec_version: "#{s.current}")))
  end
end
