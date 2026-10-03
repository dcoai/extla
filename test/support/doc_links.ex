defmodule ExTLA.DocLinks do
  @moduledoc """
  Every internal link in the **built** documentation resolves (#102, #103).

  ## Why a second link gate

  `ExTLA.GuideCheck.Links` checks the links the guides *write*, in markdown, against markdown. This
  one checks the site ExDoc *publishes*. The two are not the same surface, and the gap between
  them is where #102 lived: ExDoc emits the sidebar's home link itself, pointing at
  `readme.html`, and no build produced that file — `README.md` and `spec/README.md` both derived
  the id `readme`, ExDoc disambiguated them to `readme-1` and `readme-2`, and `main: "readme"`
  went on naming a page that no longer existed. Every page of the documentation carried a 404 in
  its header, and nothing could see it: a gate over source markdown cannot check a link that only
  exists in the output.

  ## What it checks, and what it leaves alone

  Every `href` in `doc/*.html` that a reader could follow inside the site: another page, an asset,
  an anchor on this page or another. External URLs, `mailto:` and `javascript:` are somebody
  else's to resolve and are skipped — this gate is about the site being internally whole, not
  about the web being up.

  ## It says when it cannot answer

  `doc/` is built by `mix docs`, which is not part of `mix test`. Rather than pass when there is
  nothing to look at, `check/1` returns `:not_built`, and the test says so out loud — the same
  move `TLA_COVERAGE.md` makes in recording an unverified item as unverified. CI's `docs` job is
  what makes the answer real: without it this would be a gate that never runs, which is the shape
  #75 and #90 were raised about.
  """

  @href ~r/href="([^"]*)"/
  @id ~r/id="([^"]*)"/

  @doc """
  Failure strings for every unresolvable internal link in a built docs directory, or `:not_built`
  when there is nothing there to check.
  """
  def check(dir \\ "doc") do
    case Path.wildcard(Path.join(dir, "*.html")) do
      [] -> :not_built
      pages -> Enum.flat_map(Enum.sort(pages), &check_page(&1, dir))
    end
  end

  defp check_page(page, dir) do
    source = File.read!(page)

    @href
    |> Regex.scan(source)
    |> Enum.map(fn [_, href] -> href end)
    |> Enum.uniq()
    |> Enum.flat_map(fn href ->
      case resolve(href, page, dir) do
        :ok -> []
        {:error, why} -> ["#{Path.basename(page)}: #{why}"]
      end
    end)
  end

  defp resolve(href, page, dir) do
    cond do
      href == "" or (String.starts_with?(href, "#") == false and skip?(href)) ->
        :ok

      String.starts_with?(href, "#") ->
        anchor(page, String.trim_leading(href, "#"), page, dir)

      true ->
        {path, fragment} =
          case String.split(href, "#", parts: 2) do
            [path] -> {path, nil}
            [path, fragment] -> {path, fragment}
          end

        target = Path.join(dir, path)

        cond do
          not File.regular?(target) ->
            {:error, "link to #{inspect(href)} — #{path} is not in the built docs"}

          fragment in [nil, ""] ->
            :ok

          true ->
            anchor(target, fragment, page, dir)
        end
    end
  end

  # Only an HTML page has ids to check. An anchor on an asset is not something this can decide.
  defp anchor(target, fragment, page, _dir) do
    if Path.extname(target) == ".html" do
      if fragment in ids(target) do
        :ok
      else
        where = if target == page, do: "this page", else: Path.basename(target)

        {:error, "anchor ##{fragment} — #{where} has no element with that id"}
      end
    else
      :ok
    end
  end

  defp ids(page) do
    @id
    |> Regex.scan(File.read!(page))
    |> Enum.map(fn [_, id] -> id end)
  end

  defp skip?(href) do
    Regex.match?(~r{^[a-z][a-z0-9+.-]*:}i, href) or String.starts_with?(href, "//")
  end
end
