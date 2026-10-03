defmodule Mix.Tasks.Extla.Coverage do
  @shortdoc "Render the verification ledger to TLA_COVERAGE.md"

  @moduledoc """
  Build the verification ledger — every item each `ExTLA.Spec` declares and the verification
  covering it — and render it to `TLA_COVERAGE.md`.

      mix extla.coverage           # print the ledger
      mix extla.coverage --write   # regenerate TLA_COVERAGE.md
      mix extla.coverage --check   # fail if the golden has drifted from the specs

  ## Why `--check` is HARD

  `TLA_COVERAGE.md` is generated, so a difference means the file was hand-edited or a spec
  changed without a regenerate. Both are build failures. #1's open question 2 asked whether the
  gate should be advisory and answered no: "an advisory gate on a verification artifact is the
  same mistake as `IO.warn` on `max_states_reached`" (D-10).

  Note what the gate does NOT do: it does not fail because items have `NOTHING`. The backlog
  is the document's content, not its error condition. A gate that failed on gaps could only be
  satisfied by deleting rows, which is the opposite of what this is for.
  """

  use Mix.Task

  alias ExTLA.Ledger

  @golden "TLA_COVERAGE.md"
  @switches [write: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    sections = Ledger.run()
    rendered = sections |> Ledger.render() |> IO.iodata_to_binary()
    path = Path.join(File.cwd!(), @golden)

    cond do
      opts[:write] ->
        File.write!(path, rendered)
        Mix.shell().info("wrote #{path}")

      opts[:check] ->
        check!(path, rendered)

      true ->
        Mix.shell().info(rendered)
        summarise(sections)
    end
  end

  # Public only so its failure paths can be tested. Both `Mix.raise` branches were executed by
  # NOTHING before #84: no test invoked this task, and in CI the job that runs it is in
  # `verify`, which never starts when `ledger_test.exs`'s own drift assertion fails first in
  # `check`. So the gate's red path had never once run (#75). The success path is exercised by
  # the `surface-drift` job on every pipeline. The check itself is `ExTLA.Surface.check!/4`,
  # shared with every other golden's task (#270), so there is one definition of "drifted".
  @doc false
  def check!(path, rendered), do: ExTLA.Surface.check!(@golden, "extla.coverage", path, rendered)

  defp summarise(sections) do
    gaps = Ledger.gaps(sections)

    if gaps == [] do
      Mix.shell().info("no gaps: every declared item carries verification")
    else
      Mix.shell().info("\n#{length(gaps)} items with NOTHING — the verification backlog:")
      Enum.each(gaps, &Mix.shell().info("  #{&1.kind} #{&1.name} — #{&1.exercised}"))
    end
  end
end
