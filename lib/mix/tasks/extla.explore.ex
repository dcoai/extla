defmodule Mix.Tasks.Extla.Explore do
  @shortdoc "Evaluate your own expressions at every state of a SAVED counterexample"

  @moduledoc """
  Explore a counterexample `mix extla.check --format json` already wrote, without running the
  checker again.

  > #### Not state-space exploration {: .neutral}
  >
  > `explore` means searching the state space everywhere else in this project
  > (`ExTLA.ModelChecker.explore/2`). This task does not search anything. It reads a
  > counterexample off disk and evaluates expressions over the states already in it — the
  > TLA+ Toolbox's *Trace Explorer*, not TLC. `mix extla.check` is the task that searches.

  ## Usage

      mix extla.explore Specs.DistributedLock --trace counterexample.json \\
        --expr "waiting: length(state.waiting)" \\
        --expr "quorum?: map_size(state.votes) * 2 > 3" \\
        --changed-only

      # from a CI run or an incident, months later, with no checker in the loop
      mix extla.check Specs.DistributedLock --format json > ce.json
      mix extla.explore Specs.DistributedLock --trace ce.json --expr "len: length(state.log)"

  ## `--expr` evaluates code you typed

  An expression over a state is an anonymous function and there is no way to write one on a
  command line, so each `--expr` is **compiled and evaluated** — which is exactly what the
  Toolbox's Trace Explorer does with the expressions you type into it. This is a development
  task and the code it runs is the code you just wrote in your own shell; do not point it at
  a flag string from somewhere else.

  Repeatable, one expression each. Inside one, the state is in scope two ways:

    * **each variable by its own name** — `--expr "length(waiting)"`;
    * **`state`, the whole map** — `--expr "length(state.waiting)"`, and the only way to
      reach a spec variable that is itself called `state`.

  `name: expression` labels the row. Without a label the expression's own text is the label,
  so `--expr "state.holder"` is a row called `state.holder`. The label is recognised by
  parsing, not by splitting on a colon, so `--expr "state.pc[:alice]"` is one unlabelled
  expression rather than a row called `state.pc[`.

  ## The file

  `--trace` takes what `mix extla.check --format json` writes — the whole document, or a single
  trace object lifted out of it — and a lasso as readily as a trace.

  The module argument is not decoration: `ExTLA.Trace.from_json!/1` resolves the trace's atoms
  with `String.to_existing_atom/1`, so the spec has to be loaded before its counterexample can
  be decoded. A trace belonging to a different spec fails naming the atom that did not
  resolve, rather than quietly decoding into something else.

  ## Exit codes

      0  the table was rendered
      1  a bad `--expr`, or a file that is not a counterexample for this spec
  """

  use Mix.Task

  alias ExTLA.{Mix.SpecTarget, Trace}

  @switches [trace: :string, expr: :keep, changed_only: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names} = OptionParser.parse!(args, strict: @switches)
    [spec] = SpecTarget.resolve!(module!(names))

    trace = ExTLA.Mix.TraceFile.read!(path!(opts), inspect(spec))
    expressions = expressions!(opts, representative(trace))

    Mix.shell().info(
      Trace.explore(trace, expressions, changed_only: Keyword.get(opts, :changed_only, false))
    )
  end

  # `SpecTarget.resolve!([])` means "every spec in the project", which is right for
  # `mix extla.check` and wrong here: a trace file is a counterexample for ONE spec, and
  # guessing which would decode it against the wrong set of atoms.
  defp module!([name]), do: [name]
  defp module!([]), do: Mix.raise("name the ExTLA.Spec module the trace belongs to.")
  defp module!(many), do: Mix.raise("one spec at a time; got #{Enum.join(many, ", ")}.")

  defp path!(opts) do
    case Keyword.get(opts, :trace) do
      nil ->
        Mix.raise("pass --trace <file>, a counterexample `mix extla.check --format json` wrote.")

      path ->
        path
    end
  end

  # ── Expressions ─────────────────────────────────────────────────────────────

  # Whether an expression COMPILES cannot vary from state to state: a spec's variable set is
  # fixed by its `init`, so the binding has the same names throughout. Any state will do.
  defp representative(%Trace{states: [first | _]}), do: first
  defp representative(%{prefix: %Trace{states: [first | _]}}), do: first
  defp representative(_trace), do: %{}

  defp expressions!(opts, state) do
    case Keyword.get_values(opts, :expr) do
      [] ->
        Mix.raise("""
        pass at least one --expr; a table of no rows answers no question.

            mix extla.explore MySpec --trace ce.json --expr "waiting: length(waiting)"

        The state is in scope as each variable by name, and as `state`, the whole map.\
        """)

      texts ->
        Enum.map(texts, &expression!(&1, state))
    end
  end

  # The label is found by PARSING rather than by splitting on the first colon. A bare `k: v`
  # is not a term on its own, so the text is parsed inside brackets, where Elixir's own parser
  # reads it as a keyword list; `state.pc[:alice]` bracketed is a one-element list of an
  # expression, which a string split cannot tell apart and would cut into a row called
  # `state.pc[`.
  defp expression!(text, state) do
    case Code.string_to_quoted("[" <> text <> "]") do
      {:ok, [{name, ast}]} when is_atom(name) ->
        {name, evaluator!(ast, text, state)}

      {:ok, [{name, _} | _] = many} when is_atom(name) ->
        Mix.raise(
          "--expr #{inspect(text)} holds #{length(many)} expressions. Pass one per flag, " <>
            "repeating --expr."
        )

      _unlabelled ->
        {String.to_atom(text), evaluator!(parse!(text), text, state)}
    end
  end

  defp parse!(text) do
    case Code.string_to_quoted(text) do
      {:ok, ast} ->
        ast

      {:error, {meta, message, token}} ->
        Mix.raise(
          "--expr #{inspect(text)} does not parse: " <>
            "#{format_parse_error(message, token)} (column #{Keyword.get(meta, :column, 1)})."
        )
    end
  end

  defp format_parse_error(message, token) when is_binary(message), do: message <> token

  defp format_parse_error({prefix, suffix}, token),
    do: prefix <> token <> suffix

  # Parsed once, evaluated per state.
  defp evaluator!(ast, text, state) do
    evaluator = fn state ->
      {value, _binding} = Code.eval_quoted(ast, Map.to_list(state) ++ [state: state])
      value
    end

    compiles!(evaluator, text, state)
    evaluator
  end

  # Two kinds of failure wear the same clothes at the call site and are not the same thing.
  #
  # A **runtime** error — arithmetic on an atom, a key that is not there, `hd([])` — depends on
  # the state and is the normal case: the trace is being explored *because* something in it is
  # wrong, so `ExTLA.Trace.explore/3` reports it in the cell at the state it happened in.
  #
  # A **deterministic** error — a misspelled variable, a remote call to a function that does
  # not exist — does not depend on the state at all, so leaving it to the table means the same
  # typo reported once per state, in cells reading `cannot compile file (errors have been
  # logged)`, with the message that would have helped logged separately to stderr. So it is
  # caught here, once, against one state, and raised with the diagnostic and the names actually
  # in scope. `Code.with_diagnostics/1` is what keeps that message rather than letting the
  # compiler print it past the table.
  #
  # `UndefinedFunctionError` is in that second class and used to be left to the first: a
  # `CompileError` was refused once and `Enum.no_such_thing(count)` — the comment above says a
  # function that does not exist is exactly what the probe is for — filled a cell per state
  # anyway, because an undefined REMOTE call is a runtime error and only an undefined LOCAL one
  # is a compile error (#315).
  defp compiles!(evaluator, text, state) do
    {outcome, diagnostics} = Code.with_diagnostics(fn -> attempt(evaluator, state) end)

    case outcome do
      {:raised, %CompileError{}} ->
        Mix.raise("""
        --expr #{inspect(text)} does not compile:

        #{diagnostics |> Enum.map_join("\n", &("    " <> &1.message)) |> String.trim_trailing()}

        In scope: #{in_scope(state)}, and `state`, the whole map.\
        """)

      {:raised, %UndefinedFunctionError{} = error} ->
        Mix.raise("""
        --expr #{inspect(text)} calls a function that does not exist:

        #{indent(Exception.message(error))}

        That does not depend on the state, so it is refused once rather than reported in \
        every cell.

        In scope: #{in_scope(state)}, and `state`, the whole map.\
        """)

      _state_dependent_or_fine ->
        :ok
    end
  end

  defp in_scope(state),
    do: state |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &to_string/1)

  defp indent(message),
    do:
      message
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))
      |> String.trim_trailing()

  # PERMITTED RESCUE. Scoped to the one call it wraps, and it decides nothing: it hands the
  # exception back as data so `compiles!/3` can sort the deterministic failures from the
  # state-dependent ones. A state-dependent one is returned to the caller untouched and is
  # raised again, at its own state, by `ExTLA.Trace.explore/3`.
  defp attempt(evaluator, state) do
    {:ok, evaluator.(state)}
  rescue
    error -> {:raised, error}
  end

  @doc false
  # Exposed for `ExTLA.SpecOptionsTest`, which holds this and the specification's documented
  # option list to each other (#163). `extla.check` gained this at #134 and nothing else did, so
  # for six work items its section was the only flag list in the spec that stayed correct.
  def switches, do: @switches
end
