defmodule ExTLA.Spec.ResolveConstantsTest do
  @moduledoc """
  `Spec.Compiled.resolve_constants/1` — the one place every path gets its constants from.

  A configured key the spec does not declare used to be merged in and read by nothing
  (#193): `constants: %{maxx: 100}` against `constant :max, default: 3` resolved to
  `%{max: 3, maxx: 100}`, the run used the default, and nothing said so. That is the
  selection defect of #185 through the door it did not cover, and the resolver is the
  right place to close it because `mix extla.check`, `mix extla.simulate`, Layer 3, the guides
  and the ledger all resolve here.
  """
  use ExUnit.Case, async: false

  alias ExTLA.Spec.Compiled
  alias ExTLA.TestSpecs.WithDefaults

  setup do
    on_exit(fn -> Application.delete_env(:extla, WithDefaults) end)
    :ok
  end

  test "a configured key the spec does not declare is refused, naming it and the declared set" do
    Application.put_env(:extla, WithDefaults, constants: %{maxx: 100})
    spec = Compiled.from_module(WithDefaults)

    error = assert_raise ArgumentError, fn -> Compiled.resolve_constants(spec) end

    assert error.message =~ ":maxx"
    assert error.message =~ "does not declare"
    assert error.message =~ "Declared: :max."
    assert error.message =~ inspect(WithDefaults)
  end

  test "every undeclared key is named, not just the first" do
    Application.put_env(:extla, WithDefaults, constants: %{maxx: 100, mx: 1})
    spec = Compiled.from_module(WithDefaults)

    error = assert_raise ArgumentError, fn -> Compiled.resolve_constants(spec) end

    assert error.message =~ ":maxx"
    assert error.message =~ ":mx"
  end

  test "a correctly named override still wins over the default" do
    Application.put_env(:extla, WithDefaults, constants: %{max: 100})
    spec = Compiled.from_module(WithDefaults)

    assert Compiled.resolve_constants(spec) == {:ok, %{max: 100}}
  end

  test "no config at all resolves to the defaults" do
    spec = Compiled.from_module(WithDefaults)

    assert Compiled.resolve_constants(spec) == {:ok, %{max: 3}}
  end
end
