defmodule ExTLA.GenServer.Violation do
  @moduledoc """
  A Layer 3 conformance failure: the implementation took a step its specification does not
  permit, or reached an abstract state the specification forbids.

  `kind` is the finding, and the message is the layer's primary output:

  | `kind` | Meaning |
  |---|---|
  | `:not_enabled` | the action's guard was false on the pre-state — the implementation did what the spec forbids there |
  | `:diverged` | the guard held, but no binding of the action's params reproduces the implementation's post-state |
  | `:unmapped_but_moved` | no action was claimed, yet the abstract state changed |
  | `:invariant` | the abstract post-state violates one of the spec's invariants |
  | `:action_property` | the abstract transition violates one of the spec's action properties |

  `:diverged` is the common one, and it is more often the **refinement mapping** that is
  wrong than the implementation. That is still a finding worth having: a mapping that does
  not track the implementation invalidates every other check in the layer.
  """

  defexception [:kind, :spec, :action, :params, :pre, :post, :diff, :name, :detail]

  @type t :: %__MODULE__{
          kind: :not_enabled | :diverged | :unmapped_but_moved | :invariant | :action_property,
          spec: module(),
          action: atom() | nil,
          params: map() | nil,
          pre: ExTLA.State.t() | nil,
          post: ExTLA.State.t() | nil,
          diff: [{atom(), term(), term()}] | nil,
          name: atom() | nil,
          detail: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{} = violation) do
    [
      header(violation),
      "",
      body(violation),
      "",
      "  spec:   #{inspect(violation.spec)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp header(%{kind: kind}) do
    label = kind |> Atom.to_string() |> String.upcase() |> String.replace("_", " ")
    "═══ CONFORMANCE: #{label} " <> String.duplicate("═", max(0, 60 - String.length(label)))
  end

  defp body(%{kind: :not_enabled} = v) do
    """
      The implementation took #{inspect(v.action)}, which the spec does not permit here.

    #{v.detail}

      abstract pre-state:
    #{indent(v.pre)}
    """
  end

  defp body(%{kind: :diverged} = v) do
    """
      #{inspect(v.action)} is enabled, but the spec's transition does not produce what the
      implementation produced. Closest candidate binding: #{inspect(v.params)}

      variables that differ:
    #{Enum.map_join(v.diff, "\n", fn {var, spec, impl} -> "        #{var}:\n          spec:           #{inspect(spec)}\n          implementation: #{inspect(impl)}" end)}

      abstract pre-state:
    #{indent(v.pre)}
    """
  end

  defp body(%{kind: :unmapped_but_moved} = v) do
    """
      A message the refinement mapping calls `:unmapped` moved the abstract state.

      Either `abstract_action/1` is missing a clause for it, or the implementation makes a
      transition the specification does not model. `:unmapped` is a positive claim that the
      message does not move the abstract state, and this is that claim failing.

      variables that changed: #{inspect(Enum.map(v.diff, &elem(&1, 0)))}
    #{Enum.map_join(v.diff, "\n", fn {var, pre, post} -> "        #{var}: #{inspect(pre)} -> #{inspect(post)}" end)}
    """
  end

  defp body(%{kind: :invariant} = v) do
    """
      The abstract state violates the spec's invariant #{inspect(v.name)}.

      abstract state:
    #{indent(v.post)}
    """
  end

  defp body(%{kind: :action_property} = v) do
    """
      The abstract transition violates the spec's action property #{inspect(v.name)}.

      abstract pre-state:
    #{indent(v.pre)}

      abstract post-state:
    #{indent(v.post)}
    """
  end

  defp indent(nil), do: "        (none)"

  defp indent(state) do
    Enum.map_join(state, "\n", fn {var, value} -> "        #{var} = #{inspect(value)}" end)
  end
end
