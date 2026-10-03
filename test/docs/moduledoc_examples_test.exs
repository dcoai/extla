defmodule ExTLA.ModuledocExamplesTest do
  @moduledoc """
  Every `defmodule` example in a `lib/` moduledoc compiles (#301, for #171).

  ## Why this exists

  #171 proved the gap the hard way: the example at the top of `ExTLA.Invariant` — the first
  thing a reader copies — did not compile, and had not for as long as it had existed.
  Nothing was looking. The guide harness globs `guides/`, `spec/` and `README.md` (#281);
  doctests cover six modules; the options gate parses option lines rather than code. A
  `defmodule` in a moduledoc was checked by nothing at all.

  It found a second one immediately, which is the better argument for it than the first:
  #300 fixed the `init/1` injection for Layer 1 and left `use ExTLA.GenServer` — where the
  same defect is **unconditional** — so `ExTLA.GenServer`'s own front-page example was still
  broken after the fix that was supposed to close it. A gate that catches the thing the
  previous work item missed is worth more than one that confirms it.

  ## The annotation problem, and why there is no annotation

  `ExTLA.GuideCheck` carries its claims in `<!-- tla:… -->` comments, which markdown renderers
  drop. A moduledoc has nowhere to put one: an HTML comment renders as text in ExDoc, and a
  comment inside the example renders as part of the example.

  So the rule is the default rather than a mark: **a `defmodule … end` in a doc string is
  compiled.** The exceptions are listed here, each with a reason, and the failure mode of
  forgetting to add one is a red build rather than a silent pass — which is the direction an
  exception list has to fail in to be allowed at all.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # A doc example that cannot be compiled here, and why. The reason is the whole content of
  # the entry: "we could not compile it" is what an unannotated block already says.
  @skip %{
    "lib/ex_tla/invariant/test.ex" =>
      "an ExUnit.Case module — compiling one outside a running ExUnit raises, and it is " <>
        "the reader's suite that runs it, not this gate"
  }

  describe "every defmodule example in a lib/ moduledoc" do
    test "compiles" do
      failures =
        for {path, line, code} <- examples(),
            not Map.has_key?(@skip, path),
            {:error, why} <- [compile(code, "#{path}:#{line}")],
            do: "#{path}:#{line} — #{why}"

      assert failures == [], """
      #{length(failures)} moduledoc example(s) do not compile:

        #{Enum.join(failures, "\n  ")}

      These are the first thing a reader copies. If an example cannot be compiled here —
      an ExUnit module, a fragment, something needing a running system — add it to `@skip`
      in this file with the reason, which is a different statement from leaving it
      unchecked.
      """
    end

    # Anti-vacuity, and this gate needs it more than most: `examples/0` finds blocks by
    # indentation inside doc strings, so a change to how the docs are written could silently
    # yield nothing and this file would report green having compiled no example at all.
    test "and there are examples to compile" do
      found = examples()

      assert length(found) >= 6, "only #{length(found)} doc examples found; the reader is wrong"

      paths = found |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      assert "lib/ex_tla/invariant.ex" in paths
      assert "lib/ex_tla/gen_server.ex" in paths
      assert "lib/ex_tla/spec.ex" in paths
    end

    # An entry that names a file with no example is an exception for nothing, which is how
    # a skip list rots into a list of names nobody rechecks.
    test "and every skip names a file that has one" do
      with_examples = examples() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      stale = for path <- Map.keys(@skip), not MapSet.member?(with_examples, path), do: path

      assert stale == [], "these @skip entries name no doc example: #{Enum.join(stale, ", ")}"
    end
  end

  # ── Reading them ────────────────────────────────────────────────────────────

  # An indented `defmodule X do` inside a doc string, to its closing `end` at the same
  # indentation. Indentation rather than the AST because a doc string is a literal: the
  # example is text until something compiles it, which is the point of this file.
  defp examples do
    for path <- @root |> Path.join("lib/**/*.ex") |> Path.wildcard(),
        {line, code} <- blocks(File.read!(path)),
        do: {Path.relative_to(path, @root), line, code}
  end

  defp blocks(source) do
    lines = String.split(source, "\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _i} -> Regex.match?(~r/^\s{4,}defmodule \S+ do\s*$/, line) end)
    |> Enum.map(fn {line, i} ->
      [_match, indent] = Regex.run(~r/^(\s{4,})defmodule/, line)

      body =
        lines
        |> Enum.drop(i)
        |> Enum.reduce_while([], fn l, acc ->
          if l == indent <> "end",
            do: {:halt, Enum.reverse([l | acc])},
            else: {:cont, [l | acc]}
        end)

      {i + 1, body |> Enum.map_join("\n", &String.replace_prefix(&1, indent, ""))}
    end)
  end

  # In its own process, observing the exit — the shape `ExTLA.GuideCheck.isolated/1` and
  # `ExTLA.Ledger.check/2` both use. A `rescue` would hide a bug in this gate among the
  # failures it is reporting, and CLAUDE.md forbids it outright.
  #
  # The spawn buys isolation of the *caller*, and nothing more. This used to set
  # `Code.put_compiler_option(:ignore_module_conflict, true)` inside the child, under a
  # comment of mine claiming that kept a compiler-global out of the test process. It did
  # not — measured, the parent reads the child's write straight back, and this file is
  # `async: true`, so the whole suite ran with module-conflict warnings suppressed for as
  # long as it took to compile the examples (#322).
  #
  # The option was only ever there for noise: two examples may define the same module name,
  # and redefinition *warns*, it does not fail. `Code.with_diagnostics/1` collects those
  # warnings instead of printing them, and its handler is scoped to this process — which is
  # the behaviour that was wanted, reached without the global.
  defp compile(code, where) do
    parent = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        Code.with_diagnostics(fn -> Code.compile_string(code, where) end)
        send(parent, {:compiled, self()})
      end)

    receive do
      {:compiled, _pid} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, describe(reason)}
    after
      30_000 -> {:error, "timed out after 30s"}
    end
  end

  defp describe({%{__struct__: _} = exception, _stacktrace}),
    do: exception |> Exception.message() |> String.split("\n") |> hd()

  defp describe(reason), do: reason |> inspect() |> String.slice(0, 200)
end
