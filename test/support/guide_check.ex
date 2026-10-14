defmodule ExTLA.GuideCheck do
  @moduledoc """
  Runs ExTLA on the code blocks in `guides/`, and asserts the outcome each block claims (#94, #95).

  ## Why the snippet is the only copy

  The obvious way to keep a guide honest is to hold the real spec in `test/` and check the guide's
  block against it. That is two copies which must be kept in step — the duplication that let
  `README.md` drift two phases out of date (#73/#80). Here the block in the markdown IS the source:
  it is compiled from the page the reader sees, so it cannot disagree with itself.

  ## A block declares what it is for

  Compiling is not the claim worth checking. A guide can compile perfectly and still narrate "this
  reports `:ok`" about a spec that reports a violation — and a reader trusts the prose over the
  code. So each block says what it expects, in an HTML comment on the line before its fence, and
  this module enforces exactly that:

      <!-- tla:spec -->                                  compiles; later blocks may refer to it
      <!-- tla:compile_error match="not declared" -->    MEANT to fail; the message must match
      <!-- tla:skip reason=... -->                       not executable, and the reason is on the page

      <!-- tla:check module=M expect=ok -->              the run reports :ok
      <!-- tla:check module=M expect=ok states=8 depth=4 -->   ...and found that many, that deep
      <!-- tla:check module=M expect=ok never_enabled=cancel -->  ...with THAT action never enabled
      <!-- tla:check module=M expect=ok symmetry=clients states=7 -->  under the reduction
      <!-- tla:check module=M expect=unsound_symmetry symmetry=clients -->  verify_symmetry refuses it
      <!-- tla:check module=M expect=incomplete max_states=100 -->   the run was BOUNDED, not verified
      <!-- tla:check module=M expect=violation length=6 -->    violated, shortest trace that long
      <!-- tla:check module=M expect=violation property=at_most_two -->   by THAT property
      <!-- tla:check module=M expect=deadlock -->        a reachable state nothing admits
      <!-- tla:liveness module=M expect=violation property=no_starvation -->   refuted, that one
      <!-- tla:liveness module=M expect=ok -->           every temporal property holds

      <!-- tla:simulate module=Server expect=ok -->      random traces find nothing (seeded)
      <!-- tla:simulate module=Server expect=violation match="DIVERGED" -->   ...or find that
      <!-- tla:run expect=ok -->                         the block evaluates without raising
      <!-- tla:run expect=raise match="only the holder releases" -->   it raises, with that message

  `tla:check`, `tla:liveness` and `tla:simulate` claim a run rather than code, so their comment
  may stand alone, beside the command whose output the page quotes; the other kinds annotate the
  fence below them.

  **An unannotated `elixir` block is an unchecked claim and is rejected.** Requiring an explicit
  `tla:skip reason=` makes a gap visible instead of silent — the principle `TLA_COVERAGE.md`
  applies to spec items, applied to prose: something nobody verified is recorded as unverified,
  never omitted.

  ## Why a comment, and not the fence's info string

  The first version of this harness put the annotation on the fence itself — `` ```elixir
  tla:spec ``. Earmark, which renders the guides under `mix docs`, accepts a single word after the
  backticks and nothing else: `` ```elixir tla:spec `` is not a fence to it, and the whole block
  came out as one run of inline text. Found by #96, the first guide to meet `mix docs`. An HTML
  comment is dropped by Earmark and by GitLab alike, so the reader sees a plain `elixir` block and
  the harness sees the claim. A fence with anything after `elixir` is rejected here for the same
  reason, so the mistake cannot be made again quietly.

  ## Pages are checked in sorted path order, and that order is a dependency

  `guides/` is a tree: the tutorial is `guides/tutorial/NN-name.md`, read in order. A page may
  refer to a module an **earlier** page compiled — the tutorial's Layer 3 page checks a server
  against the lock declared on its DSL page — so `guides/0` walks `guides/**/*.md` sorted by path,
  which for `NN-` names is reading order. The numbering IS the dependency.

  The alternative was to re-show every module on every page that mentions it. That is more copies
  of one spec, which is the defect this module exists to prevent (#94).

  ## What is deliberately NOT asserted

  Only what a block claims. A block declaring `expect=ok` and no `states=` is not failed for its
  state count. An over-tight harness makes guides unwritable, and #79 is the precedent for a check
  asserting more than the design promises.
  """

  alias ExTLA.GuideCheck.{Links, Output}
  alias ExTLA.{ModelChecker, Simulation, Spec}

  # An optional `<!-- tla:... -->` on the line IMMEDIATELY before a ```elixir fence, then the
  # fence's trailing info string (which must be empty — see the moduledoc), then the code.
  @fence ~r/(?:^[ \t]*<!--[ \t]*(tla:[^\n]*?)[ \t]*-->[ \t]*\n)?^```elixir([^\n]*)\n(.*?)^```/ms

  # A run-claim with no fence under it. It claims a run, not code, so it stands beside the
  # command whose output the page quotes rather than above an empty block — which `mix docs`
  # would render as an empty grey box.
  #
  # A bare fence directly under it is the output of that run, and is compared with what the
  # command prints (`ExTLA.GuideCheck.Output`, #409).
  @bare_claim ~r/^[ \t]*<!--[ \t]*(tla:(?:check|liveness|simulate)[^\n]*?)[ \t]*-->[ \t]*$(?!\n```elixir)(?:\n```\n(.*?)^```[ \t]*$)?/ms

  # Output that is not a claim's: the result of the `tla:run` block above it, or with
  # `command="mix …"` the output of that command.
  @output ~r/^[ \t]*<!--[ \t]*(tla:output[^\n]*?)[ \t]*-->[ \t]*\n```\n(.*?)^```[ \t]*$/ms

  # `mix extla.simulate`'s own defaults, and a fixed seed: a claim about a random walk is only a
  # claim if the walk is the same one every time — and with these, it is the walk the page
  # quotes from `mix extla.simulate Server --seed 1`.
  @simulate_defaults %{traces: 100, max_steps: 25, seed: 1}

  @doc """
  Every `elixir` block and every bare run-claim in a guide, in order, as
  `{annotation_map, code, line}`. A bare claim's code is `""`.
  """
  def blocks(path) do
    source = File.read!(path)

    fences =
      @fence
      |> Regex.scan(source, return: :index)
      |> Enum.map(fn [{start, _}, annotation, {info_start, info_len}, {code_start, code_len}] ->
        {start,
         parse_annotation(part(source, annotation), binary_part(source, info_start, info_len)),
         binary_part(source, code_start, code_len)}
      end)

    bare =
      @bare_claim
      |> Regex.scan(source, return: :index)
      |> Enum.map(fn
        [{start, _}, annotation] ->
          {start, parse_tla(part(source, annotation)), ""}

        [{start, _}, annotation, shown] ->
          {start, Map.put(parse_tla(part(source, annotation)), :shown, part(source, shown)), ""}
      end)

    outputs =
      @output
      |> Regex.scan(source, return: :index)
      |> Enum.map(fn [{start, _}, annotation, shown] ->
        {start, parse_tla(part(source, annotation)), part(source, shown)}
      end)

    (fences ++ bare ++ outputs)
    |> Enum.sort()
    |> Enum.map(fn {start, annotation, code} -> {annotation, code, line_of(source, start)} end)
  end

  # An unmatched optional group comes back as `{-1, 0}`.
  defp part(_source, {-1, 0}), do: nil
  defp part(source, {start, len}), do: binary_part(source, start, len)

  @doc """
  Every guide, in the order they must be checked in: sorted by path, which for the tutorial's
  `NN-` names is reading order.
  """
  def guides, do: Enum.sort(Path.wildcard("guides/**/*.md"))

  @doc """
  Every page this harness checks: the guides, then `spec/`, then `README.md` (#281).

  `spec/` holds seventy-odd `elixir` fences that nothing compiled. They are not a tutorial —
  most are API sketches whose signatures `spec_api_test` already holds to `API_SURFACE.md` —
  but "nothing compiles this" and "something else gates this" are different facts, and only
  one of them is acceptable silently. Under this harness each block says which it is.

  Sorted within each tree, because within a tree the order is a dependency: `spec/07`'s
  `MyApp.LockServer` conforms to the `Specs.DistributedLock` declared earlier on its own
  page. Across trees there are none — a spec page has never referred to a guide's module —
  so the trees are concatenated in the order a reader meets them rather than interleaved.
  """
  def pages do
    guides() ++ Enum.sort(Path.wildcard("spec/**/*.md")) ++ ["README.md", "usage-rules.md"]
  end

  @doc """
  Check one guide. Returns a list of failure strings — empty when the guide tells the truth.
  """
  def check(path, opts \\ []) do
    # A guide that shows the tool refusing something crashes a process on purpose — a
    # `compile_error` block, a Layer 1 precondition, a leaky server under simulation — and the
    # emulator's crash report for each would land in the test output as though something had gone
    # wrong. Every crash here is read out of a DOWN reason and reported as a failure string if it
    # was not the one claimed, so nothing is lost by not logging it; the report is noise.
    level = Logger.level()
    Logger.configure(level: :none)

    # The last `tla:run` block's outcome travels to a `tla:output` block under it.
    {claims, _last_run} =
      Enum.flat_map_reduce(blocks(path), nil, fn {annotation, code, line}, last_run ->
        {result, last_run} = verify_block(annotation, code, last_run, opts)

        case result do
          :ok -> {[], last_run}
          {:error, why} -> {["#{path}:#{line}: #{why}"], last_run}
        end
      end)

    failures = claims ++ unchecked_output(path) ++ Links.check(path)

    # The emulator delivers a crash report asynchronously; without the flush it would arrive
    # after the level is restored and print anyway.
    Logger.flush()
    Logger.configure(level: level)
    failures
  end

  # --- the blocks -----------------------------------------------------------------------

  # A `tla:run` block is evaluated once, and its outcome is both checked and kept for the
  # `tla:output` block that may follow.
  defp verify_block(%{kind: :run} = annotation, code, _last_run, _opts) do
    outcome = evaluate_run(code)
    {verify_run(annotation, outcome), outcome}
  end

  defp verify_block(%{kind: :output} = annotation, shown, last_run, opts) do
    {verify_output(annotation, shown, last_run, opts), last_run}
  end

  defp verify_block(annotation, code, last_run, opts) do
    result =
      with :ok <- verify(annotation, code) do
        claimed_output(annotation, opts)
      end

    {result, last_run}
  end

  # --- output blocks (#409) ---------------------------------------------------------------

  # A claim with no block under it shows no output, and there is nothing to compare.
  defp claimed_output(%{shown: shown} = annotation, opts) when is_binary(shown) do
    case cli_argv(annotation) do
      {:ok, argv, env} ->
        real = with_env(env, opts, fn -> Output.task(argv) end)
        compare_output(shown, real, annotation, opts)

      {:error, _} = error ->
        error
    end
  end

  defp claimed_output(_annotation, _opts), do: :ok

  defp verify_output(%{command: command} = annotation, shown, _last_run, opts) do
    case OptionParser.split(command) do
      ["mix" | argv] ->
        compare_output(shown, with_env([], opts, fn -> Output.task(argv) end), annotation, opts)

      _other ->
        {:error, "tla:output command=#{inspect(command)} is not a `mix` command"}
    end
  end

  defp verify_output(annotation, shown, {:ok, value}, opts) when is_binary(value),
    do: compare_output(shown, value, annotation, opts)

  defp verify_output(annotation, shown, {:raised_exception, exception}, opts),
    do: compare_output(shown, raised_text(exception), annotation, opts)

  defp verify_output(_annotation, _shown, nil, _opts),
    do:
      {:error,
       "tla:output with no command= follows no tla:run block, so it shows nothing's output"}

  defp verify_output(_annotation, _shown, outcome, _opts),
    do:
      {:error,
       "tla:output shows the result of the tla:run block above it, which produced " <>
         "#{inspect(outcome)} rather than text or an exception"}

  # `collect:` names a process that is sent `{:guide_output, shown, real, mode}` for every block
  # compared, which is how the blocks are regenerated from real output rather than retyped.
  defp compare_output(shown, real, annotation, opts) do
    if pid = opts[:collect], do: send(pid, {:guide_output, shown, real, mode(annotation)})
    Output.compare(shown, real, mode(annotation))
  end

  # How a raised exception reads where it is not caught: `** (Module) message`.
  defp raised_text(exception),
    do: "** (#{inspect(exception.__struct__)}) " <> Exception.message(exception)

  defp mode(%{output: "abridged"}), do: :abridged
  defp mode(_annotation), do: :exact

  # The command a claim's output came from. It is derived from the claim rather than read from
  # the page's ```sh block, because the claim is what the harness runs: a block quoting the
  # output of one command under the shell line of another would otherwise pass.
  #
  # Symmetry is not a flag. A reader declares it in config, `config :extla, Spec, symmetry:`,
  # and so does this: `env` is that config, applied around the run by the caller's `with_env`.
  defp cli_argv(%{kind: kind, module: module} = annotation) when kind in [:check, :liveness] do
    flags =
      Enum.concat([
        if(limit = annotation[:max_states], do: ["--max-states", limit], else: []),
        if(annotation[:verify_symmetry] == "true" or annotation[:expect] == "unsound_symmetry",
          do: ["--verify-symmetry"],
          else: []
        )
      ])

    env =
      case annotation[:symmetry] do
        nil ->
          []

        names ->
          [
            {Module.concat([module]),
             symmetry: names |> String.split(",") |> Enum.map(&String.to_atom/1)}
          ]
      end

    {:ok, ["extla.check", module | flags], env}
  end

  defp cli_argv(%{kind: :simulate, module: module} = annotation) do
    flags =
      Enum.flat_map([traces: "--traces", steps: "--steps"], fn {key, flag} ->
        if value = annotation[key], do: [flag, value], else: []
      end)

    {:ok, ["extla.simulate", module, "--seed", annotation[:seed] || "1" | flags], []}
  end

  defp cli_argv(%{kind: kind}),
    do: {:error, "a #{kind} claim has no command whose output a block could show"}

  # Config the command reads, such as a spec's `symmetry:`, is application env, which this
  # module may not write (`test/docs/async_isolation_test.exs`): the caller supplies
  # `with_env:`, a function `(env, fun) -> result` that applies `env` around `fun`. A test that
  # passes one is a test that may write global state, and says so where it is written.
  defp with_env([], _opts, fun), do: fun.()

  defp with_env(env, opts, fun) do
    case opts[:with_env] do
      nil ->
        "** this output needs config (#{inspect(env)}) and the check was given no `with_env:`\n"

      apply_env ->
        apply_env.(env, fun)
    end
  end

  # A bare fence in a guide renders as output. One that is neither a claim's output nor a
  # `tla:output` block is output nothing checks, which is how the blocks drifted (#409); text
  # that is not output says what it is with a language, ```text or ```sh.
  defp unchecked_output(path) do
    if String.starts_with?(path, "guides/") or String.contains?(path, "/guides/"),
      do: bare_fences(path),
      else: []
  end

  defp bare_fences(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false, nil}, fn {line, number}, {found, in_fence, previous} ->
      cond do
        in_fence ->
          {found, not String.starts_with?(line, "```"), line}

        String.trim_trailing(line) == "```" ->
          checked =
            previous &&
              Regex.match?(~r/^\s*<!--\s*tla:(check|liveness|simulate|output)\b/, previous)

          found = if checked, do: found, else: [number | found]
          {found, true, line}

        String.starts_with?(line, "```") ->
          {found, true, line}

        true ->
          {found, false, line}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(fn number ->
      "#{path}:#{number}: a bare ``` block renders as output, and nothing checks it. Put the " <>
        "claim whose output it is on the line above (tla:check, tla:liveness, tla:simulate), or " <>
        "<!-- tla:output --> for a tla:run block's result or command=\"mix …\"; text that is " <>
        "not output takes a language (```text, ```sh)"
    end)
  end

  # --- the annotations ------------------------------------------------------------------

  defp verify(%{kind: :bad_fence, info: info}, _code),
    do:
      {:error,
       "```elixir#{info} is not a fence Earmark recognises, so `mix docs` renders the block " <>
         "as inline text. Put the annotation in an HTML comment on the line before: " <>
         "<!-- tla:... -->"}

  defp verify(%{kind: :none}, _code),
    do:
      {:error,
       "an `elixir` block with no annotation is an unchecked claim. Give it one on the line " <>
         "before the fence (<!-- tla:spec -->, tla:check, tla:liveness, tla:compile_error, " <>
         "tla:simulate, tla:run) or <!-- tla:skip reason=... -->"}

  # A bare `tla:skip` was accepted until #281, which makes the harness's own principle
  # false: "an unannotated block is an unchecked claim" is enforced one line up, and a
  # reasonless skip is an unchecked claim wearing an annotation. The reason is what a
  # reader sees on the page — #215's point, and `TLA_COVERAGE.md`'s: something nobody
  # verified is recorded as unverified, never omitted.
  # A dependency snippet: not a spec, and checkable anyway (#154).
  #
  # `guides/getting-started.md`'s install block is the repository's only `deps` entry, and
  # it read `tag: "v0.1.0"` against a current release of **v0.3.20** — in documentation
  # that SHIPS in the package, on a page whose next chapter teaches two features that
  # install does not have. Every other Elixir block on that page is compiled and its
  # verdict asserted. The one block the harness was told to skip is the one that drifted.
  #
  # "Not a spec" was true, and was taken to mean "not checkable". A `mix.exs` fragment
  # parses, and a `tag:` is a string that can be compared with the release record, so this
  # directive does that and the block stops being exempt.
  #
  # The record is `CHANGELOG.md`'s newest release heading rather than `git tag`, for two
  # reasons: it is in the tree, so a shallow CI clone with no tags still checks it; and
  # #282 established the changelog as the project's record of what is built, so tying the
  # install instruction to it means one place goes stale instead of two.
  #
  # The `git:` URL is held to `mix.exs`'s `source_url`, the repository the package names as
  # its public home (#402). An install line pointing anywhere else, such as the private
  # instance where day-to-day work happens, is one a public reader can't follow.
  defp verify(%{kind: :deps}, code) do
    with {:ok, opts} <- documented_dep(code),
         {:ok, release} <- newest_release(),
         :ok <- deps_tag(opts[:tag], release) do
      deps_url(opts[:git])
    end
  end

  defp verify(%{kind: :skip} = annotation, _code) do
    case annotation[:reason] do
      reason when is_binary(reason) and reason != "" ->
        :ok

      _missing ->
        {:error,
         "tla:skip needs a reason: <!-- tla:skip reason=why this block is not compiled -->. " <>
           "A skip without one records that a block is unchecked and not why, which is the " <>
           "gap this annotation exists to make visible."}
    end
  end

  defp verify(%{kind: :spec}, code) do
    case compile(code) do
      {:ok, _modules} -> :ok
      {:raised, message} -> {:error, "tla:spec does not compile: #{message}"}
    end
  end

  # A block that is SUPPOSED to fail. Compiling successfully is the failure here.
  defp verify(%{kind: :compile_error} = annotation, code) do
    case compile(code) do
      {:ok, _modules} ->
        {:error, "tla:compile_error compiled successfully, so the guide's error is not real"}

      {:raised, message} ->
        matched(message, annotation[:match], "the error")
    end
  end

  defp verify(%{kind: :simulate} = annotation, _code) do
    module = Module.concat([annotation.module])

    config =
      Enum.reduce([traces: :traces, steps: :max_steps, seed: :seed], @simulate_defaults, fn
        {key, config_key}, acc ->
          case annotation[key] do
            nil -> acc
            value -> Map.put(acc, config_key, String.to_integer(value))
          end
      end)

    case {annotation[:expect], simulate(module, config)} do
      {_, {:raised, message}} ->
        {:error, "the simulation raised: #{message}"}

      {"ok", {:ok, %{status: :ok}}} ->
        :ok

      {"ok", {:ok, result}} ->
        {:error,
         "the guide claims the simulation finds nothing, but it reports " <>
           "#{inspect(result.status)}" <> simulation_finding(result)}

      {"violation", {:ok, %{status: :violation} = result}} ->
        matched(result.violation.message, annotation[:match], "the violation")

      {"violation", {:ok, result}} ->
        {:error,
         "the guide claims the simulation finds a violation, but it reports " <>
           "#{inspect(result.status)}"}

      {other, _} ->
        {:error, "unknown expect=#{inspect(other)} for tla:simulate (ok or violation)"}
    end
  end

  defp verify(%{kind: kind} = annotation, _code) when kind in [:check, :liveness] do
    module = Module.concat([annotation.module])

    case {annotation[:expect], run(module, config(kind, annotation))} do
      {"unsound_symmetry", {:raised, message}} ->
        if message =~ "is not sound" do
          :ok
        else
          {:error, "the run raised, but not because the symmetry was unsound: #{message}"}
        end

      {"unsound_symmetry", {:ok, result}} ->
        {:error,
         "the guide claims the symmetry declaration is unsound, but the run reported " <>
           "#{inspect(result.status)} with and without the reduction"}

      {_, {:raised, message}} ->
        {:error, "the run raised: #{message}"}

      {_, {:ok, result}} ->
        with :ok <- compare(result, annotation), do: census(result, annotation)
    end
  end

  # A block that runs — a GenServer driven by hand, a replay — and either returns or raises.
  # `expect=raise` is how a guide shows Layer 1 refusing a call: the server's exception arrives
  # here as the caller's exit, and `describe/1` digs it out.
  defp verify_run(annotation, {:raised_exception, exception}),
    do: verify_run(annotation, {:raised, Exception.message(exception)})

  defp verify_run(annotation, outcome) do
    case {annotation[:expect], outcome} do
      {"ok", {:ok, _value}} ->
        :ok

      {"ok", {:raised, message}} ->
        {:error, "the guide claims this runs, but it raised: #{message}"}

      {"raise", {:raised, message}} ->
        matched(message, annotation[:match], "the exception")

      {"raise", {:ok, value}} ->
        {:error, "the guide claims this raises, but it returned #{inspect(value)}"}

      {other, _} ->
        {:error, "unknown expect=#{inspect(other)} for tla:run (ok or raise)"}
    end
  end

  defp config(kind, annotation) do
    %{}
    |> Map.merge(if kind == :liveness, do: %{check_liveness: true}, else: %{})
    |> Map.merge(symmetry_config(annotation))
    |> Map.merge(max_states_config(annotation))
  end

  # A guide teaching what a BOUND does to a verdict has to be able to impose one.
  defp max_states_config(%{max_states: limit}),
    do: %{max_states: String.to_integer(limit)}

  defp max_states_config(_annotation), do: %{}

  defp symmetry_config(%{symmetry: names} = annotation) do
    %{
      symmetry: names |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1),
      verify_symmetry:
        annotation[:verify_symmetry] == "true" or annotation[:expect] == "unsound_symmetry"
    }
  end

  defp symmetry_config(_annotation), do: %{}

  defp compare(result, %{expect: "ok"} = _annotation) do
    if result.status == :ok do
      :ok
    else
      {:error,
       "the guide claims this reports :ok, but it reports #{inspect(result.status)}" <>
         violated_by(result)}
    end
  end

  defp compare(result, %{expect: "violation"} = annotation) do
    # `invariant=` is the name #95 gave this claim; `property=` is the one that also reads
    # right for a refuted temporal property. Both mean "violated by THAT one".
    claimed = annotation[:property] || annotation[:invariant]

    cond do
      result.status != :violation ->
        {:error, "the guide claims a violation, but the run reports #{inspect(result.status)}"}

      annotation[:length] && trace_length(result) != String.to_integer(annotation[:length]) ->
        {:error,
         "the guide claims a #{annotation[:length]}-step counterexample, " <>
           "but the shortest is #{inspect(trace_length(result))}"}

      claimed && to_string(violated_property(result)) != claimed ->
        {:error,
         "the guide claims #{claimed} is violated, " <>
           "but the violated property is #{inspect(violated_property(result))}"}

      true ->
        :ok
    end
  end

  # "The run ran out of budget" is a THIRD outcome beside verified and violated, and the guide
  # that explains it must be able to claim it — otherwise the page teaching that a green run is a
  # proof about the model would itself be making an unchecked claim.
  defp compare(result, %{expect: "incomplete"}) do
    if result.status in [:max_states_reached, :constrained] do
      :ok
    else
      {:error,
       "the guide claims the run was bounded, but it reports #{inspect(result.status)}" <>
         violated_by(result) <>
         " — an `expect=incomplete` claim needs `max_states=` small enough to bite"}
    end
  end

  # A deadlock is worth teaching in its own right, and it does not fit `expect=violation
  # property=`: it arrives as a trace whose `property` is nil and whose `type` is :deadlock.
  defp compare(result, %{expect: "deadlock"}) do
    case result.violation do
      %{type: :deadlock} ->
        :ok

      _ ->
        {:error,
         "the guide claims a deadlock, but the run reports #{inspect(result.status)}" <>
           violated_by(result)}
    end
  end

  defp compare(_result, annotation),
    do: {:error, "unknown expect=#{inspect(annotation[:expect])}"}

  # The numbers a guide quotes from the run's summary line and coverage table. A reader will
  # believe "8 distinct states, depth 4" exactly as much as the verdict beside it, so a block
  # may claim them and then they are held to.
  defp census(result, annotation) do
    cond do
      annotation[:states] && result.distinct_states != String.to_integer(annotation[:states]) ->
        {:error,
         "the guide claims #{annotation[:states]} distinct states, " <>
           "but the run found #{result.distinct_states}"}

      annotation[:depth] && result.diameter != String.to_integer(annotation[:depth]) ->
        {:error,
         "the guide claims depth #{annotation[:depth]}, but the run reached #{result.diameter}"}

      annotation[:never_enabled] && never_enabled(annotation) != result.coverage.never_enabled ->
        {:error,
         "the guide claims #{inspect(never_enabled(annotation))} were never enabled, " <>
           "but the run reports #{inspect(result.coverage.never_enabled)}"}

      true ->
        :ok
    end
  end

  defp never_enabled(%{never_enabled: names}),
    do: names |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1) |> Enum.sort()

  # A safety counterexample is a trace; a liveness one is a lasso, and the property it refutes
  # is on the prefix.
  defp violated_property(%{violation: %{prefix: %{property: property}}}), do: property
  defp violated_property(%{violation: %{property: property}}), do: property
  defp violated_property(_result), do: nil

  defp trace_length(%{violation: %{prefix: _}}), do: :"a lasso, not a trace"
  defp trace_length(%{violation: %{length: length}}), do: length

  defp violated_by(%{violation: %{type: :deadlock}}),
    do: " (a state has no successors and no `terminal` admits it)"

  defp violated_by(%{violation: _} = result) do
    case violated_property(result) do
      nil -> ""
      property -> " (#{property} is violated)"
    end
  end

  defp violated_by(_), do: ""

  defp simulation_finding(%{violation: %{message: message}}),
    do: ":\n    " <> (message |> String.split("\n") |> hd())

  defp simulation_finding(_result), do: ""

  defp matched(message, nil, _what), do: if(message, do: :ok, else: {:error, "no message"})

  defp matched(message, expected, what) do
    if String.contains?(message, expected) do
      :ok
    else
      {:error, "expected #{what} to contain #{inspect(expected)}, got:\n    #{message}"}
    end
  end

  # --- running things that may blow up --------------------------------------------------

  # No try/rescue (CLAUDE.md). The work happens in a monitored process and an exception is READ
  # out of the DOWN reason rather than caught, so nothing is swallowed and a crash that was not
  # expected still surfaces as one.
  defp compile(code), do: isolated(fn -> Code.compile_string(code, "guide") end)

  # The exception itself is kept, not only its message, so a `tla:output` block can show it the
  # way it reads uncaught.
  defp evaluate_run(code) do
    case isolated_reason(fn -> code |> Code.eval_string([], file: "guide") |> elem(0) end) do
      {:ok, value} ->
        {:ok, value}

      {:down, reason} ->
        case find_exception(reason) do
          nil -> {:raised, describe(reason)}
          exception -> {:raised_exception, exception}
        end
    end
  end

  defp simulate(module, config), do: isolated(fn -> Simulation.run(module, config) end)

  # Constants come from `default:` the way a reader's `mix extla.check` takes them, through the same
  # `Spec.Compiled.resolve_constants/1` the task calls. A guide spec whose constant has no default
  # is a spec the reader cannot run, and it fails here rather than working by way of a config file
  # the page never showed.
  defp run(module, config) do
    isolated(fn ->
      spec = Spec.Compiled.from_module(module)

      case Spec.Compiled.resolve_constants(spec) do
        {:ok, constants} ->
          ModelChecker.run(spec, Map.put(config, :constants, constants))

        {:error, missing} ->
          raise ArgumentError,
                "#{inspect(module)} has no assignment for #{inspect(missing)}; a guide spec " <>
                  "must declare `default:` beside each constant, because the reader has no config"
      end
    end)
  end

  defp isolated(fun) do
    case isolated_reason(fun) do
      {:down, reason} -> {:raised, describe(reason)}
      other -> other
    end
  end

  defp isolated_reason(fun) do
    parent = self()

    # Two guide blocks may define the same module name, and redefinition warns rather than
    # fails. `Code.with_diagnostics/1` collects those warnings in this process instead of
    # printing them. It replaces `Code.put_compiler_option(:ignore_module_conflict, true)`,
    # which set the option for the whole VM (#367, as #325 did for moduledoc examples). A
    # module under `test/support/` cannot know whether its caller runs async, so it may not
    # touch VM-global state at all (`test/docs/async_isolation_test.exs`).
    {_pid, ref} =
      spawn_monitor(fn ->
        {value, _diagnostics} = Code.with_diagnostics(fun)
        send(parent, {:result, value})
      end)

    receive do
      {:result, value} ->
        Process.demonitor(ref, [:flush])
        {:ok, value}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:down, reason}
    after
      60_000 -> {:down, "timed out after 60s"}
    end
  end

  # The exception may be the reason itself, or nested inside an exit — a `GenServer.call` whose
  # server raised exits the caller with `{{exception, stacktrace}, {GenServer, :call, args}}`.
  # An Erlang error (`{:function_clause, stacktrace}`) is not a struct; `format_exit/1` renders
  # those the way a crash report would.
  defp describe(reason) do
    case find_exception(reason) do
      nil -> Exception.format_exit(reason)
      exception -> Exception.message(exception)
    end
  end

  defp find_exception(term) when is_exception(term), do: term

  defp find_exception(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.find_value(&find_exception/1)

  defp find_exception(_term), do: nil

  # --- parsing --------------------------------------------------------------------------

  # The fence's own info string is checked first: a block that will not render is wrong before
  # its claim is even read.
  defp parse_annotation(comment, info) do
    cond do
      String.trim(info) != "" -> %{kind: :bad_fence, info: info}
      comment == nil -> %{kind: :none}
      true -> parse_tla(comment)
    end
  end

  defp parse_tla(info) do
    [head | _] = String.split(info, " ", trim: true)
    kind = head |> String.replace_prefix("tla:", "") |> String.to_atom()

    # Values may be quoted and contain spaces -- `match="not declared"` is the whole point of the
    # compile_error annotation. Splitting on whitespace silently truncated that to `"not`, which
    # matches almost any message, so the check passed while asserting nearly nothing. Caught by
    # the test that feeds it a message the code will never produce.
    ~r/(\w+)=(?:"([^"]*)"|(\S+))/
    |> Regex.scan(info)
    |> Enum.reduce(%{kind: kind}, fn
      [_, key, quoted], acc -> Map.put(acc, String.to_atom(key), quoted)
      [_, key, "", bare], acc -> Map.put(acc, String.to_atom(key), bare)
      [_, key, quoted, _], acc -> Map.put(acc, String.to_atom(key), quoted)
    end)
    |> whole_reason(info)
  end

  # `reason=` runs to the end of the annotation. Every other value is a token — a module
  # name, a count, a property — and the scan above reads one; a reason is a sentence, and
  # the scan read `reason=a shell invocation, and the timing below is from this machine` as
  # the word "a". Nothing failed, because nothing had ever asked what a reason SAID. #281
  # does, so it has to be the whole of it.
  defp whole_reason(annotation, info) do
    case Regex.run(~r/\breason=(.+)$/s, info) do
      [_match, reason] -> Map.put(annotation, :reason, reason |> String.trim() |> unquote_value())
      nil -> annotation
    end
  end

  defp unquote_value(<<?", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_value(value), do: value

  defp deps_tag(tag, release) do
    if tag == "v" <> release do
      :ok
    else
      {:error,
       "tla:deps documents #{inspect(tag)}, and the newest release in CHANGELOG.md is " <>
         "v#{release}. A reader follows this block and gets a version the rest of the " <>
         "page does not describe — which is how v0.1.0 came to be the published install " <>
         "instruction for v0.3.20 (#154). Update the tag with the release."}
    end
  end

  defp deps_url(git) do
    expected = Mix.Project.config()[:source_url] <> ".git"

    if git == expected do
      :ok
    else
      {:error,
       "tla:deps installs from #{inspect(git)}, and mix.exs's source_url says the public " <>
         "repository is #{inspect(expected)}. A reader who can't reach the first can't " <>
         "install (#402)."}
    end
  end

  # The `:extla` dependency's options, wherever in the snippet it sits.
  defp documented_dep(code) do
    with {:ok, ast} <- Code.string_to_quoted(code),
         {_ast, opts} when is_list(opts) <- Macro.prewalk(ast, nil, &extla_dep/2) |> elem_pair(),
         tag when is_binary(tag) <- Keyword.get(opts, :tag) do
      {:ok, opts}
    else
      {:error, {meta, message, token}} ->
        {:error, "tla:deps does not parse: #{message}#{token} (line #{meta[:line]})"}

      _no_tag ->
        {:error,
         "tla:deps has no `{:extla, …, tag: \"…\"}` entry. The directive exists to hold " <>
           "that tag to the release record; a block without one is either a different " <>
           "kind of snippet (use tla:skip with a reason) or is missing its pin."}
    end
  end

  defp elem_pair({ast, acc}), do: {ast, acc}

  defp extla_dep({:extla, opts} = node, nil) when is_list(opts), do: {node, opts}
  defp extla_dep(node, acc), do: {node, acc}

  # The newest `## [x.y.z] — date` heading. `[Unreleased]` is deliberately not a release:
  # what a reader can install is what has been tagged.
  defp newest_release do
    case Regex.run(~r/^## \[(\d+\.\d+\.\d+)\]/m, File.read!("CHANGELOG.md")) do
      [_match, version] ->
        {:ok, version}

      nil ->
        {:error,
         "CHANGELOG.md has no `## [x.y.z]` release heading, so tla:deps has nothing to " <>
           "check the documented tag against"}
    end
  end

  defp line_of(source, offset) do
    source
    |> binary_part(0, offset)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end
end
