defmodule ExTLA.GuideCheckClaimsTest do
  @moduledoc """
  The claim kinds the tutorial needs (#97), each checked against a guide written to lie: a refuted
  temporal property named wrongly, a never-enabled action claimed on the wrong action, an unsound
  symmetry claimed sound and a sound one claimed unsound, a random-walk finding claimed absent,
  and a block that raises claimed to run. Same standard as `guide_check_test.exs`: a gate nobody
  has seen fail is not known to be a gate.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ExTLA.GuideCheck

  defp guide(tmp, body) do
    path = Path.join(tmp, "guide-#{System.unique_integer([:positive])}.md")
    File.write!(path, body)
    path
  end

  defp block(annotation, code), do: "<!-- #{annotation} -->\n```elixir\n#{code}```\n"
  defp claim(annotation), do: "\n<!-- #{annotation} -->\n"

  defp unique(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  # The tutorial's lock: three clients, one lock, any waiting client may take it. `extra` is
  # spliced in before `end`, which is how one fixture serves fairness, symmetry and the rest.
  defp lock(name, extra, clients \\ "[:alice, :bob, :carol]") do
    block("tla:spec", """
    defmodule #{name} do
      use ExTLA.Spec

      constant :clients, default: set(#{clients})

      variable :free, type: [true, false]
      variable :pc,   type: [^clients ~> [:idle, :waiting, :holding]]

      init do
        free = true
        pc   = for_each(^clients, fn _ -> :idle end)
      end

      action :request, params: [c: ^clients] do
        require pc[c] == :idle
        pc = update(pc, c, fn _ -> :waiting end)
      end

      action :acquire, params: [c: ^clients] do
        require pc[c] == :waiting
        require free
        free = false
        pc   = update(pc, c, fn _ -> :holding end)
      end

      action :release, params: [c: ^clients] do
        require pc[c] == :holding
        free = true
        pc   = update(pc, c, fn _ -> :idle end)
      end

      invariant :mutual_exclusion do
        Enum.count(^clients, fn c -> pc[c] == :holding end) <= 1
      end
    #{extra}
    end
    """)
  end

  @no_starvation """
    temporal :no_starvation do
      Enum.all?(^clients, fn c -> (pc[c] == :waiting) ~> (pc[c] == :holding) end)
    end
  """

  describe "tla:liveness names the refuted property" do
    test "weak per-client fairness is refuted, and the guide may say by which property",
         %{tmp_dir: tmp} do
      m = unique("Claims.Weak")

      path =
        guide(
          tmp,
          lock(m, @no_starvation <> "  fairness :weak, acquire: [:c], release: [:c]\n") <>
            claim("tla:liveness module=#{m} expect=violation property=no_starvation")
        )

      assert GuideCheck.check(path) == []
    end

    test "naming a property the run did not refute is rejected", %{tmp_dir: tmp} do
      m = unique("Claims.WeakLies")

      path =
        guide(
          tmp,
          lock(m, @no_starvation <> "  fairness :weak, acquire: [:c], release: [:c]\n") <>
            claim("tla:liveness module=#{m} expect=violation property=mutual_exclusion")
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims mutual_exclusion is violated"
      assert failure =~ ":no_starvation"
    end

    test "claiming a length for a lasso is rejected rather than answered with the prefix",
         %{tmp_dir: tmp} do
      m = unique("Claims.Lasso")

      path =
        guide(
          tmp,
          lock(m, @no_starvation <> "  fairness :weak, acquire: [:c], release: [:c]\n") <>
            claim("tla:liveness module=#{m} expect=violation length=5")
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "a lasso, not a trace"
    end

    test "strong per-client fairness holds, and claiming otherwise is rejected", %{tmp_dir: tmp} do
      m = unique("Claims.Strong")

      spec =
        lock(
          m,
          @no_starvation <> "  fairness :strong, acquire: [:c]\n  fairness :weak, release: [:c]\n"
        )

      assert GuideCheck.check(guide(tmp, spec <> claim("tla:liveness module=#{m} expect=ok"))) ==
               []

      assert [failure] =
               GuideCheck.check(
                 guide(tmp, spec <> claim("tla:liveness module=#{m} expect=violation"))
               )

      assert failure =~ "claims a violation"
    end
  end

  describe "tla:check never_enabled= names the dead action" do
    # A `cancel` whose guard has a typo: never enabled, and nothing depends on it, so the spec
    # verifies — the silent kind of wrong that the coverage table exists to show.
    @cancel """
      action :cancel, params: [c: ^clients] do
        require pc[c] == :wating
        pc = update(pc, c, fn _ -> :idle end)
      end
    """

    test "accepted when it is the action that was never enabled", %{tmp_dir: tmp} do
      m = unique("Claims.Cancel")

      path =
        guide(
          tmp,
          lock(m, @cancel) <> claim("tla:check module=#{m} expect=ok never_enabled=cancel")
        )

      assert GuideCheck.check(path) == []
    end

    test "rejected when it names the wrong action, and when nothing was dead", %{tmp_dir: tmp} do
      m = unique("Claims.CancelLies")

      assert [failure] =
               GuideCheck.check(
                 guide(
                   tmp,
                   lock(m, @cancel) <>
                     claim("tla:check module=#{m} expect=ok never_enabled=release")
                 )
               )

      assert failure =~ "claims [:release] were never enabled"
      assert failure =~ "[:cancel]"

      m = unique("Claims.AllLive")

      assert [failure] =
               GuideCheck.check(
                 guide(
                   tmp,
                   lock(m, "") <> claim("tla:check module=#{m} expect=ok never_enabled=cancel")
                 )
               )

      assert failure =~ "reports []"
    end
  end

  describe "tla:check symmetry= runs under the reduction" do
    test "the reduced census is the one asserted", %{tmp_dir: tmp} do
      m = unique("Claims.Sym")

      path =
        guide(
          tmp,
          lock(m, "") <>
            claim("tla:check module=#{m} expect=ok states=20 depth=5") <>
            claim(
              "tla:check module=#{m} expect=ok symmetry=clients verify_symmetry=true states=7"
            )
        )

      assert GuideCheck.check(path) == []
    end

    test "quoting the unreduced count for a reduced run is rejected", %{tmp_dir: tmp} do
      m = unique("Claims.SymLies")

      path =
        guide(
          tmp,
          lock(m, "") <> claim("tla:check module=#{m} expect=ok symmetry=clients states=20")
        )

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims 20 distinct states"
      assert failure =~ "found 7"
    end

    # An invariant that names a client can tell the clients apart, which is exactly what a
    # symmetry declaration promises nothing does.
    @names_carol """
      invariant :carol_never_holds do
        pc[:carol] != :holding
      end
    """

    test "an unsound declaration is refused, and the guide may say so", %{tmp_dir: tmp} do
      m = unique("Claims.Unsound")

      path =
        guide(
          tmp,
          lock(m, @names_carol) <>
            claim("tla:check module=#{m} expect=unsound_symmetry symmetry=clients")
        )

      assert GuideCheck.check(path) == []
    end

    test "claiming a sound declaration is unsound is rejected, and the reverse", %{tmp_dir: tmp} do
      m = unique("Claims.SoundLies")

      assert [failure] =
               GuideCheck.check(
                 guide(
                   tmp,
                   lock(m, "") <>
                     claim("tla:check module=#{m} expect=unsound_symmetry symmetry=clients")
                 )
               )

      assert failure =~ "claims the symmetry declaration is unsound"

      m = unique("Claims.UnsoundLies")

      assert [failure] =
               GuideCheck.check(
                 guide(
                   tmp,
                   lock(m, @names_carol) <>
                     claim(
                       "tla:check module=#{m} expect=violation symmetry=clients verify_symmetry=true"
                     )
                 )
               )

      assert failure =~ "the run raised"
      assert failure =~ "is not sound"
    end
  end

  # --- Layers 1 and 3 ------------------------------------------------------------------------

  # A server that refines the two-client lock, its mapping, and a sibling that leaks: releasing
  # leaves the client waiting, which the spec's `release` does not do.
  defp servers(spec, refinement, good, leaky) do
    block("tla:spec", """
    defmodule #{refinement} do
      use ExTLA.Refinement

      def abstract(%{holder: holder, waiting: waiting}) do
        pc =
          Map.new([:alice, :bob], fn c ->
            {c,
             cond do
               holder == c -> :holding
               c in waiting -> :waiting
               true -> :idle
             end}
          end)

        %{free: holder == nil, pc: pc}
      end

      def abstract_action({:request, c}), do: {:request, %{c: c}}
      def abstract_action({:acquire, c}), do: {:acquire, %{c: c}}
      def abstract_action({:release, c}), do: {:release, %{c: c}}
      def abstract_action(_), do: :unmapped

      def concrete_message(:request, %{c: c}), do: {:request, c}
      def concrete_message(:acquire, %{c: c}), do: {:acquire, c}
      def concrete_message(:release, %{c: c}), do: {:release, c}
    end

    defmodule #{good} do
      use GenServer
      use ExTLA.GenServer, spec: #{spec}, refinement: #{refinement}

      def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(_), do: {:ok, %{holder: nil, waiting: []}}

      @impl true
      def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

      def handle_call({:acquire, c}, _from, %{holder: nil} = s),
        do: {:reply, :ok, %{s | holder: c, waiting: List.delete(s.waiting, c)}}

      def handle_call({:release, c}, _from, %{holder: c} = s), do: {:reply, :ok, %{s | holder: nil}}
    end

    defmodule #{leaky} do
      use GenServer
      use ExTLA.GenServer, spec: #{spec}, refinement: #{refinement}

      def start_link(opts \\\\ []), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(_), do: {:ok, %{holder: nil, waiting: []}}

      @impl true
      def handle_call({:request, c}, _from, s), do: {:reply, :ok, %{s | waiting: s.waiting ++ [c]}}

      def handle_call({:acquire, c}, _from, %{holder: nil} = s),
        do: {:reply, :ok, %{s | holder: c, waiting: List.delete(s.waiting, c)}}

      def handle_call({:release, c}, _from, %{holder: c} = s),
        do: {:reply, :ok, %{s | holder: nil, waiting: s.waiting ++ [c]}}
    end
    """)
  end

  defp layer3(tmp, claims) do
    n = System.unique_integer([:positive])
    spec = "Claims.L3Spec#{n}"
    good = "Claims.L3Good#{n}"
    leaky = "Claims.L3Leaky#{n}"

    body =
      lock(spec, "", "[:alice, :bob]") <>
        servers(spec, "Claims.L3Map#{n}", good, leaky) <>
        Enum.map_join(claims, fn c ->
          c |> String.replace("GOOD", good) |> String.replace("LEAKY", leaky) |> claim()
        end)

    guide(tmp, body)
  end

  describe "tla:simulate walks the implementation" do
    test "a conforming server finds nothing, a leaky one is caught with the message claimed",
         %{tmp_dir: tmp} do
      path =
        layer3(tmp, [
          "tla:simulate module=GOOD expect=ok",
          ~s(tla:simulate module=LEAKY expect=violation match="DIVERGED")
        ])

      assert GuideCheck.check(path) == []
    end

    test "claiming the leaky server clean is rejected, with the finding", %{tmp_dir: tmp} do
      path = layer3(tmp, ["tla:simulate module=LEAKY expect=ok"])

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims the simulation finds nothing"
      assert failure =~ "DIVERGED"
    end

    test "claiming a finding on the conforming server is rejected", %{tmp_dir: tmp} do
      path = layer3(tmp, ["tla:simulate module=GOOD expect=violation"])

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims the simulation finds a violation"
    end

    test "a wrong match on a real finding is rejected", %{tmp_dir: tmp} do
      path =
        layer3(tmp, [
          ~s(tla:simulate module=LEAKY expect=violation match="a message it never prints")
        ])

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "expected the violation to contain"
    end
  end

  describe "tla:check expect=incomplete claims a BOUNDED run" do
    # The mathematics page (#101) teaches that a green run is a proof about the model, and a
    # bounded one is not a verdict at all. That page's own demonstration has to be checked, or it
    # would be prose asserting exactly what it warns against.
    test "a run cut short by max_states can say so", %{tmp_dir: tmp} do
      m = unique("Claims.Bounded")

      path =
        guide(
          tmp,
          lock(m, "") <> claim("tla:check module=#{m} expect=incomplete max_states=5 states=7")
        )

      assert GuideCheck.check(path) == []
    end

    test "claiming a bound on a run that completed is rejected", %{tmp_dir: tmp} do
      m = unique("Claims.NotBounded")

      path = guide(tmp, lock(m, "") <> claim("tla:check module=#{m} expect=incomplete"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims the run was bounded"
      assert failure =~ ":ok"
      assert failure =~ "max_states="
    end

    test "claiming :ok for a bounded run is rejected — the confusion the exit codes exist for",
         %{tmp_dir: tmp} do
      m = unique("Claims.BoundedNotOk")

      path =
        guide(tmp, lock(m, "") <> claim("tla:check module=#{m} expect=ok max_states=5"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims this reports :ok"
      assert failure =~ ":max_states_reached"
    end
  end

  describe "tla:run evaluates a block, and a raise is a claim" do
    test "a block that runs may say so, and one that raises must say what", %{tmp_dir: tmp} do
      n = System.unique_integer([:positive])
      spec = "Claims.RunSpec#{n}"
      good = "Claims.RunGood#{n}"

      path =
        guide(
          tmp,
          lock(spec, "", "[:alice, :bob]") <>
            servers(spec, "Claims.RunMap#{n}", good, "Claims.RunLeaky#{n}") <>
            block("tla:run expect=ok", """
            {:ok, pid} = #{good}.start_link()
            :ok = GenServer.call(pid, {:request, :alice})
            :ok = GenServer.call(pid, {:acquire, :alice})
            """) <>
            block(~s(tla:run expect=raise match="CONFORMANCE"), """
            {:ok, pid} = #{good}.start_link()
            GenServer.call(pid, {:acquire, :alice})
            """)
        )

      assert GuideCheck.check(path) == []
    end

    test "a block that raises cannot claim to run", %{tmp_dir: tmp} do
      path = guide(tmp, block("tla:run expect=ok", "raise ArgumentError, \"on purpose\"\n"))

      assert [failure] = GuideCheck.check(path)
      assert failure =~ "claims this runs, but it raised: on purpose"
    end

    test "a block that returns cannot claim to raise, and a wrong match is rejected",
         %{tmp_dir: tmp} do
      assert [failure] = GuideCheck.check(guide(tmp, block("tla:run expect=raise", ":fine\n")))
      assert failure =~ "claims this raises, but it returned :fine"

      assert [failure] =
               GuideCheck.check(
                 guide(
                   tmp,
                   block(
                     ~s(tla:run expect=raise match="something else"),
                     "raise ArgumentError, \"on purpose\"\n"
                   )
                 )
               )

      assert failure =~ "expected the exception to contain"
    end
  end
end
