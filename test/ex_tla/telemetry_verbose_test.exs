defmodule ExTLA.TelemetryVerboseTest do
  @moduledoc """
  The four `:checked` events `03-layer1-invariants.md` documents, and the opt-in that
  gates them (#279).

  ## What was wrong

  The table at §Telemetry lists four `:checked` events and reasons from that count — "a
  single transition can fire four of them" is the argument for making them opt-in. Two of
  the four **could not fire**: `emit_wrapper/3` spliced `:verbose` into the invariant and
  action-property calls and not into the precondition and postcondition ones, and
  `ExTLA.Invariant.Runtime` had no `:verbose` arity for the latter two to be spliced into.

  The same file contradicted itself three hundred lines apart — its `Runtime` API block
  listed the two arities the code had, because #22 amended the block from the code and
  left the event table alone. That is this milestone's subject exactly: a document that
  states what the code denies.

  ## Why this file is `async: false`

  `telemetry:` is read with `Application.compile_env/2`, so choosing it means setting
  application config and compiling a module under it — VM-global state, which cannot run
  beside anything else. `ExTLA.InvariantModesTest` makes the same choice for `mode:` and
  says so in the same words.
  """
  use ExUnit.Case, async: false

  # One module carrying all four declaration kinds, so one call can fire all four events.
  @source """
  defmodule <NAME> do
    use GenServer
    use ExTLA.Invariant

    invariant :never_negative do
      state.balance >= 0
    end

    action_property :no_free_money do
      new.balance <= old.balance
    end

    precondition {:withdraw, amount} do
      amount > 0
    end

    postcondition {:withdraw, amount} do
      new.balance == old.balance - amount
    end

    def init(balance), do: {:ok, %{balance: balance}}

    def handle_call({:withdraw, n}, _from, state) do
      {:reply, :ok, %{state | balance: state.balance - n}}
    end

    def handle_call(:peek, _from, state), do: {:reply, state.balance, state}
  end
  """

  @checked [
    [:extla, :invariant, :checked],
    [:extla, :action_property, :checked],
    [:extla, :precondition, :checked],
    [:extla, :postcondition, :checked]
  ]

  defp compile(name, telemetry) do
    previous = Application.get_env(:extla, :telemetry)
    Application.put_env(:extla, :telemetry, telemetry)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:extla, :telemetry, previous),
        else: Application.delete_env(:extla, :telemetry)
    end)

    [{module, _binary} | _] =
      Code.compile_string(String.replace(@source, "<NAME>", Atom.to_string(name)))

    module
  end

  # A module capture rather than a closure: `:telemetry` logs an `[info]` about a local
  # handler on every attach, and six of those in a suite people read is noise this file
  # would be adding on purpose. The test's pid travels as the handler's config instead.
  @doc false
  def forward(event, measurements, metadata, test),
    do: send(test, {:telemetry, event, measurements, metadata})

  defp listen(events) do
    handler = "#{inspect(self())}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(handler, events, &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp withdraw(module, amount) do
    {:ok, pid} = GenServer.start_link(module, 100)
    Process.unlink(pid)
    GenServer.call(pid, {:withdraw, amount})
  end

  defp received do
    receive do
      {:telemetry, event, measurements, metadata} -> {event, measurements, metadata}
    after
      0 -> nil
    end
  end

  defp drain(acc \\ []) do
    case received() do
      nil -> Enum.reverse(acc)
      event -> drain([event | acc])
    end
  end

  describe "under telemetry: :verbose" do
    # The assertion the work item exists for. Two of these four could not fire.
    test "one transition fires all four :checked events" do
      listen(@checked)
      module = compile(VerboseAll, :verbose)

      withdraw(module, 10)

      fired = drain() |> Enum.map(fn {event, _measurements, _metadata} -> event end)

      assert fired |> Enum.uniq() |> Enum.sort() == Enum.sort(@checked)

      # `uniq` above, and this is why: the invariant is checked on the initial state as
      # well as after the transition, so it fires twice for one call. The count is a fact
      # about `init/1` being instrumented, not about the events being double-emitted.
      assert Enum.count(fired, &(&1 == [:extla, :invariant, :checked])) == 2
      assert Enum.count(fired, &(&1 == [:extla, :precondition, :checked])) == 1
    end

    test "and each carries the module, the name and a duration" do
      listen(@checked)
      module = compile(VerboseMetadata, :verbose)

      withdraw(module, 10)

      for {event, _measurements, metadata} <- drain() do
        assert metadata.module == module, "#{inspect(event)} named #{inspect(metadata.module)}"
        assert is_atom(metadata.name)
        assert is_integer(metadata.duration)
        assert metadata.duration >= 0
      end
    end

    # A precondition's generated clause answers `:no_match` for a message it is not about,
    # without evaluating the predicate. An event there would time a pattern match and
    # report it as the cost of a check that never ran.
    test "a declaration that does not match the message fires nothing" do
      listen([[:extla, :precondition, :checked], [:extla, :postcondition, :checked]])
      module = compile(VerboseNoMatch, :verbose)

      {:ok, pid} = GenServer.start_link(module, 100)
      Process.unlink(pid)
      assert GenServer.call(pid, :peek) == 100

      assert drain() == []
    end
  end

  describe "under the default" do
    # The opt-in asserted rather than assumed: §Telemetry's whole argument for gating
    # these is that they are the hot path, and a gate nothing tests is a gate that can
    # quietly open.
    test "no :checked event fires at all" do
      listen(@checked)
      module = compile(DefaultQuiet, :enabled)

      withdraw(module, 10)

      assert drain() == []
    end

    # …and the violations still do, because those are not opt-in. Without this, "no events
    # fired" above would also pass on a module that emits nothing whatsoever.
    test "though a violation still does" do
      listen([[:extla, :precondition, :violated]])
      module = compile(DefaultViolating, :enabled)

      catch_exit(withdraw(module, -1))

      assert [{[:extla, :precondition, :violated], _measurements, metadata}] = drain()
      assert metadata.module == module
    end
  end

  # Two claims in `invariant_test.exs` that no assertion could reach, because both are about
  # a wrapper that is ABSENT and absence leaves no trace (#175). Under `:verbose` it does:
  # a wrapped callback emits `[:extla, :invariant, :checked]`, so "this callback was not
  # wrapped" becomes "this callback fired no event", which is a positive observation.
  describe "what the wrapper is put on" do
    @restricted """
    defmodule <NAME> do
      use GenServer
      use ExTLA.Invariant

      invariant :everywhere do
        state.n >= 0
      end

      invariant :calls_only, callbacks: [:handle_call] do
        state.n < 100
      end

      def init(n), do: {:ok, %{n: n}}
      def handle_call(:peek, _from, state), do: {:reply, state.n, state}
      def handle_cast(:bump, state), do: {:noreply, %{state | n: state.n + 1}}
    end
    """

    defp compile_restricted(name, telemetry) do
      previous = Application.get_env(:extla, :telemetry)
      Application.put_env(:extla, :telemetry, telemetry)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:extla, :telemetry, previous),
          else: Application.delete_env(:extla, :telemetry)
      end)

      [{module, _binary} | _] =
        Code.compile_string(String.replace(@restricted, "<NAME>", Atom.to_string(name)))

      module
    end

    defp names_checked do
      drain() |> Enum.map(fn {_event, _m, metadata} -> metadata.name end)
    end

    # `invariant_test.exs:53` asserted that the FIRST violation reported is the unrestricted
    # one — true, and equally true of a build that ignores `callbacks:` entirely.
    test "a callbacks:-restricted invariant is not checked in the others" do
      listen([[:extla, :invariant, :checked]])
      module = compile_restricted(RestrictedCast, :verbose)

      {:ok, pid} = GenServer.start_link(module, 0)
      Process.unlink(pid)
      drain()

      GenServer.cast(pid, :bump)
      _sync = GenServer.call(pid, :peek)

      cast_then_call = names_checked()

      assert :everywhere in cast_then_call
      # `calls_only` appears once — for the `call` — and not for the `cast`.
      assert Enum.count(cast_then_call, &(&1 == :calls_only)) == 1
      assert Enum.count(cast_then_call, &(&1 == :everywhere)) == 2
    end

    # `invariant_test.exs:163` asserted `refute function_exported?(Account, :handle_continue, 2)`
    # — and `use GenServer` does not inject `handle_continue/2` at all, so it held whatever the
    # wrapper did. `handle_info/2` IS injected, and a wrapper on it would check invariants on a
    # message the author never handled.
    test "and no wrapper is put on the callbacks use GenServer injected" do
      listen([[:extla, :invariant, :checked]])
      module = compile_restricted(InjectedDefaults, :verbose)

      {:ok, pid} = GenServer.start_link(module, 0)
      Process.unlink(pid)
      drain()

      # Reaches the injected `handle_info/2`, which the author did not write.
      send(pid, :nothing_handles_this)
      _sync = GenServer.call(pid, :peek)

      # Exactly the events of the `call` that followed it: the `info` contributed none.
      assert names_checked() == [:everywhere, :calls_only]
    end
  end

  describe "the events and the document" do
    # The recurrence guard. `spec/03`'s table is the only statement of which events exist,
    # and it drifted from the code once already — by three hundred lines, inside one file.
    test "list exactly the same four :checked events" do
      documented =
        "spec/03-layer1-invariants.md"
        |> File.read!()
        |> then(&Regex.scan(~r/^\[:extla, :(\w+), :checked\]/m, &1))
        |> Enum.map(fn [_match, kind] -> [:extla, String.to_existing_atom(kind), :checked] end)

      assert documented != [], "the event table was not found; this gate is reading nothing"

      listen(@checked)
      module = compile(VerboseDocumented, :verbose)
      withdraw(module, 10)

      emitted = drain() |> Enum.map(fn {event, _m, _md} -> event end) |> Enum.uniq()

      assert Enum.sort(documented) == Enum.sort(emitted)
    end
  end
end
