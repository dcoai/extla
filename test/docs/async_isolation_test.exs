defmodule TLA.AsyncIsolationTest do
  @moduledoc """
  No `async: true` test file writes VM-global state (#285).

  ## What went wrong, and how it was invisible

  `test/conformance/step_test.exs` was `async: true` and set
  `Application.put_env(:extla, :trace_buffer, 3)` to watch the buffer drop states.
  `trace_buffer` is read by `TLA.GenServer.Runtime.record_transition!/4` **in whatever
  process is recording**, so for the duration of that test every concurrently running test
  that recorded a transition saw a 3-state buffer.

  Nothing could have failed on it. A neighbour's trace was truncated, its temporal verdicts
  became `:inconclusive`, and the assertion beside it reads
  `verdict in [:holds, :inconclusive]` — which is exactly what a corrupted run still
  satisfies. That is this milestone's subject: a passing result that means nothing was
  checked, arriving here through the *config of a different test file*.

  The discipline already existed — `TLA.InvariantModesTest` and `TLA.TelemetryVerboseTest`
  are `async: false` and say why — and one file broke it. A sweep that is not gated is a
  sweep that has to be repeated, which is why this exists rather than a one-line fix.

  ## What is checked, and what is not

  The AST, not a `grep`: `test/conformance/truncated_behaviour_test.exs` *mentions*
  `Application.put_env` in a comment explaining why it does not call one, and a textual
  scan would fail it for saying so.

  `Process.register/2` and `:global` are deliberately **not** checked. Registering a
  per-test unique name is legitimate and registering a fixed one is not, and a gate cannot
  tell them apart without judgment it does not have. Neither appears anywhere in the suite
  today; if one arrives, it needs a reviewer rather than this test.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # Writes that outlive the test process and are visible to every other one.
  @global [
    {Application, :put_env},
    {Application, :delete_env},
    {:persistent_term, :put},
    {:persistent_term, :erase}
  ]

  describe "a test file that runs concurrently" do
    test "writes no VM-global state" do
      offenders =
        for path <- test_files(),
            async?(path),
            {module, function, line} <- global_writes(path),
            do: "#{relative(path)}:#{line} — #{inspect(module)}.#{function}"

      assert offenders == [], """
      #{length(offenders)} concurrent test(s) write state every other test can see:

        #{Enum.join(offenders, "\n  ")}

      Application config and `:persistent_term` are read by the code under test in whatever
      process calls it, so a value set here is set for every test running beside this one.
      `on_exit` bounds the window; it does not remove it.

      Either mark the file `async: false` — `TLA.InvariantModesTest`,
      `TLA.TelemetryVerboseTest` and `TLA.Conformance.TraceBufferTest` all do, and say why —
      or reach the behaviour without the global, as `truncated_behaviour_test.exs` does by
      driving past the shipped default.
      """
    end
  end

  describe "the gate itself" do
    # Anti-vacuity: the walk must find the writes where they DO exist, or the assertion
    # above passes by reading nothing. The `async: false` files are the fixture — they are
    # the ones allowed to do this, so they are also the proof the detector works.
    test "finds the writes in the files that are allowed to make them" do
      allowed =
        for path <- test_files(), not async?(path), global_writes(path) != [], do: relative(path)

      assert length(allowed) >= 4,
             "the detector found VM-global writes in only #{inspect(allowed)}; it should " <>
               "see them in every `async: false` file that sets application config"

      assert "test/tla/invariant_modes_test.exs" in allowed
      assert "test/conformance/trace_buffer_test.exs" in allowed
    end

    # And the reason it reads the AST rather than the text.
    test "does not fail a file that only mentions a global write in a comment" do
      path = Path.join(@root, "test/conformance/truncated_behaviour_test.exs")

      assert async?(path)
      assert File.read!(path) =~ "Application.put_env"
      assert global_writes(path) == []
    end

    test "and reads a real tree" do
      assert length(test_files()) > 50
      assert Enum.count(test_files(), &async?/1) > 40
    end
  end

  # ── Reading the tree ────────────────────────────────────────────────────────

  defp test_files, do: @root |> Path.join("test/**/*_test.exs") |> Path.wildcard()

  defp relative(path), do: Path.relative_to(path, @root)

  defp ast(path), do: path |> File.read!() |> Code.string_to_quoted!()

  # `use ExUnit.Case, async: true`. A file that says nothing runs synchronously.
  defp async?(path) do
    {_ast, async} =
      Macro.prewalk(ast(path), false, fn
        {:use, _meta, [{:__aliases__, _, [:ExUnit, :Case]}, opts]} = node, acc
        when is_list(opts) ->
          {node, acc or Keyword.get(opts, :async, false) == true}

        node, acc ->
          {node, acc}
      end)

    async
  end

  defp global_writes(path) do
    {_ast, found} =
      Macro.prewalk(ast(path), [], fn
        {{:., meta, [target, function]}, _call_meta, _args} = node, acc ->
          case module_of(target) do
            nil -> {node, acc}
            module -> {node, record(acc, module, function, meta)}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp module_of({:__aliases__, _meta, segments}), do: Module.concat(segments)
  defp module_of(erlang_module) when is_atom(erlang_module), do: erlang_module
  defp module_of(_other), do: nil

  defp record(acc, module, function, meta) do
    if {module, function} in @global,
      do: [{module, function, Keyword.get(meta, :line, 0)} | acc],
      else: acc
  end
end
