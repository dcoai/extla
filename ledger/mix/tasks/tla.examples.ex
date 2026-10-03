defmodule Mix.Tasks.Tla.Examples do
  @shortdoc "Generate the differential corpus entries that spec/07-examples.md publishes"

  @moduledoc """
  Generate `test/differential/<entry>/spec.ex` from `spec/07-examples.md`'s fences, so the
  corpus checks the documentation rather than a copy of it (#280).

      mix tla.examples           # print what would be written
      mix tla.examples --write   # regenerate the corpus entries
      mix tla.examples --check   # fail if an entry has drifted from the page

  ## Why `--check` is HARD

  Three corpus moduledocs claimed to be "Example N verbatim, which is the point: the
  corpus checks the documentation, not a paraphrase of it", and D-21 falsified all three
  **forty-three minutes** after the claim was written, by rewriting the corpus's types and
  leaving the page. For a month the page a reader copies from declared
  `type: [^resources ~> :set]` where the checker had been given `set(^processes)`.

  An advisory gate would not have helped: nobody was reading the page against the corpus,
  which is exactly why the claim survived. The gate is what makes "verbatim" a property of
  the build instead of a sentence in a moduledoc.

  ## The direction is unusual and deliberate

  The other five goldens render a document from code. This one renders code from a
  document, because here the document is the specification — the thing a reader is told to
  copy — and the corpus is its consumer. `ExTLA.Examples` says what the generator changes
  (the module name, and `default:` on the constants) and why neither is drift.
  """

  use Mix.Task

  alias ExTLA.Examples

  @switches [write: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    for entry <- Examples.entries() do
      rendered = Examples.render(entry)
      golden = Path.relative_to(entry.path, File.cwd!())

      cond do
        opts[:write] ->
          File.write!(entry.path, rendered)
          Mix.shell().info("wrote #{golden}")

        opts[:check] ->
          ExTLA.Surface.check!(golden, "tla.examples", entry.path, rendered)

        true ->
          Mix.shell().info(rendered)
      end
    end
  end

  @doc false
  # Exposed for `ExTLA.SpecOptionsTest` / `CLI_SURFACE.md`, which hold a task's switches and
  # its documentation to each other.
  def switches, do: @switches
end
