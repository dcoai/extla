defmodule ExTLA.Conformance do
  @moduledoc """
  Layer 2 and Layer 3, checked against each other (#49).

  They compute over the same specification and never look at one another. Layer 2 says
  which states are reachable. Layer 3 runs a real GenServer and observes behaviour through
  a refinement mapping. A trace the implementation produces that is **not a path in the
  checker's graph** means one of three things:

    1. the implementation is wrong — the finding Layer 3 exists for;
    2. the refinement mapping is wrong — `ExTLA.Simulation`'s own stated catch, "a
       refinement mapping that is wrong in a state no test happened to reach";
    3. **the search missed a state** — a checker defect, found by running code.

  Only the first two are ever considered today, and the third is indistinguishable from
  them. It is also the only one no other gate can find: TLC agreement covers six models,
  and a running server explores paths driven by real OTP scheduling rather than by the
  traversal code under test.

  ## What is decidable here, and what is not

  Given a step the graph does not contain, replaying it against the DSL semantics settles
  **one** question completely: does the spec permit it?

    * **it does**, and the graph lacks it — the search missed something. `:checker`, and
      the finding this module exists to make.
    * **it does not** — the implementation did something the spec forbids, *or* the
      mapping described the step wrongly. `:not_a_step_of_the_spec`.

  That last pair is not split, and not because it is hard.
  `test/conformance/README.md` already states the position for `:not_followed`: "one of
  the two is wrong, and which one is not something the checker can decide." The same
  argument runs in this direction, and a confident split would be precisely the kind of
  self-consistent wrong answer the rest of this work exists to remove. Layer 3's own
  `check_step/5` runs during the simulation and reports its reading; this adds the
  containment view beside it rather than overruling it.

  ## It declines to answer about a truncated graph

  Past `max_states`, or under a `state_constraint`, absence from the graph is a fact about
  the bound rather than about the search. Reporting that as a checker finding would
  manufacture exactly the false positive that gets a check like this turned off, so the
  run's status is a required argument and a bounded one is refused.
  """

  alias ExTLA.{ModelChecker, Spec, StateGraph}

  @typedoc """
  What containment found. `:ok`, or the first divergence and its class.
  """
  @type finding ::
          :ok
          | :nothing_observed
          | {:checker, map()}
          | {:absent_state, map()}
          | {:not_a_step_of_the_spec, map()}

  @complete [:ok, :violation, :deadlock]

  @doc """
  Is every state of `behaviour` a node of `graph`, and every step an edge?

  `status` is the run's own status, and it is required rather than optional: only a
  complete run can be audited this way, and a caller who has not thought about that is a
  caller about to get a false finding.

      ExTLA.Conformance.against_graph(graph, behaviour, status: result.status)
  """
  def against_graph(graph, behaviour, opts) do
    status = Keyword.fetch!(opts, :status)

    unless status in @complete do
      raise ArgumentError,
            "the graph came from a #{inspect(status)} run, so it does not describe the " <>
              "whole state space. Absence from it would be a fact about the bound rather " <>
              "than about the search, and reporting that as a checker finding would be a " <>
              "false positive. Re-run without the bound, or do not ask."
    end

    case behaviour do
      [] ->
        # Nothing was observed, so nothing can contradict the graph. Refusing would be the
        # wrong shape -- this is not a question that could not be answered, it is a question
        # with no subject -- but answering `:ok` silently is how the one-state case below
        # came to lie, so it is its own outcome rather than a success (#168).
        :nothing_observed

      [only] ->
        # A behaviour with no STEPS still makes a claim: that its state is one the spec can
        # reach. The pairwise fold below produced `[]` for it and returned its `:ok` seed, so
        # `against_graph(graph, [state_not_in_the_graph], status: :ok)` answered `:ok` and
        # `explain/1` said "every observed state is in the graph" about a state that was not.
        #
        # Reachable in practice: a simulation trace whose first message times out or is
        # refused yields exactly one state. And this is the module that already refuses a
        # BOUNDED graph outright rather than report absence from it -- the same discipline,
        # missed at the other end of the input.
        if StateGraph.id_of(graph, only) == nil do
          {:absent_state, %{step: 0, state: only, position: :only}}
        else
          :ok
        end

      _many ->
        behaviour
        |> Enum.zip(tl(behaviour))
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {{pre, post}, step}, :ok ->
          case classify(graph, pre, post, step) do
            :ok -> {:cont, :ok}
            finding -> {:halt, finding}
          end
        end)
    end
  end

  defp classify(graph, pre, post, step) do
    id_pre = StateGraph.id_of(graph, pre)
    id_post = StateGraph.id_of(graph, post)

    cond do
      id_pre == nil ->
        {:absent_state, %{step: step, state: pre, position: :pre}}

      id_post == nil ->
        {:absent_state, %{step: step, state: post, position: :post}}

      edge?(graph, id_pre, id_post) ->
        :ok

      permitted?(graph, pre, post) ->
        {:checker, %{step: step, from: pre, to: post, from_id: id_pre, to_id: id_post}}

      true ->
        {:not_a_step_of_the_spec, %{step: step, from: pre, to: post}}
    end
  end

  defp edge?(graph, id_pre, id_post) do
    Enum.any?(StateGraph.successors(graph, id_pre), fn {_action, _binding, to} ->
      to == id_post
    end)
  end

  # The decidable question, and the whole reason this module can say something Layer 3
  # cannot: does the SPEC permit this step, whatever the graph recorded?
  defp permitted?(graph, pre, post) do
    Enum.any?(ModelChecker.enabled_steps(graph.spec, graph.constants, pre), fn {action, binding} ->
      Spec.Compiled.action(graph.spec, action).transition.(graph.constants, pre, binding) == post
    end)
  end

  @doc """
  A finding rendered for a person, saying which of the three it is and why that matters.
  """
  def explain(:ok), do: "every observed state is in the graph, and every step is an edge."

  def explain(:nothing_observed),
    do:
      "the behaviour is empty, so there is nothing to compare against the graph. This is " <>
        "not a pass: no state was observed and no step was taken."

  def explain({:checker, %{step: step, from: from, to: to}}) do
    """
    CHECKER — step #{step} is a step the spec permits, and the graph does not have it.

      from: #{inspect(from)}
        to: #{inspect(to)}

    The implementation took a transition the specification allows, and the model checker's
    graph does not contain it. That is a defect in the search rather than in the code: a
    running server explores paths driven by real scheduling, and this is one the traversal
    missed. It is the only one of the three classes no other gate can produce.
    """
  end

  def explain({:absent_state, %{step: step, state: state, position: position}}) do
    """
    ABSENT STATE — #{absent_where(position, step)} is not in the graph at all.

      #{inspect(state)}

    Either the search never reached it, or the mapping produced an abstract state the spec
    cannot be in. The step check Layer 3 ran alongside this is the evidence for which.
    """
  end

  def explain({:not_a_step_of_the_spec, %{step: step, from: from, to: to}}) do
    """
    NOT A STEP OF THE SPEC — step #{step} is one no action of the spec permits.

      from: #{inspect(from)}
        to: #{inspect(to)}

    The implementation did something the specification forbids, or the refinement mapping
    described the step wrongly. Which of the two is NOT decidable from one step —
    `test/conformance/README.md` says so of the mirror case — so this names the pair and
    stops. Layer 3's own step check ran during the simulation and reports its reading.
    """
  end

  # A one-state behaviour has no step to number, and saying "step 0" would invite the reader
  # to look for a transition that does not exist.
  defp absent_where(:only, _step), do: "the behaviour's only state"
  defp absent_where(position, step), do: "the #{position}-state of step #{step}"
end
