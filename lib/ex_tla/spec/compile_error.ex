defmodule ExTLA.Spec.CompileError do
  @moduledoc """
  Raised when a spec module violates one of the rules in `02-dsl-semantics.md`.

  Every rule in that document is enforced when the spec module compiles, so a
  spec either means something precise or does not compile. The message quality
  is a deliverable rather than a nicety (`02-dsl-semantics.md` §7): a diagnostic
  carries the spec module, the declaration it came from, the offending line, and
  — where there is one — the form the author probably meant to write.

  ## `kind` — the name the diagnostic is known by

  Every diagnostic carries a `kind`, a stable identifier: the first column of the
  diagnostics table in `02-dsl-semantics.md` §7 is the kind. It is required, so a
  diagnostic without one cannot be raised, and the set of kinds stays closed.
  """

  defexception [:kind, :module, :declaration, :line, :message]

  @doc """
  Raise a diagnostic.

  `kind` names it — the identifier in the first column of `02-dsl-semantics.md` §7's
  table. `hint` is a second paragraph naming the fix; omit it only when there is nothing
  more useful to say than the problem itself.
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
