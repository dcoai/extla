defmodule ExTLA.Examples do
  @moduledoc """
  The differential corpus entries that `07-examples.md` publishes, generated **from the
  page** (#280).

  ## The claim that stopped being true

  Three corpus moduledocs said "`spec/07-examples.md` Example N verbatim, which is the
  point: the corpus checks the documentation, not a paraphrase of it." `git log` dates that
  claim to 2026-08-30/31 and D-21 (`33dc7bf`) to **forty-three minutes later**: it rewrote
  every corpus spec's types — `set(^processes)` for a bare `:set`, a record union for
  `messages` — and left the page alone. The claim was true for about a day, and the page a
  reader copies from has been wrong since.

  Nothing could have caught it. Two files said the same thing by discipline, and discipline
  is what D-21 spent in the forty-three minutes.

  ## The direction of generation

  The page is the source; `test/differential/<entry>/spec.ex` is the artifact. That is the
  inverse of the five `surface-drift` goldens, which render a document from code — but it
  is the same guarantee, and D-32's reasoning applies unchanged: an enumeration kept by
  hand does not announce that it has stopped being true, so it is generated and
  byte-compared. Here what is enumerated is the specification itself.

  Compiling the fence in place — the guide harness's "the block in the markdown IS the
  source" — would be purer still, and it is what #281 should revisit when it brings all of
  `spec/` under that harness. It cannot be done in this work item without taking three
  specs out of `TLA_COVERAGE.md`: the ledger finds specs through
  `:application.get_key(:modules)` and their items through `ExTLA.Spec.Hash.item_versions/1`,
  which reads the file the BEAM records as the module's source and parses it as Elixir. A
  module compiled from a markdown string satisfies neither. A generated `.ex` satisfies
  both, and the drift gate makes it as true as the fence.

  ## What the generator changes, and why each change is not drift

  The fence shows what a reader should write; the corpus needs two things a reader does
  not:

  - **The module name.** `Specs.DistributedLock` on the page, `ExTLA.Differential.*` in the
    corpus, because the corpus is a test tree and its modules are namespaced to it.
  - **`default:` on the constants.** The page shows `constant :processes`, which is what a
    reader writes — the assignment belongs to the run, not to the declaration. The corpus
    needs one anyway, because `ExTLA.Ledger` resolves constants through
    `Spec.Compiled.resolve_constants/1` and a spec with none is reported unrunnable. The
    values live in `@entries` below, and `examples_test.exs` holds them to the constants
    `differential_test.exs` passes TLC's side, so the ledger and the corpus cannot end up
    checking two different models.

  Everything else is the fence, byte for byte. A `moduledoc` is *added* rather than kept,
  because what those paragraphs said is about the corpus — what this entry adds over the
  other five — and belongs in `test/differential/README.md`, not in a page a reader is
  reading to learn the DSL.
  """

  @page "spec/07-examples.md"

  # One entry per example the corpus takes from the page. `constants` is what the generated
  # declaration gets as `default:`; `examples_test.exs` asserts it equals the constants the
  # differential entry runs against.
  @entries [
    %{
      name: "distributed_lock",
      example: 1,
      page_module: Specs.DistributedLock,
      module: ExTLA.Differential.DistributedLock,
      constants: [
        processes: quote(do: MapSet.new([:p1, :p2])),
        resources: quote(do: MapSet.new([:r1, :r2]))
      ]
    },
    %{
      name: "raft_election",
      example: 2,
      page_module: Specs.RaftElection,
      module: ExTLA.Differential.RaftElection,
      constants: [
        servers: quote(do: MapSet.new([:s1, :s2, :s3])),
        max_term: quote(do: 2)
      ]
    },
    %{
      name: "bounded_buffer",
      example: 3,
      page_module: Specs.BoundedBuffer,
      module: ExTLA.Differential.BoundedBuffer,
      constants: [
        producers: quote(do: MapSet.new([:p1, :p2])),
        consumers: quote(do: MapSet.new([:c1, :c2])),
        buffer_size: quote(do: 3),
        max_items: quote(do: 6)
      ]
    }
  ]

  @doc "Every entry this generator owns, with the path it writes."
  def entries(root \\ File.cwd!()) do
    Enum.map(@entries, fn entry ->
      Map.put(entry, :path, Path.join([root, "test/differential", entry.name, "spec.ex"]))
    end)
  end

  @doc "The page each entry is generated from."
  def page(root \\ File.cwd!()), do: Path.join(root, @page)

  @doc """
  The `.ex` source for one entry, rendered from the page's fence.
  """
  def render(entry, root \\ File.cwd!()) do
    body =
      root
      |> page()
      |> File.read!()
      |> fence!(entry.page_module)
      |> with_defaults(entry.constants)

    """
    # Generated from #{@page} Example #{entry.example} — do not edit.
    #
    # Regenerate with `mix extla.examples --write`; the `surface-drift` job fails on a
    # difference. The specification is the page's fence: editing this file is editing a
    # copy, which is the drift D-21 introduced and #280 closed.
    defmodule #{inspect(entry.module)} do
      @moduledoc \"\"\"
      `#{tla_module(entry)}.tla`, in the ExTLA DSL — generated from `#{@page}` Example
      #{entry.example}, so "verbatim" holds by construction rather than by discipline.

      What this entry adds over the others is in `test/differential/README.md`. What it
      *specifies* is the page, and only the page.
      \"\"\"
    #{body}
    end
    """
  end

  @doc """
  The fenced Elixir block defining `module`, without its `defmodule`/`end` wrapper.

  Located by the module it defines rather than by line number: a fence that moves when the
  page is edited is still the same fence, and a line number in a generator is a second
  thing to keep in step with the document.
  """
  def fence!(markdown, module) do
    opening = "defmodule #{inspect(module)} do"

    markdown
    |> String.split("\n")
    |> fences([], nil)
    |> Enum.find(&(List.first(&1) == opening))
    |> case do
      nil ->
        raise ArgumentError,
              "#{@page} has no ```elixir block defining #{inspect(module)}. The generator " <>
                "locates a fence by the module it declares, so either the module was " <>
                "renamed on the page or the example was removed."

      [^opening | rest] ->
        rest |> Enum.drop(-1) |> Enum.join("\n") |> String.trim_trailing()
    end
  end

  defp fences([], done, nil), do: Enum.reverse(done)

  defp fences([], _done, open) when is_list(open) do
    raise ArgumentError, "#{@page} ends inside an unclosed ```elixir block"
  end

  defp fences(["```elixir" | rest], done, nil), do: fences(rest, done, [])

  defp fences(["```" <> _other | rest], done, nil), do: fences(rest, done, nil)

  defp fences(["```" | rest], done, open), do: fences(rest, [Enum.reverse(open) | done], nil)

  defp fences([_line | rest], done, nil), do: fences(rest, done, nil)

  defp fences([line | rest], done, open), do: fences(rest, done, [line | open])

  # `constant :processes` → `constant :processes, default: MapSet.new([:p1, :p2])`. A name
  # the entry does not list is left alone, and a name the fence does not declare is an
  # error rather than a silent no-op: it means the page and this table disagree about what
  # the example's constants are.
  defp with_defaults(body, constants) do
    {rendered, unused} =
      body
      |> String.split("\n")
      |> Enum.map_reduce(constants, fn line, remaining ->
        case Regex.run(~r/^(\s*)constant :(\w+)$/, line) do
          [_match, indent, name] ->
            name = String.to_atom(name)

            case Keyword.fetch(remaining, name) do
              {:ok, value} ->
                {"#{indent}constant :#{name}, default: #{Macro.to_string(value)}",
                 Keyword.delete(remaining, name)}

              :error ->
                {line, remaining}
            end

          nil ->
            {line, remaining}
        end
      end)

    unless unused == [] do
      raise ArgumentError,
            "the generator has defaults for #{inspect(Keyword.keys(unused))}, which the " <>
              "page's fence does not declare as constants. The example and this table " <>
              "disagree about the model."
    end

    Enum.join(rendered, "\n")
  end

  # `ExTLA.Differential.DistributedLock` → `DistributedLock`, the TLA+ module the entry is
  # checked against.
  defp tla_module(entry), do: entry.module |> Module.split() |> List.last()
end
