defmodule ExTLA.CallerClaimsTest do
  @moduledoc """
  A docstring that names a caller is telling the truth (#324, #347).

  `ExTLA.Set.cross_many/1` justified its empty-product convention as "the answer the DSL
  needs when an action has no parameters". Nothing in `lib/` called it, and the DSL builds
  its parameter bindings with `ExTLA.ModelChecker.bindings/3`, a different operation. The
  claim had been there since the module was written, repeated in `spec/01`, and nothing
  read it: `API_SURFACE.md` records a function's head, not its rationale.

  ## What is checked

  Every `@doc` and `@moduledoc` under `lib/`, read from the AST so each doc is attached to
  the module and function it documents. A sentence is a **caller claim** when it says
  something is called from, called by, used by, needed by or relied on by something, or is
  "what … needs". In each one:

  - **Every backticked project function it names exists.** `M.f/a` is looked up in `M`. A
    bare `f/a` belongs to the last module the sentence named, or else to the documented
    module, which is how a reader takes it. A function outside the project, like
    `Agent.update/3`, is not this project's to check.
  - **In a function's `@doc`, each caller named after a *calls* verb (called from/by, used
    by, relied on by) reaches the documented function**: by a local or remote call, or a
    capture, of that name and an arity it has, made by the caller or by a function of its
    own module it calls locally (`ExTLA.PropertyTest.action_sequences/3` does its calling in
    a private `walk/4`). The module qualifier of the call is not compared, because aliases
    make it unreliable from source, so this is a name-and-arity check.
  - **A *needs* claim (needed by, "what … needs") gets the existence check only.** A need is
    often met by a value passed in as an argument: `weak_fairness/5` needs what
    `constraint_predicates/3` builds, and never calls it. Neither does a `@moduledoc`
    claim, whose subject is the module or something it builds (`ExTLA.Profile`'s
    closures), which the call graph cannot follow.

  ## What is not checked, and why

  A claim that names no backticked function, such as "the DSL needs", is not refused. The
  same phrasing is how `lib/` talks about concepts ("what Layer 3 needs", "what a safety
  violation needs") and hypotheticals ("a helper function called from an action body").
  A form check would refuse those correct sentences to catch the one wrong one, so
  `cross_many/1` was rewritten instead (#324). Naming a caller with backticks is what
  makes a claim checkable, and that is the form to use.

  The first run found one: `ExTLA.Profile`'s moduledoc wrote `take_action/6` and
  `enabled_bindings/3` right after `ExTLA.ModelChecker.Safety.check_invariants/4`, which
  makes them read as Safety functions. Both are in `ExTLA.ModelChecker`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # How many caller-claim references lib/ holds now. The test is not vacuous: a parser
  # that stopped finding claims would pass every claim it found. A new claim updates this
  # number, which is the moment to check that the claim is true.
  @expected_references 9

  # A claim that something CALLS: the named caller must reach the documented function.
  @calls ~r/\b(called (from|by)|used by|relied on by)\b/i
  # A claim that something NEEDS it: often met by a value passed in as an argument, which
  # the call graph does not show, so the named function must exist and no more.
  @claim ~r/\b(called (from|by)|used by|relied on by|needed by|what\b(?:[^.`]|`[^`]*`)*\bneeds?)\b/i
  # `Module`, `Module.fun/arity` or a bare `fun/arity`, in that group order.
  @reference ~r/`(?:([A-Z]\w*(?:\.[A-Z]\w*)*)(?:\.([a-z_]\w*[?!]?)\/(\d+))?|([a-z_]\w*[?!]?)\/(\d+))`/

  describe "lib/ docstrings" do
    test "every caller a docstring names exists, and calls what it is said to" do
      %{references: references, problems: problems} = check(lib_sources())

      assert problems == [], """
      #{length(problems)} caller claim(s) in lib/ docstrings are not true:

      #{Enum.map_join(problems, "\n", &"  - #{&1}")}

      Name a caller that exists, fully qualified unless it is in the documented module, and
      that calls the documented function. If the reason for the behaviour does not depend
      on a caller, state it on its own terms instead (#324).
      """

      assert length(references) == @expected_references, """
      expected #{@expected_references} caller-claim references in lib/, found \
      #{length(references)}:

      #{Enum.map_join(references, "\n", &"  - #{&1}")}

      A new claim: check that it is true (the test above did), then update the count.
      """
    end
  end

  describe "the checker" do
    test "reports a named caller that does not exist" do
      source = """
      defmodule Fixture.A do
        @doc "Called from `Fixture.A.nowhere/1`, which is gone."
        def target(x), do: x
      end
      """

      assert %{problems: [problem]} = check([{"lib/a.ex", source}])
      assert problem =~ "Fixture.A.nowhere/1 does not exist"
    end

    test "reports a named caller that does not call the documented function" do
      source = """
      defmodule Fixture.B do
        @doc "Used by `bystander/0`."
        def target(x), do: x

        def bystander, do: :nothing
      end
      """

      assert %{problems: [problem]} = check([{"lib/b.ex", source}])
      assert problem =~ "Fixture.B.bystander/0 does not call target/1"
    end

    test "resolves a bare reference against the module the sentence last named" do
      source = """
      defmodule Fixture.C do
        @moduledoc "Its closures are called from `Fixture.D.run/1` and `go/0`."
      end

      defmodule Fixture.D do
        def run(x), do: x
      end
      """

      assert %{problems: [problem]} = check([{"lib/c.ex", source}])
      assert problem =~ "Fixture.D.go/0 does not exist"
    end

    test "passes true claims: a local call, a remote call, a capture, a delegate" do
      source = """
      defmodule Fixture.E do
        @doc "Called by `local/1`, `Fixture.F.remote/1`, `Fixture.F.captured/0` and `Fixture.F.delegated/1`."
        def target(x, y \\\\ 0), do: x + y

        def local(x), do: target(x)
      end

      defmodule Fixture.F do
        alias Fixture.E

        def remote(x), do: E.target(x, 1)
        def captured, do: &E.target/1
        defdelegate delegated(x), to: Fixture.E, as: :target
      end
      """

      assert %{problems: [], references: references} = check([{"lib/e.ex", source}])
      assert length(references) == 4
    end

    test "follows a caller through its own module's helpers, and only checks a need exists" do
      source = """
      defmodule Fixture.H do
        @doc "Used by `Fixture.I.public/1`."
        def target(x), do: x

        @doc "It is what `Fixture.I.consumer/1` needs, passed in as an argument."
        def provider, do: 1
      end

      defmodule Fixture.I do
        def public(x), do: helper(x)
        defp helper(x), do: Fixture.H.target(x)

        def consumer(value), do: value
      end
      """

      assert %{problems: [], references: [_, _]} = check([{"lib/h.ex", source}])
    end

    test "a module named on its own owns the bare references after it" do
      source = """
      defmodule Fixture.J do
        @moduledoc "Called from `Fixture.K`'s `run/0` and private `step/0`."
      end

      defmodule Fixture.K do
        def run, do: step()
        defp step, do: :ok
      end
      """

      assert %{problems: [], references: [_, _]} = check([{"lib/j.ex", source}])
    end

    # ex_doc links a qualified reference and `--warnings-as-errors` refuses a private target,
    # which is how #347's first pipeline failed in the docs job.
    test "reports a private function written qualified" do
      source = """
      defmodule Fixture.L do
        @moduledoc "Called from `Fixture.M.step/0`."
      end

      defmodule Fixture.M do
        defp step, do: :ok
      end
      """

      assert %{problems: [problem]} = check([{"lib/l.ex", source}])
      assert problem =~ "Fixture.M.step/0 is private"
    end

    test "leaves a function outside the project, and a claim naming nothing, alone" do
      source = """
      defmodule Fixture.G do
        @doc "So it can stand in the `Agent.update/3` function it is called from."
        def step(x), do: x

        @doc "That is what Layer 3 needs."
        def layered(x), do: x
      end
      """

      assert %{problems: [], references: []} = check([{"lib/g.ex", source}])
    end
  end

  # ── The checker ──

  defp lib_sources do
    for path <- Path.wildcard(Path.join(@root, "lib/**/*.ex")) |> Enum.sort(),
        do: {Path.relative_to(path, @root), File.read!(path)}
  end

  @doc false
  def check(sources) do
    modules = Enum.flat_map(sources, fn {file, source} -> modules(file, source) end)
    index = Map.new(modules, &{&1.name, &1.functions})

    checked =
      for module <- modules,
          {subject, text} <- module.docs,
          sentence <- sentences(text),
          Regex.match?(@claim, sentence),
          reference <- references(sentence, module.name),
          Map.has_key?(index, reference.module) or project?(reference.module),
          do: {module, subject, reference, verify(index, module, subject, reference)}

    %{
      references: for({m, _, r, _} <- checked, do: "#{m.file}: #{label(r)}"),
      problems: for({m, _, _, {:error, why}} <- checked, do: "#{m.file}: #{why}")
    }
  end

  defp project?(module), do: String.starts_with?(module, ["ExTLA", "Mix.Tasks.Extla"])

  defp verify(index, module, subject, reference) do
    case find(index, reference) do
      nil ->
        {:error, "#{label(reference)} does not exist"}

      # ex_doc links a qualified reference, and `--warnings-as-errors` refuses a link to a
      # private function. Written bare after its module, it reads the same and is not linked.
      %{private?: true} when reference.qualified? ->
        {:error,
         "#{label(reference)} is private, and written qualified ex_doc links it and fails " <>
           "the docs job; name `#{reference.module}`, then write `#{reference.name}/#{reference.arity}` bare"}

      _caller when subject == :moduledoc or not reference.called? ->
        :ok

      caller ->
        {name, arities} = subject

        if reaches?(index, reference.module, caller, name, arities),
          do: :ok,
          else:
            {:error,
             "#{label(reference)} does not call #{name}/#{Enum.max(arities)} " <>
               "(documented in #{module.name})"}
    end
  end

  defp find(index, %{module: module, name: name, arity: arity}) do
    index
    |> Map.get(module, [])
    |> Enum.find(fn function -> function.name == name and arity in function.arities end)
  end

  defp label(r), do: "#{r.module}.#{r.name}/#{r.arity}"

  # Each sentence's references, with a bare `f/a` belonging to the last module named.
  defp references(sentence, documented) do
    # Only a reference after a "calls" verb is named as a caller.
    verb_at =
      case Regex.run(@calls, sentence, return: :index) do
        [{at, _} | _] -> at
        nil -> byte_size(sentence)
      end

    {found, _} =
      @reference
      |> Regex.scan(sentence, return: :index)
      |> Enum.flat_map_reduce(documented, fn [{at, _} | groups], last ->
        part = fn index ->
          case Enum.at(groups, index, {-1, 0}) do
            {start, length} when start >= 0 and length > 0 -> binary_part(sentence, start, length)
            _ -> nil
          end
        end

        case {part.(0), part.(1), part.(3)} do
          # A module on its own: what a bare reference after it belongs to.
          {module, nil, nil} ->
            {[], module}

          {module, name, nil} ->
            {[reference(module, name, part.(2), true, at > verb_at)], module}

          {nil, nil, name} ->
            {[reference(last, name, part.(4), false, at > verb_at)], last}
        end
      end)

    found
  end

  defp reference(module, name, arity, qualified?, called?) do
    %{
      module: module,
      name: String.to_atom(name),
      arity: String.to_integer(arity),
      qualified?: qualified?,
      called?: called?
    }
  end

  # Sentences, with a doc's line breaks joined so one can span lines.
  defp sentences(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.split(~r/(?<=[.!?])\s+(?=[A-Z`])/)
  end

  # ── Reading the source ──

  defp modules(file, source) do
    source
    |> Code.string_to_quoted!()
    |> collect_modules(nil, file)
  end

  defp collect_modules({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent, file) do
    name = Enum.join(Enum.reject([parent | parts], &is_nil/1) |> Enum.map(&to_string/1), ".")
    forms = forms(body)

    [%{name: name, file: file, functions: functions(forms), docs: docs(forms)}] ++
      Enum.flat_map(forms, &collect_modules(&1, name, file))
  end

  defp collect_modules({:__block__, _, forms}, parent, file),
    do: Enum.flat_map(forms, &collect_modules(&1, parent, file))

  defp collect_modules(_form, _parent, _file), do: []

  # A module body's top-level forms, in order, looking through `if`/`unless` (a function
  # defined only when a dependency is loaded is still defined, with its docs).
  defp forms({:__block__, _, forms}), do: Enum.flat_map(forms, &forms/1)

  defp forms({conditional, _, [_condition, branches]})
       when conditional in [:if, :unless] and is_list(branches),
       do: Enum.flat_map(Keyword.values(branches), &forms/1)

  defp forms(form), do: [form]

  @definers [:def, :defp, :defmacro, :defmacrop]

  defp functions(forms) do
    for form <- forms, function = definition(form), function != nil, do: function
  end

  defp definition({definer, _, [head | rest]}) when definer in @definers do
    {name, args} = call(head)
    defaults = Enum.count(args, &match?({:\\, _, _}, &1))
    body = with [[{:do, body} | _]] <- rest, do: body

    %{
      name: name,
      arities: Enum.to_list((length(args) - defaults)..length(args)),
      body: body,
      private?: definer in [:defp, :defmacrop]
    }
  end

  defp definition({:defdelegate, _, [head, options]}) do
    {name, args} = call(head)
    target = Keyword.get(options, :as, name)
    body = {{:., [], [Keyword.fetch!(options, :to), target]}, [], args}

    %{name: name, arities: [length(args)], body: body, private?: false}
  end

  defp definition(_form), do: nil

  defp call({:when, _, [head | _]}), do: call(head)
  defp call({name, _, args}) when is_list(args), do: {name, args}
  defp call({name, _, _}), do: {name, []}

  # Each doc with what it documents: `:moduledoc`, or the `{name, arities}` of the next
  # definition after a `@doc`.
  defp docs(forms) do
    {docs, _pending} =
      Enum.reduce(forms, {[], nil}, fn
        {:@, _, [{:moduledoc, _, [value]}]}, {docs, pending} ->
          {add(docs, :moduledoc, text(value)), pending}

        {:@, _, [{:doc, _, [value]}]}, {docs, _pending} ->
          {docs, text(value)}

        form, {docs, pending} when is_binary(pending) ->
          case definition(form) do
            nil -> {docs, pending}
            function -> {add(docs, {function.name, function.arities}, pending), nil}
          end

        _form, acc ->
          acc
      end)

    Enum.reverse(docs)
  end

  defp add(docs, _subject, nil), do: docs
  defp add(docs, subject, text), do: [{subject, text} | docs]

  defp text(value) when is_binary(value), do: value
  defp text({:sigil_S, _, [{:<<>>, _, [value]}, _]}), do: value
  defp text({:<<>>, _, parts}), do: parts |> Enum.filter(&is_binary/1) |> Enum.join()
  defp text(_false_or_other), do: nil

  # Whether `caller` calls or captures `name` at one of `arities`, directly or through the
  # functions of its own module it calls locally: "`action_sequences/3` walks" is true of
  # the private `walk/4` that does the calling.
  defp reaches?(index, module, caller, name, arities) do
    functions = Map.fetch!(index, module)
    reach(functions, [caller], MapSet.new(), name, arities)
  end

  defp reach(_functions, [], _seen, _name, _arities), do: false

  defp reach(functions, [function | rest], seen, name, arities) do
    called = calls(function.body)

    if Enum.any?(called, fn {_, called_name, arity} ->
         called_name == name and arity in arities
       end) do
      true
    else
      seen = MapSet.put(seen, function)

      local =
        for {:local, called_name, arity} <- called,
            next <- functions,
            next.name == called_name and arity in next.arities,
            next not in seen,
            do: next

      reach(functions, rest ++ Enum.uniq(local), seen, name, arities)
    end
  end

  # Every call and capture in a body, as `{:local | :remote, name, arity}`.
  defp calls(body) do
    {_, found} =
      Macro.prewalk(body, [], fn
        {:&, _, [{:/, _, [reference, arity]}]} = node, acc when is_integer(arity) ->
          {node, add_call(acc, reference, arity)}

        {_, _, args} = node, acc when is_list(args) ->
          {node, add_call(acc, node, length(args))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp add_call(acc, {{:., _, [_module, name]}, _, _}, arity) when is_atom(name),
    do: [{:remote, name, arity} | acc]

  defp add_call(acc, {name, _, _}, arity) when is_atom(name), do: [{:local, name, arity} | acc]
  defp add_call(acc, _node, _arity), do: acc
end
