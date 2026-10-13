defmodule ExTLA.Mutation do
  @moduledoc """
  Applies a deliberate defect to a copy of the checker and reports which gate, if any,
  noticed (#46).

  A gate whose kill power is unmeasured is an assertion, and this project does not do
  assertions about its own correctness — D-9 measures the checker against TLC,
  `verify_symmetry:` measures a reduction against its absence, and
  `parallel_agreement_test.exs` measures eight workers against one. Nothing measured what
  any of them would *catch*. A mutant no gate kills is a **survivor**, and a survivor is
  the specification for the next check to write.

  It lives in `test/support/` rather than `lib/` deliberately: it mutates ExTLA's own
  source, so it is meaningful only inside this checkout and a consumer should not receive
  it in the package.

  ## Anchored text, not AST rewriting

  A mutant names a file, an anchor to find, and what to put there. The catalogue has to be
  *read* — a reviewer must be able to see what defect is modelled without running anything
  — and an AST patch is not readable.

  Two ways a patch can be wrong, and both raise rather than skip:

    * **the anchor is gone**, because the checker's source moved. The mutant no longer
      models what it claims, and a sweep that quietly skipped it would stay green while
      measuring less. This is the way this harness rots, so it is the loudest failure it
      has.
    * **the anchor appears more than once**, so which occurrence is meant is a guess.

  ## Five outcomes, and three of them are not kills

      killed        a gate failed because of the mutant -- the defect is caught
      survived      every gate passed -- the defect is invisible to the gates
      build_error   the mutated source did not compile
      timeout       it did not finish
      inconclusive  a gate failed, but the failure is not the mutant's

  `build_error` and `timeout` are **not** kills. A mutant that never ran says nothing
  about the gates, and counting it as caught is how a harness comes to report a kill rate
  it has not earned.

  ## A kill is attributed, not assumed (#378)

  A failing gate is not yet a kill. A test that flakes under host load fails the gate
  just as well, and main pipeline 4744 recorded the catalogue's one expected survivor as
  killed that way. So a failing gate is run twice more, each time over only the tests
  that just failed (`mix test --failed`):

    1. **with the mutant still applied.** Nothing fails again: the failure did not
       reproduce, which is a flake, not a kill.
    2. **with the mutant removed.** Something still fails: the tree fails without the
       mutant, so the mutant did not cause it.

  Only a failure that reproduces and goes away with the mutant is a kill; anything else is
  `inconclusive`, with the reason. Neither half alone is enough: re-running the unmutated
  tree misses a one-off flake, which passes there too, and re-running the mutant misses a
  test that fails regardless. The reruns cost only the failing tests, and only on the
  path where a gate failed.

  ## Out of process

  The gate runs under `timeout(1)` via `System.cmd/3`, so a mutant that hangs or takes the
  VM down is an exit status observed from outside. The alternative would be `try`/`rescue`,
  which CLAUDE.md forbids and which would turn a checker that died into a checker that was
  caught.

  ## One workspace per sweep

  The project is copied once — it is about 16 MB with `deps` and `_build` — and compiled
  once. Each mutant then patches one file, recompiles just that file, runs its gate, and
  restores the file. Copying per mutant would be correct and would spend most of the
  sweep on `cp`.

  The copy holds everything the gates' tests read, which is more than what they compile. A
  file a gate needs and the workspace lacks fails that gate whether or not a mutant is
  applied. The attribution rule reports that as `inconclusive (fails_unmutated)`, where it
  used to be a kill, and `mix extla.mutants --check` fails on it (#380): a gate that fails
  unmutated is a harness defect, not a flake. The copy is not the whole tree, so a gate
  runs named tests (`:corpus`, or a mutant's `:tests`) and never the whole suite, which
  reads README.md, guides/ and spec/.
  """

  defmodule Mutant do
    @moduledoc """
    One deliberate defect.

      * `:name` — stable identifier; it is the key in `survivors.json`.
      * `:models` — one line saying what real defect this stands for. The catalogue is
        read more often than it is run.
      * `:file` — path under the project root, e.g. `"lib/ex_tla/model_checker.ex"`.
      * `:anchor` — the exact text to replace. Must appear exactly once.
      * `:replacement` — what to put there.
      * `:kills` — the gate expected to catch it, or `:nothing` where the mutant is
        expected to survive and the survival is the finding.
      * `:tests` — for `kills: :tests`, the test files that gate runs: the ones measured
        to catch this mutant, named so a reader sees which tests do the work. Their
        generated properties are excluded, so the kill is one every seed reproduces (#392).
      * `:timeout` — seconds for this mutant's gate, overriding the sweep's. For a
        defect that makes the search non-terminating, where the sweep's budget would be
        spent waiting for something that is never going to finish.
    """

    @enforce_keys [:name, :models, :file, :anchor, :replacement, :kills]
    defstruct [:name, :models, :file, :anchor, :replacement, :kills, tests: [], timeout: nil]

    @type gate :: :corpus | :tests | :nothing
    @type t :: %__MODULE__{
            name: atom(),
            models: String.t(),
            file: String.t(),
            anchor: String.t(),
            replacement: String.t(),
            kills: gate(),
            tests: [Path.t()],
            timeout: pos_integer() | nil
          }
  end

  @type outcome :: :killed | :survived | :build_error | :timeout | :inconclusive

  @typedoc "Why a failing gate was not counted as a kill."
  @type reason :: :not_reproduced | :fails_unmutated | :rerun_timed_out | :unmutated_build_failed

  @type result :: %{
          name: atom(),
          outcome: outcome(),
          reason: reason() | nil,
          gate: Mutant.gate(),
          expected: Mutant.gate(),
          failures: [String.t()],
          output: String.t()
        }

  # What each gate actually runs. `:corpus` is the D-9 acceptance gate and is what most
  # mutants are aimed at. `:tests` is for defects no corpus entry exercises, and runs the
  # test files the mutant names (`Mutant` `:tests`).
  #
  # It replaced `:suite`, which ran the whole of `mix test` (#380). The whole suite reads
  # README.md, guides/ and spec/ and failed in the workspace with no mutant applied, so
  # all three of its kills were unmeasured. Naming the files that catch each mutant
  # measures something specific, in seconds rather than a full suite per mutant.
  @gates %{
    corpus: ["test", "test/differential"]
  }

  @default_timeout 300
  # What `timeout(1)` exits with: 124 when the budget ran out, 137 when `--kill-after` had
  # to SIGKILL a process that ignored the TERM.
  @timed_out [124, 137]
  # Everything `mix test` reads, not only what it compiles. `.surfex.exs` is read by the
  # evidence formatter `test_helper.exs` starts (#336). Without it the formatter crashes,
  # and whether that crash makes a run exit non-zero depends on timing: a short passing
  # run exits 1 every time, while the 77-second corpus gate exited 0. A passing gate that
  # exits 1 is a kill, so the crash turned load into kills (#378).
  @copied ~w(lib test bin mix.exs mix.lock .formatter.exs .surfex.exs deps _build)

  @doc """
  Copy the project into a temporary directory and compile it once.

  Returns the workspace path. The caller must `cleanup/1`.
  """
  @spec prepare(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def prepare(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    workspace = Path.join(System.tmp_dir!(), "tla-mutation-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    for entry <- @copied, path = Path.join(root, entry), File.exists?(path) do
      File.cp_r!(path, Path.join(workspace, entry))
    end

    case compile(workspace, @default_timeout) do
      {_output, 0} ->
        {:ok, workspace}

      {output, status} ->
        cleanup(workspace)
        {:error, "the unmutated copy does not build (exit #{status}):\n#{output}"}
    end
  end

  @doc """
  Delete a workspace. Safe to call twice.
  """
  @spec cleanup(Path.t()) :: :ok
  def cleanup(workspace) do
    File.rm_rf!(workspace)
    :ok
  end

  @doc """
  Apply one mutant, run its gate, restore the file, and classify.

  The file is restored whether or not the gate passed, so the next mutant starts from a
  pristine tree — and restoring is a plain write of the text read before patching rather
  than an undo, so a mutant cannot leave the workspace subtly different.

  Options: `:timeout` and `:compile_timeout` in seconds, and `:gates`, which replaces the
  map from gate name to `mix` arguments. That last one exists for the harness's own tests,
  which need a gate whose failure they control.
  """
  @spec run_one(Path.t(), Mutant.t(), keyword()) :: result()
  def run_one(workspace, %Mutant{} = mutant, opts \\ []) do
    timeout = mutant.timeout || Keyword.get(opts, :timeout, @default_timeout)
    # Separate, and generous: a mutant that compiles slowly is not a mutant that hung, and
    # one budget for both would report the first as the second.
    compile_timeout = Keyword.get(opts, :compile_timeout, @default_timeout)
    path = Path.join(workspace, mutant.file)
    pristine = read_target!(path, mutant)

    File.write!(path, patch(pristine, mutant))

    # The attribution's second rerun needs the mutant gone. Restoring here is the same
    # plain write as below, so the tree it runs is the tree every other mutant starts from.
    unmutate = fn ->
      File.write!(path, pristine)
      compile(workspace, compile_timeout)
    end

    result =
      case compile(workspace, compile_timeout) do
        {_output, 0} ->
          gate(workspace, mutant, timeout, Keyword.get(opts, :gates, @gates), unmutate)

        {output, status} ->
          classify_failed_build(mutant, output, status)
      end

    File.write!(path, pristine)
    result
  end

  @doc """
  Run a catalogue against one workspace, sequentially.

  Sequential because the workspace is one directory and a mutant patches a file in it.
  The sweep is a CI job rather than part of `mix test`, so its wall time is a budget
  rather than a latency.
  """
  @spec sweep([Mutant.t()], keyword()) :: {:ok, [result()]} | {:error, String.t()}
  def sweep(mutants, opts \\ []) do
    case prepare(opts) do
      {:ok, workspace} ->
        results = Enum.map(mutants, &run_one(workspace, &1, opts))
        cleanup(workspace)
        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether `timeout(1)` is available. The runner needs it, and needs to say so plainly
  rather than hanging a CI job for its whole limit.
  """
  @spec timeout_available?() :: boolean()
  def timeout_available?, do: System.find_executable("timeout") != nil

  # ── Patching ────────────────────────────────────────────────────────────────

  defp read_target!(path, mutant) do
    unless File.exists?(path) do
      raise ArgumentError,
            "mutant #{inspect(mutant.name)} names #{mutant.file}, which does not exist in " <>
              "the workspace. The catalogue is stale: either the file moved or the mutant " <>
              "outlived the code it models."
    end

    File.read!(path)
  end

  @doc """
  The patched source, or a raise saying why the mutant no longer applies.

  Public and pure so the anchor rules can be tested on plain strings, which is what lets
  the catalogue's staleness check run in the normal suite rather than only in the sweep.
  """
  @spec patch(String.t(), Mutant.t()) :: String.t()
  def patch(source, mutant) do
    case occurrences(source, mutant.anchor) do
      1 ->
        String.replace(source, mutant.anchor, mutant.replacement)

      0 ->
        raise ArgumentError,
              "mutant #{inspect(mutant.name)}: its anchor is not in #{mutant.file}.\n\n" <>
                "The checker's source has moved and this mutant no longer models what it " <>
                "claims. That is a build failure rather than a skip, because a mutant that " <>
                "quietly stops applying leaves the sweep green while measuring less.\n\n" <>
                "Anchor:\n#{mutant.anchor}"

      n ->
        raise ArgumentError,
              "mutant #{inspect(mutant.name)}: its anchor appears #{n} times in " <>
                "#{mutant.file}, so which one is meant is a guess. Lengthen the anchor " <>
                "until it is unique.\n\nAnchor:\n#{mutant.anchor}"
    end
  end

  defp occurrences(source, anchor), do: length(String.split(source, anchor)) - 1

  # ── Running ─────────────────────────────────────────────────────────────────

  defp compile(workspace, timeout) do
    run(workspace, ["compile"], timeout)
  end

  @doc false
  # An empty `:tests` list does not match, on purpose: `mix test` with no paths is the whole
  # suite, which is exactly the gate `:tests` replaced, and a missing list would bring it
  # back silently.
  #
  # Generated properties are excluded (#392). A property draws new input on every seed, so
  # a kill that rests on one is a kill on some seeds: `wrong_init_index` was killed only by
  # a property, survived 10 seeds of 100, and failed a pipeline that changed nothing. With
  # properties out, a `:tests` kill is one every run reproduces, and a gate that needs one
  # is a survivor the sweep reports the first time it is measured.
  #
  # Public so the arguments are tested without a sweep.
  def gate_args(%Mutant{kills: :tests, tests: [_ | _] = tests}, _gates),
    do: ["test" | tests] ++ ["--exclude", "property"]

  def gate_args(%Mutant{kills: kills}, gates) when kills != :tests, do: Map.fetch!(gates, kills)

  defp gate(workspace, %Mutant{kills: :nothing} = mutant, timeout, gates, unmutate) do
    # A mutant expected to survive is still run — the measurement is the point, and a
    # mutant nobody ran cannot be reported as surviving.
    gate(workspace, %{mutant | kills: :corpus}, timeout, gates, unmutate)
    |> Map.put(:expected, :nothing)
  end

  defp gate(workspace, mutant, timeout, gates, unmutate) do
    args = gate_args(mutant, gates)
    {output, status} = run(workspace, args, timeout)

    {verdict, evidence} =
      if status == 0 or status in @timed_out do
        {outcome(status, nil, nil), output}
      else
        attribute(workspace, args, timeout, status, output, unmutate)
      end

    {outcome, reason} =
      case verdict do
        {:inconclusive, reason} -> {:inconclusive, reason}
        outcome -> {outcome, nil}
      end

    %{
      name: mutant.name,
      outcome: outcome,
      reason: reason,
      gate: mutant.kills,
      expected: mutant.kills,
      failures: failures(evidence),
      output: tail(evidence)
    }
  end

  # The two reruns of #378. `--failed` reads the manifest the previous `mix test` in this
  # workspace wrote, so each rerun is exactly the tests the run before it failed. The
  # evidence kept is the run that decided: the failures that reproduced for a kill, the
  # first run for a flake, the unmutated run for a tree that fails on its own.
  defp attribute(workspace, args, timeout, status, output, unmutate) do
    {again, reproduced} = run(workspace, args ++ ["--failed"], timeout)

    if reproduced == 0 or reproduced in @timed_out do
      {outcome(status, reproduced, nil), output}
    else
      case unmutate.() do
        {_build, 0} ->
          {plain, unmutated} = run(workspace, args ++ ["--failed"], timeout)
          verdict = outcome(status, reproduced, unmutated)
          {verdict, if(verdict == :killed, do: again, else: plain)}

        {build, _status} ->
          {{:inconclusive, :unmutated_build_failed}, build}
      end
    end
  end

  @doc """
  The outcome of a gate from its exit statuses: the gate's own, the rerun with the mutant,
  and the rerun without it. A rerun that did not happen is `nil`.

  Pure, so the attribution rule is tested on statuses rather than behind a sweep: a gate
  failure that does not reproduce, or that recurs unmutated, is never a kill.
  """
  @spec outcome(integer(), integer() | nil, integer() | nil) ::
          :survived | :timeout | :killed | {:inconclusive, reason()}
  def outcome(0, nil, nil), do: :survived
  def outcome(gate, nil, nil) when gate in @timed_out, do: :timeout
  def outcome(_gate, rerun, _) when rerun in @timed_out, do: {:inconclusive, :rerun_timed_out}
  def outcome(_gate, 0, nil), do: {:inconclusive, :not_reproduced}

  def outcome(_gate, _rerun, plain) when plain in @timed_out,
    do: {:inconclusive, :rerun_timed_out}

  def outcome(_gate, _rerun, 0), do: :killed
  def outcome(_gate, _rerun, plain) when is_integer(plain), do: {:inconclusive, :fails_unmutated}

  @doc """
  The failing tests ExUnit named in `output`, as `"test name (Module)"`.

  What a reader of the job log needs to tell a real kill from a flake: the corpus entry a
  defect broke, or the unrelated test that happened to fail.
  """
  @spec failures(String.t()) :: [String.t()]
  def failures(output) do
    ~r/^\s+\d+\) ((?:test|property|doctest) .+)$/m
    |> Regex.scan(output, capture: :all_but_first)
    |> Enum.map(fn [name] -> String.trim_trailing(name) end)
  end

  # A mutated source that does not compile is not a caught defect. It is a mutant that
  # never ran, and the two must not render as the same thing.
  defp classify_failed_build(mutant, output, status) do
    outcome = if status in @timed_out, do: :timeout, else: :build_error

    %{
      name: mutant.name,
      outcome: outcome,
      reason: nil,
      gate: mutant.kills,
      expected: mutant.kills,
      failures: [],
      output: tail(output)
    }
  end

  defp run(workspace, args, timeout) do
    unless timeout_available?() do
      raise RuntimeError,
            "ExTLA.Mutation needs `timeout(1)` (coreutils) so that a mutant which hangs is " <>
              "an exit status rather than a stuck job. It is not on PATH."
    end

    System.cmd(
      "timeout",
      ["--kill-after=10s", "#{timeout}s", "mix" | args],
      cd: workspace,
      env: [{"MIX_ENV", "test"}, {"TLA_MUTATION", "1"}],
      stderr_to_stdout: true
    )
  end

  # Enough to see which gate failed and why, without carrying a whole suite's output into
  # an artifact that is diffed.
  defp tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-40)
    |> Enum.join("\n")
  end
end
