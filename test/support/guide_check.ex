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

  alias ExTLA.GuideCheck.Links
  alias ExTLA.{ModelChecker, Simulation, Spec}

  # An optional `<!-- tla:... -->` on the line IMMEDIATELY before a ```elixir fence, then the
  # fence's trailing info string (which must be empty — see the moduledoc), then the code.
  @fence ~r/(?:^[ \t]*<!--[ \t]*(tla:[^\n]*?)[ \t]*-->[ \t]*\n)?^```elixir([^\n]*)\n(.*?)^```/ms

  # A run-claim with no fence under it. It claims a run, not code, so it stands beside the
  # command whose output the page quotes rather than above an empty block — which `mix docs`
  # would render as an empty grey box.
  @bare_claim ~r/^[ \t]*<!--[ \t]*(tla:(?:check|liveness|simulate)[^\n]*?)[ \t]*-->[ \t]*$(?!\n```elixir)/m

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
      |> Enum.map(fn [{start, _}, annotation] ->
        {start, parse_tla(part(source, annotation)), ""}
      end)

    (fences ++ bare)
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
  def check(path) do
    # A guide that shows the tool refusing something crashes a process on purpose — a
    # `compile_error` block, a Layer 1 precondition, a leaky server under simulation — and the
    # emulator's crash report for each would land in the test output as though something had gone
    # wrong. Every crash here is read out of a DOWN reason and reported as a failure string if it
    # was not the one claimed, so nothing is lost by not logging it; the report is noise.
    level = Logger.level()
    Logger.configure(level: :none)

    claims =
      Enum.flat_map(blocks(path), fn {annotation, code, line} ->
        case verify(annotation, code) do
          :ok -> []
          {:error, why} -> ["#{path}:#{line}: #{why}"]
        end
      end)

    failures = claims ++ Links.check(path)

    # The emulator delivers a crash report asynchronously; without the flush it would arrive
    # after the level is restored and print anyway.
    Logger.flush()
    Logger.configure(level: level)
    failures
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
  defp verify(%{kind: :deps}, code) do
    with {:ok, tag} <- documented_tag(code),
         {:ok, release} <- newest_release() do
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

  # A block that runs — a GenServer driven by hand, a replay — and either returns or raises.
  # `expect=raise` is how a guide shows Layer 1 refusing a call: the server's exception arrives
  # here as the caller's exit, and `describe/1` digs it out.
  defp verify(%{kind: :run} = annotation, code) do
    case {annotation[:expect], evaluate(code)} do
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

  defp evaluate(code),
    do: isolated(fn -> code |> Code.eval_string([], file: "guide") |> elem(0) end)

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
    parent = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        Code.put_compiler_option(:ignore_module_conflict, true)
        send(parent, {:result, fun.()})
      end)

    receive do
      {:result, value} ->
        Process.demonitor(ref, [:flush])
        {:ok, value}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:raised, describe(reason)}
    after
      60_000 -> {:raised, "timed out after 60s"}
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

  # The `tag:` of the `:extla` dependency, wherever in the snippet it sits.
  defp documented_tag(code) do
    with {:ok, ast} <- Code.string_to_quoted(code),
         {_ast, tag} when is_binary(tag) <- Macro.prewalk(ast, nil, &extla_tag/2) |> elem_pair() do
      {:ok, tag}
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

  defp extla_tag({:extla, opts} = node, nil) when is_list(opts) do
    {node, Keyword.get(opts, :tag)}
  end

  defp extla_tag(node, acc), do: {node, acc}

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
