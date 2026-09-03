defmodule TLA.GuideCheck.Links do
  @moduledoc """
  Every relative link in a guide resolves — the file exists, and the anchor is a heading it has
  (#98, #99).

  ## Why this is a test and not a review step

  #96 and #97 each checked their links by hand against the built docs, and #97's first draft got
  four of them wrong in the same way: ExDoc slugifies `### 1.5 Type annotations` to
  `1-5-type-annotations`, not `15-type-annotations`, so `#15-type-annotations` was a link into
  nothing. A link that silently goes nowhere is the drift `TLA_COVERAGE.md` exists to prevent, one
  layer out — and splitting the tutorial across pages (#99) multiplies the surface, because the
  pages now link to each other as well as into `spec/`.

  ## The anchors are ExDoc's own

  `slug/1` reproduces what ExDoc generates for a heading, because that is what the published docs
  will contain: lowercase, every run of non-alphanumerics to a single `-`, ends trimmed. Checking
  against anything else would pass links the reader cannot follow.
  """

  # `[text](target)`, where target is relative — anything with a scheme, and any bare `mailto:`
  # or protocol-relative URL, is somebody else's to resolve.
  @link ~r/\[(?:[^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/

  @heading ~r/^\#{1,6}[ \t]+(.+?)[ \t]*\#*$/m

  @doc """
  Failure strings for the links in one guide — empty when every one resolves.
  """
  def check(path) do
    source = File.read!(path)

    @link
    |> Regex.scan(source, return: :index)
    |> Enum.flat_map(fn [{start, _}, {target_start, target_len}] ->
      target = binary_part(source, target_start, target_len)
      line = line_of(source, start)

      case resolve(path, target) do
        :ok -> []
        {:error, why} -> ["#{path}:#{line}: #{why}"]
      end
    end)
  end

  defp resolve(path, target) do
    cond do
      # Someone else's to resolve: an absolute URL, a protocol-relative one, a mailto.
      Regex.match?(~r{^[a-z][a-z0-9+.-]*:}i, target) or String.starts_with?(target, "//") ->
        :ok

      String.starts_with?(target, "#") ->
        anchor(path, path, String.trim_leading(target, "#"))

      true ->
        {file, fragment} =
          case String.split(target, "#", parts: 2) do
            [file] -> {file, nil}
            [file, fragment] -> {file, fragment}
          end

        resolved = path |> Path.dirname() |> Path.join(file) |> Path.expand() |> relative()

        cond do
          not File.regular?(resolved) ->
            {:error, "link to #{inspect(target)}: #{resolved} does not exist"}

          fragment == nil ->
            :ok

          true ->
            anchor(path, resolved, fragment)
        end
    end
  end

  # A link into a document that is not markdown (an .ex, an image) cannot be checked for an
  # anchor, and saying so is better than pretending either way.
  defp anchor(from, file, fragment) do
    if Path.extname(file) == ".md" do
      if fragment in anchors(file) do
        :ok
      else
        {:error,
         "link to #{inspect(anchor_target(from, file, fragment))}: " <>
           "#{Path.basename(file)} has no heading whose anchor is #{inspect(fragment)}"}
      end
    else
      :ok
    end
  end

  defp anchor_target(from, file, fragment) do
    if from == file, do: "##{fragment}", else: "#{Path.basename(file)}##{fragment}"
  end

  defp anchors(file) do
    @heading
    |> Regex.scan(File.read!(file))
    |> Enum.map(fn [_, heading] -> slug(heading) end)
  end

  @doc """
  A heading's anchor, as ExDoc generates it: downcased, every run of anything that is not a
  letter, a digit or an underscore collapsed to one `-`, the ends trimmed.

  **The underscore survives** — `## 4. `action_property` uses `old` and `new`` anchors as
  `4-action_property-uses-old-and-new`, which is the id in the built docs. An earlier version
  stripped `_` along with the backticks and asterisks, on the theory that inline markup is not
  part of the slug; it does not need stripping, because a backtick collapses into the same `-`
  run as the space beside it, and stripping `_` made this check reject a link that works.

      iex> TLA.GuideCheck.Links.slug("1.5 Type annotations")
      "1-5-type-annotations"

      iex> TLA.GuideCheck.Links.slug("4. `action_property` uses `old` and `new`")
      "4-action_property-uses-old-and-new"

      iex> TLA.GuideCheck.Links.slug("5.1 The supported temporal fragment is bounded — say so")
      "5-1-the-supported-temporal-fragment-is-bounded-say-so"

      iex> TLA.GuideCheck.Links.slug("1.6 `f[x]` is function application, and it is strict")
      "1-6-f-x-is-function-application-and-it-is-strict"
  """
  def slug(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "-")
    |> String.trim("-")
  end

  defp relative(absolute), do: Path.relative_to(absolute, File.cwd!())

  defp line_of(source, offset) do
    source
    |> binary_part(0, offset)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end
end
