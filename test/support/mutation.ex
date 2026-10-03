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

  ## Four outcomes, and two of them are not kills

      killed       a gate failed -- the defect is caught
      survived     every gate passed -- the defect is invisible to the gates
      build_error  the mutated source did not compile
      timeout      it did not finish

  `build_error` and `timeout` are **not** kills. A mutant that never ran says nothing
  about the gates, and counting it as caught is how a harness comes to report a kill rate
  it has not earned.

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
      * `:timeout` — seconds for this mutant's gate, overriding the sweep's. For a
        defect that makes the search non-terminating, where the sweep's budget would be
        spent waiting for something that is never going to finish.
    """

    @enforce_keys [:name, :models, :file, :anchor, :replacement, :kills]
    defstruct [:name, :models, :file, :anchor, :replacement, :kills, timeout: nil]

    @type gate :: :corpus | :suite | :nothing
    @type t :: %__MODULE__{
            name: atom(),
            models: String.t(),
            file: String.t(),
            anchor: String.t(),
            replacement: String.t(),
            kills: gate(),
            timeout: pos_integer() | nil
          }
  end

  @type outcome :: :killed | :survived | :build_error | :timeout

  @type result :: %{
          name: atom(),
          outcome: outcome(),
          gate: Mutant.gate(),
          expected: Mutant.gate(),
          output: String.t()
        }

  # What each gate actually runs. `:corpus` is the D-9 acceptance gate and is what most
  # mutants are aimed at; `:suite` is everything, for defects no corpus entry exercises.
  @gates %{
    corpus: ["test", "test/differential"],
    suite: ["test"]
  }

  @default_timeout 300
  @copied ~w(lib test bin mix.exs mix.lock .formatter.exs deps _build)

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

    result =
      case compile(workspace, compile_timeout) do
        {output, 0} -> gate(workspace, mutant, timeout, output)
        {output, status} -> classify_failed_build(mutant, output, status)
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

  defp gate(workspace, %Mutant{kills: :nothing} = mutant, timeout, _compile_output) do
    # A mutant expected to survive is still run — the measurement is the point, and a
    # mutant nobody ran cannot be reported as surviving.
    gate(workspace, %{mutant | kills: :corpus}, timeout, nil)
    |> Map.put(:expected, :nothing)
  end

  defp gate(workspace, mutant, timeout, _compile_output) do
    {output, status} = run(workspace, Map.fetch!(@gates, mutant.kills), timeout)

    outcome =
      case status do
        0 -> :survived
        s when s in [124, 137] -> :timeout
        _ -> :killed
      end

    %{
      name: mutant.name,
      outcome: outcome,
      gate: mutant.kills,
      expected: mutant.kills,
      output: tail(output)
    }
  end

  # A mutated source that does not compile is not a caught defect. It is a mutant that
  # never ran, and the two must not render as the same thing.
  defp classify_failed_build(mutant, output, status) do
    outcome = if status in [124, 137], do: :timeout, else: :build_error

    %{
      name: mutant.name,
      outcome: outcome,
      gate: mutant.kills,
      expected: mutant.kills,
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
