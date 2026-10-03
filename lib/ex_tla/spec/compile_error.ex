defmodule ExTLA.Spec.CompileError do
  @moduledoc """
  Raised when a spec module violates one of the rules in `02-dsl-semantics.md`.

  Every rule in that document is enforced when the spec module compiles, so a
  spec either means something precise or does not compile. The message quality
  is a deliverable rather than a nicety (§7): a diagnostic carries the spec
  module, the declaration it came from, the offending line, and — where there is
  one — the form the author probably meant to write.

  ## `kind` — the name the diagnostic is known by (#273)

  `02-dsl-semantics.md` §7 tabulates the diagnostics this raises, under a preamble
  promising that a spec violating any rule does not compile. Nothing held the table to
  the code, and nothing could: a row's first column was a *name its author gave it* and
  the code carried no identifier to match it against. The table was nineteen rows short,
  and one row described a check that runs at runtime.

  `kind` is that identifier. Every site passes one, `DIAGNOSTICS.md` lists them, §7's
  first column is the kind, and `test/docs/spec_diagnostics_test.exs` holds the four sets
  — raised, rendered, tabulated, tested — to each other. It is `Keyword.fetch!`, so a new
  diagnostic without a kind does not compile, which is what keeps the set closed.
  """

  defexception [:kind, :module, :declaration, :line, :message]

  @doc """
  Raise a diagnostic.

  `kind` names it — the identifier §7's table and `DIAGNOSTICS.md` share. `hint` is a
  second paragraph naming the fix; omit it only when there is nothing more useful to say
  than the problem itself.
  """
  def raise!(opts) do
    kind = Keyword.fetch!(opts, :kind)
    module = Keyword.fetch!(opts, :module)
    declaration = Keyword.fetch!(opts, :declaration)
    line = Keyword.get(opts, :line)
    problem = Keyword.fetch!(opts, :problem)
    hint = Keyword.get(opts, :hint)

    where = if line, do: ":#{line}", else: ""

    message =
      "#{inspect(module)}#{where}, in #{declaration}: #{problem}" <>
        if(hint, do: "\n\n" <> hint, else: "")

    raise __MODULE__,
      kind: kind,
      module: module,
      declaration: declaration,
      line: line,
      message: message
  end
end
