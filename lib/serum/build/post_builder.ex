defmodule Serum.Build.PostBuilder do
  @moduledoc """
  This module contains functions for building blog posts
  sequantially for parallelly.
  """

  import Serum.Util
  alias Serum.Error
  alias Serum.Build
  alias Serum.Build.Renderer
  alias Serum.BuildDataStorage
  alias Serum.PostInfo
  alias Serum.PostInfoStorage
  alias Serum.ProjectInfoStorage

  @type erl_datetime :: {erl_date, erl_time}
  @type erl_date :: {non_neg_integer, non_neg_integer, non_neg_integer}
  @type erl_time :: {non_neg_integer, non_neg_integer, non_neg_integer}

  @typep header :: {String.t, [Serum.Tag.t], [String.t]}

  @re_fname ~r/^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9a-z\-]+$/
  @async_opt [max_concurrency: System.schedulers_online * 10]

  @spec run(String.t, String.t, Build.build_mode) :: Error.result

  def run(src, dest, mode) do
    srcdir = "#{src}posts/"
    dstdir = "#{dest}posts/"
    PostInfoStorage.init owner()

    case load_file_list srcdir do
      {:ok, list} ->
        File.mkdir_p! dstdir
        result = launch mode, list, srcdir, dstdir
        Error.filter_results result, :post_builder
      error -> error
    end
  end

  @spec load_file_list(String.t) :: Error.result([String.t])

  defp load_file_list(srcdir) do
    case File.ls srcdir do
      {:ok, list} ->
        list =
          list
          |> Enum.filter_map(&String.ends_with?(&1, ".md"), fn x ->
            String.replace x, ~r/\.md$/, ""
          end)
          |> Enum.sort
        {:ok, list}
      {:error, reason} ->
        {:error, :file_error, {reason, srcdir, 0}}
    end
  end

  @spec launch(Build.build_mode, [String.t], String.t, String.t)
    :: [Error.result]

  defp launch(:parallel, files, src, dst) do
    own = owner()
    files
    |> Task.async_stream(__MODULE__, :post_task, [src, dst, own], @async_opt)
    |> Enum.map(&(elem &1, 1))
  end

  defp launch(:sequential, files, srcdir, dstdir) do
    own = owner()
    files |> Enum.map(&post_task(&1, srcdir, dstdir, own))
  end

  @spec post_task(String.t, String.t, String.t, pid) :: Error.result

  def post_task(file, src, dest, owner) do
    Process.link owner
    srcname = "#{src}#{file}.md"
    dstname = "#{dest}#{file}.html"
    base = ProjectInfoStorage.get owner, :base_url
    case {extract_date(srcname), extract_header(srcname, base)} do
      {{:ok, raw_date}, {:ok, header}} ->
        do_post_task file, srcname, dstname, header, raw_date
      {error = {:error, _, _}, _} -> error
      {_, error = {:error, _, _}} -> error
    end
  end

  @spec do_post_task(String.t, String.t, String.t, header, erl_datetime) :: :ok

  defp do_post_task(file, srcname, dstname, header, raw_date) do
    lines = elem header, 2
    stub = Earmark.to_html lines
    preview_len = ProjectInfoStorage.get owner(), :preview_length
    preview = make_preview stub, preview_len
    info = PostInfo.new file, header, raw_date, preview
    PostInfoStorage.add owner(), info
    html = render_post stub, info
    fwrite dstname, html
    IO.puts "  GEN  #{srcname} -> #{dstname}"
    :ok
  end

  @spec make_preview(String.t, non_neg_integer) :: String.t

  def make_preview(html, maxlen) do
    case maxlen do
      0 -> ""
      x when is_integer(x) ->
        parsed =
          case Floki.parse html do
            t when is_tuple(t) -> [t]
            l when is_list(l)  -> l
          end
        parsed
        |> Enum.filter_map(&(elem(&1, 0) == "p"), &Floki.text/1)
        |> Enum.join(" ")
        |> String.slice(0, x)
    end
  end

  @spec render_post(String.t, PostInfo.t) :: String.t

  defp render_post(contents, info) do
    template = BuildDataStorage.get owner(), "template", "post"
    template
    |> Renderer.render([title: info.title, date: info.date,
      raw_date: info.raw_date, tags: info.tags, contents: contents])
    |> Renderer.genpage([page_title: info.title], owner())
  end

  @doc "Extracts the date/time information from a file name."
  @spec extract_date(String.t) :: Error.result(erl_datetime)

  def extract_date(path) do
    fname = :filename.basename path, ".md"
    if fname =~ @re_fname do
      [y, m, d, hhmm|_] =
        fname
        |> String.split("-")
        |> Enum.take(4)
        |> Enum.map(&(&1 |> Integer.parse |> elem(0)))
      {h, i} =
        with h <- div(hhmm, 100), i <- rem(hhmm, 100) do
          h = h > 23 && 23 || h
          i = i > 59 && 59 || i
          {h, i}
        end
      raw_date = {{y, m, d}, {h, i, 0}}
      {:ok, raw_date}
    else
      {:error, :post_error, {:invalid_filename, path, 0}}
    end
  end

  @spec extract_header(String.t, String.t) :: Error.result(header)

  def extract_header(fname, base) do
    case File.read fname do
      {:ok, data} ->
        do_extract_header fname, data, base
      {:error, reason} ->
        {:error, :file_error, {reason, fname, 0}}
    end
  end

  @spec do_extract_header(String.t, String.t, String.t) :: Error.result(header)

  defp do_extract_header(fname, data, base) do
    try do
      [l1, l2|rest] = data |> String.split("\n")
      {"# " <> title, "#" <> tags} = {l1, l2}
      title = String.trim title
      tags =
        tags
        |> String.split(~r/, */)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Enum.sort
        |> Enum.map(&(%Serum.Tag{name: &1, list_url: "#{base}tags/#{&1}"}))
      {:ok, {title, tags, rest}}
    rescue
      _ in MatchError ->
        {:error, :post_error, {:invalid_header, fname, 0}}
    end
  end
end
