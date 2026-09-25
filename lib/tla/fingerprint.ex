defmodule TLA.Fingerprint do
  @moduledoc """
  Canonical, collision-resistant state identity.

  A fingerprint is the truncated SHA-256 of the state's canonical binary encoding.

  This module decides whether the checker's answers can be trusted. A fingerprint
  collision silently drops an unexplored state, and the run then reports success
  over a state space it never visited — the worst failure mode a verification tool
  has. See `01-foundation.md` §`TLA.Fingerprint` for why `:erlang.phash2/1` is not
  used.
  """

  @type t :: <<_::64>> | <<_::128>>

  @default_bits 64
  @permitted_bits [64, 128]

  @doc """
  The widths a fingerprint may be computed at.

  Asked for rather than restated by callers (#180). `mix tla.check --fingerprint-bits`
  validates its flag against this, so a second list cannot fall out of step with the one
  `compute/2` actually enforces.
  """
  def permitted_bits, do: @permitted_bits

  @doc """
  Canonical binary encoding of a state.

  Uses `:erlang.term_to_binary/2` with the `:deterministic` option, which fixes map
  and MapSet key ordering in the external term format. The plain 1-arity call is NOT
  used: its output for maps is not a guaranteed canonical encoding across OTP
  versions, so two equal states could encode differently and be explored twice — or,
  worse, a stored fingerprint could stop matching after an OTP upgrade.
  """
  def canonical(state), do: :erlang.term_to_binary(state, [:deterministic])

  @doc """
  Fingerprint a state. 64 bits by default; `bits: 128` for very large runs.

      iex> TLA.Fingerprint.compute(%{x: 1}) == TLA.Fingerprint.compute(%{x: 1})
      true

      iex> byte_size(TLA.Fingerprint.compute(%{x: 1}, bits: 128))
      16
  """
  def compute(state, opts \\ []), do: state |> canonical() |> of_encoding(opts)

  @doc """
  Fingerprint an encoding that has already been produced.

  Symmetry reduction (`TLA.Symmetry`) picks the smallest encoding of a state over every
  permutation of its interchangeable constants, and that encoding — not the state it came
  from — is what identity is then defined by. Re-encoding the winner would be work already
  done, and re-deriving it a chance for the two to disagree.
  """
  def of_encoding(encoding, opts \\ []) do
    bits = Keyword.get(opts, :bits, @default_bits)

    unless bits in @permitted_bits do
      raise ArgumentError,
            "fingerprint width must be one of #{inspect(@permitted_bits)}, got: #{inspect(bits)}"
    end

    :sha256
    |> :crypto.hash(encoding)
    |> binary_part(0, div(bits, 8))
  end

  @doc """
  Expected number of distinct states silently lost to collisions, by the birthday
  bound: `n^2 / 2^(bits+1)`. Reported in every `TLA.ModelChecker.result()` so a run's
  soundness margin is visible rather than assumed.

  The number is an expectation, not a bound: it is well below 1 for every run a
  64-bit fingerprint is appropriate for, and reporting `0.0000000271` rather than
  "no collisions" is the point — it says the answer is probabilistic and how
  probable, instead of implying a guarantee the method does not provide.

      iex> TLA.Fingerprint.collision_estimate(10_000_000, 64)
      2.710505431213761e-6
  """
  def collision_estimate(distinct_states, bits)
      when is_integer(distinct_states) and distinct_states >= 0 and is_integer(bits) and bits > 0 do
    distinct_states * distinct_states / :math.pow(2, bits + 1)
  end
end
