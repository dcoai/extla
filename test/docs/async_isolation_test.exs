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

  ## The list was short, and its shortness was the defect (#322)

  This gate ran green for as long as it existed over three files that break the rule it
  states, because `Mix.shell/1` and `Code.put_compiler_option/2` were not in `@global`.
  A gate whose list is two entries short claims to cover a class it does not.

  Two things a reader should take from that, both of which cost real time to learn:

  * **`on_exit` does not make such a test safe.** It runs after the damage, and the window
    is the whole body of the test. `test/mix/tla_coverage_test.exs` restored the shell
    faithfully and still blanked `Mix.shell()` output for every concurrent reader while it
    ran — which surfaces as a failed assertion in some unrelated file, about its own
    subject rather than about the shell.

  * **Spawning isolates the caller, not the setting.**
    `test/docs/moduledoc_examples_test.exs` set `:ignore_module_conflict` from a spawned
    process under a comment claiming that kept it out of the test process. Measured, a
    child's write to either of these is read straight back by the parent. A process
    boundary is no boundary at all for state the VM keeps once.

  The boundary of the list — what is in, what is out, and what to do on finding a fifth —
  is stated at `@global` itself, where the reader adding one is looking.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # ── What counts as a VM-global write ────────────────────────────────────────
  #
  # Hand-kept, because it has to be. The AST can see that a call is `Mix.shell/1`; nothing
  # in the AST says whether `Mix.shell/1` writes state the whole VM shares. That is a fact
  # about the callee, and there is no tree to read it out of — so this list is an
  # enumeration somebody maintains, which is this project's signature defect class sitting
  # inside the gate meant to prevent a different instance of it. It cannot be derived. It
  # can be justified, which is what the rest of this comment is for.
  #
  # **In.** A call whose effect is read back through a process-independent path: whoever
  # sets it, everyone sees it, and `on_exit` bounds the window rather than removing it.
  # Application config, `:persistent_term`, the Mix shell, the compiler options. Two of
  # these were missing until #322, with three live offenders between them — `{Mix, :shell}`
  # (`test/mix/tla_coverage_test.exs`, the flake that started #322) and
  # `{Code, :put_compiler_option}` (`test/docs/moduledoc_examples_test.exs`, which set it
  # from a spawned process under a comment claiming that isolated it, and
  # `test/tla/declaration_shapes_test.exs`, which set it in the test process outright).
  # Spawning isolates the caller, not the setting: a child's write is measurable in the
  # parent for both.
  #
  # **Out, deliberately.** `Process.register/2` and `:global`: a per-test unique name is
  # legitimate and a fixed one is not, and no gate can tell them apart without judgment it
  # does not have. The process dictionary, which dies with the test process and is
  # therefore not global at all. `System.put_env/2`, which *is* global and belongs here the
  # day anything calls it; nothing does, and an entry with no possible offender is an entry
  # nothing exercises.
  #
  # **Finding a fifth.** Add the `{module, function}` pair AND a call to it in `@fixture`
  # below — the anti-vacuity test asserts the two agree in both directions, so an entry
  # without a fixture call fails, and so does a fixture call without an entry. Then run: if
  # a file goes red, fix the file, never the list. The one thing not to do is delete the
  # entry because nothing calls it today.
  @global [
    {Application, :put_env},
    {Application, :delete_env},
    {:persistent_term, :put},
    {:persistent_term, :erase},
    {Mix, :shell},
    {Code, :put_compiler_option}
  ]

  # One real call per `@global` entry, written out by hand rather than generated from
  # `@global`. A snippet built from the list would spell a typo in the list the same way
  # twice and match itself, proving nothing; this is an independent statement of what the
  # calls look like, so the two can disagree.
  @fixture """
  defmodule TLA.AsyncIsolationFixture do
    def every_write do
      Application.put_env(:extla, :k, 1)
      Application.delete_env(:extla, :k)
      :persistent_term.put(:k, 1)
      :persistent_term.erase(:k)
      Mix.shell(Mix.Shell.IO)
      Code.put_compiler_option(:ignore_module_conflict, true)
    end
  end
  """

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

    # The fixture covers what the tree cannot. After #322's fixes NO test file calls
    # `Code.put_compiler_option/2` at all — the entry that caught two offenders is now
    # exercised by nothing in the tree, and could be deleted without anything going red.
    # That is the same nothing this gate exists to catch, so the entries are held against a
    # fixture instead of against whatever the suite happens to contain this week.
    #
    # Both directions, and both matter: an entry with no fixture call is a tuple nobody has
    # shown the detector can see, and a fixture call with no entry is a write the gate would
    # walk straight past.
    test "sees every call it lists, and lists every call it sees" do
      written = for {module, function, _line} <- calls_in(@fixture), do: {module, function}

      assert Enum.sort(written) == Enum.sort(@global), """
      `@fixture` and `@global` disagree about what a VM-global write is.

        listed, but no call in `@fixture`: #{inspect(@global -- written)}
        called in `@fixture`, but not listed: #{inspect(written -- @global)}

      An entry with no fixture call is one nobody has shown the detector can see — a
      misspelled function name would sit there inert, failing no file whatever that file
      does. A fixture call with no entry is a write this gate walks straight past. Add the
      missing entry to `@global`, or the missing call to `@fixture`.
      """

      # And the detector as the gate above actually uses it, not just the raw walk.
      detected =
        for {module, function, _line} <- global_writes_in(@fixture), do: {module, function}

      assert Enum.sort(detected) == Enum.sort(@global)
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

  defp global_writes(path), do: path |> File.read!() |> global_writes_in()

  defp global_writes_in(source) do
    for {module, function, line} <- calls_in(source),
        {module, function} in @global,
        do: {module, function, line}
  end

  # Every remote call in a source, with `@global` not consulted. The filter lives in the
  # caller rather than here for one reason: the fixture above is read with this, so the
  # comparison against `@global` is a comparison against something `@global` did not
  # already narrow. Filtering during the walk made that check vacuous — the found set was
  # a subset of the list by construction, so an entry could be deleted and nothing said so.
  defp calls_in(source) do
    {_ast, found} =
      Macro.prewalk(Code.string_to_quoted!(source), [], fn
        {{:., meta, [target, function]}, _call_meta, _args} = node, acc ->
          case module_of(target) do
            nil -> {node, acc}
            module -> {node, [{module, function, Keyword.get(meta, :line, 0)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp module_of({:__aliases__, _meta, segments}), do: Module.concat(segments)
  defp module_of(erlang_module) when is_atom(erlang_module), do: erlang_module
  defp module_of(_other), do: nil
end
