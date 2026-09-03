defmodule TLA.GuideCheck do
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
      <!-- tla:check module=M expect=ok -->              the run reports :ok
      <!-- tla:check module=M expect=ok states=8 depth=4 -->   ...and found that many, that deep
      <!-- tla:check module=M expect=violation length=6 -->    violated, shortest trace that long
      <!-- tla:check module=M expect=violation invariant=at_most_two -->   by THAT invariant
      <!-- tla:check module=M expect=deadlock -->        a reachable state nothing admits
      <!-- tla:liveness module=M expect=violation -->    check_liveness: true, refuted
      <!-- tla:compile_error match="not declared" -->    MEANT to fail; the message must match
      <!-- tla:skip reason=... -->                       not executable, and the reason is on the page

  `tla:check` and `tla:liveness` claim a run rather than code, so their comment may stand alone,
  beside the command whose output the page quotes; the other kinds annotate the fence below them.

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

  ## What is deliberately NOT asserted

  Only what a block claims. A block declaring `expect=ok` and no `states=` is not failed for its
  state count. An over-tight harness makes guides unwritable, and #79 is the precedent for a check
  asserting more than the design promises.
  """

  alias TLA.{ModelChecker, Spec}

  # An optional `<!-- tla:... -->` on the line IMMEDIATELY before a ```elixir fence, then the
  # fence's trailing info string (which must be empty — see the moduledoc), then the code.
  @fence ~r/(?:^[ \t]*<!--[ \t]*(tla:[^\n]*?)[ \t]*-->[ \t]*\n)?^```elixir([^\n]*)\n(.*?)^```/ms

  # A `tla:check` or `tla:liveness` with no fence under it. It claims a run, not code, so it
  # stands beside the command whose output the page quotes rather than above an empty block —
  # which `mix docs` would render as an empty grey box.
  @bare_claim ~r/^[ \t]*<!--[ \t]*(tla:(?:check|liveness)[^\n]*?)[ \t]*-->[ \t]*$(?!\n```elixir)/m

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
  Check one guide. Returns a list of failure strings — empty when the guide tells the truth.
  """
  def check(path) do
    path
    |> blocks()
    |> Enum.flat_map(fn {annotation, code, line} ->
      case verify(annotation, code) do
        :ok -> []
        {:error, why} -> ["#{path}:#{line}: #{why}"]
      end
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
         "before the fence (<!-- tla:spec -->, tla:check, tla:liveness, tla:compile_error) " <>
         "or <!-- tla:skip reason=... -->"}

  defp verify(%{kind: :skip}, _code), do: :ok

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
        expected = annotation[:match]

        if expected == nil or String.contains?(message, expected) do
          :ok
        else
          {:error, "expected the error to contain #{inspect(expected)}, got:\n    #{message}"}
        end
    end
  end

  defp verify(%{kind: kind} = annotation, _code) when kind in [:check, :liveness] do
    module = Module.concat([annotation.module])
    config = if kind == :liveness, do: %{check_liveness: true}, else: %{}

    case run(module, config) do
      {:raised, message} -> {:error, "the run raised: #{message}"}
      {:ok, result} -> with(:ok <- compare(result, annotation), do: census(result, annotation))
    end
  end

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
    cond do
      result.status != :violation ->
        {:error, "the guide claims a violation, but the run reports #{inspect(result.status)}"}

      annotation[:length] && result.violation.length != String.to_integer(annotation[:length]) ->
        {:error,
         "the guide claims a #{annotation[:length]}-step counterexample, " <>
           "but the shortest is #{result.violation.length}"}

      annotation[:invariant] &&
          to_string(result.violation.property) != annotation[:invariant] ->
        {:error,
         "the guide claims #{annotation[:invariant]} is violated, " <>
           "but the violated property is #{inspect(result.violation.property)}"}

      true ->
        :ok
    end
  end

  # A deadlock is worth teaching in its own right, and it does not fit `expect=violation
  # invariant=`: it arrives as a trace whose `property` is nil and whose `type` is :deadlock.
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

  # The numbers a guide quotes from the run's summary line. A reader will believe "8 distinct
  # states, depth 4" exactly as much as the verdict beside it, so a block may claim them and
  # then they are held to.
  defp census(result, annotation) do
    cond do
      annotation[:states] && result.distinct_states != String.to_integer(annotation[:states]) ->
        {:error,
         "the guide claims #{annotation[:states]} distinct states, " <>
           "but the run found #{result.distinct_states}"}

      annotation[:depth] && result.diameter != String.to_integer(annotation[:depth]) ->
        {:error,
         "the guide claims depth #{annotation[:depth]}, but the run reached #{result.diameter}"}

      true ->
        :ok
    end
  end

  defp violated_by(%{violation: %{property: property}}) when property != nil,
    do: " (#{property} is violated)"

  defp violated_by(%{violation: %{type: :deadlock}}),
    do: " (a state has no successors and no `terminal` admits it)"

  defp violated_by(_), do: ""

  # --- running things that may blow up --------------------------------------------------

  # No try/rescue (CLAUDE.md). The work happens in a monitored process and an exception is READ
  # out of the DOWN reason rather than caught, so nothing is swallowed and a crash that was not
  # expected still surfaces as one.
  defp compile(code), do: isolated(fn -> Code.compile_string(code, "guide") end)

  # Constants come from `default:` the way a reader's `mix tla.check` takes them, through the same
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

  defp describe({exception, _stacktrace}) when is_exception(exception),
    do: Exception.message(exception)

  defp describe(other), do: inspect(other)

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
  end

  defp line_of(source, offset) do
    source
    |> binary_part(0, offset)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end
end
