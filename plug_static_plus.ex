defmodule PlugStaticPlus do
  @moduledoc """
  See the original plug for the full documentation: https://github.com/elixir-plug/plug/blob/master/lib/plug/static.ex

  New features/changes made in this plug:
    * Support for index handling. Requesting e.g. "/my-dir" while "/my-dir/index.html" exists will serve the
      "index.html" file. Respects the :custom_types setting if a reroute is performed.
      The index files can be specified by using the :index option with either a list of strings or a single string. The
      default is ["index.html", "index.htm", "index.js", "index.json"]
    * Files can be served from the "/" directory. Will respect index definitions.
  """

  @behaviour Plug
  @allowed_methods ~w(GET HEAD)

  import Plug.Conn
  alias Plug.Conn

  # In this module, the `:prim_info` Erlang module along with the `:file_info`
  # record are used instead of the more common and Elixir-y `File` module and
  # `File.Stat` struct, respectively. The reason behind this is performance: all
  # the `File` operations pass through a single process in order to support node
  # operations that we simply don't need when serving assets.

  require Record
  Record.defrecordp :file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl")

  defmodule InvalidPathError do
    defexception message: "invalid path for static asset", plug_status: 400
  end

  def init(opts) do
    from =
      case Keyword.fetch!(opts, :from) do
        {_, _} = from -> from
        from when is_atom(from) -> {from, "priv/static"}
        from when is_binary(from) -> from
        _ -> raise ArgumentError, ":from must be an atom, a binary or a tuple"
      end

    index =
      case Keyword.fetch(opts, :index) do
        {:ok, files} when is_list(files) -> files
        {:ok, file} when is_binary(file) -> [file]
        :error -> ["index.html", "index.htm", "index.js", "index.json"]
        _ -> raise ArgumentError, ":index must be a list, a binary or not specified"
      end

    %{
      gzip?: Keyword.get(opts, :gzip, false),
      brotli?: Keyword.get(opts, :brotli, false),
      only: Keyword.get(opts, :only, []),
      prefix: Keyword.get(opts, :only_matching, []),
      qs_cache: Keyword.get(opts, :cache_control_for_vsn_requests, "public, max-age=31536000"),
      et_cache: Keyword.get(opts, :cache_control_for_etags, "public"),
      et_generation: Keyword.get(opts, :etag_generation, nil),
      headers: Keyword.get(opts, :headers, %{}),
      content_types: Keyword.get(opts, :content_types, %{}),
      from: from,
      index: index,
      at: opts
          |> Keyword.fetch!(:at)
          |> Plug.Router.Utils.split()
    }
  end

  def call(
        conn = %Conn{method: meth},
        %{at: at, only: only, prefix: prefix, from: from, gzip?: gzip?, brotli?: brotli?, index: index} = options
      )
      when meth in @allowed_methods do
    segments = subset(at, conn.path_info)
    IO.inspect segments
    if allowed?(only, prefix, segments) do
      segments = Enum.map(segments, &uri_decode/1)

      if invalid_path?(segments) do
        raise InvalidPathError
      end

      path = path(from, segments)
      range = get_req_header(conn, "range")
      encoding = file_encoding(conn, path, index, range, gzip?, brotli?)
      serve_static(encoding, segments, range, options)
    else
      conn
    end
  end

  def call(conn, _options) do
    conn
  end

  defp uri_decode(path) do
    try do
      URI.decode(path)
    rescue
      ArgumentError ->
        raise InvalidPathError
    end
  end

  defp allowed?(_only, _prefix, []), do: true
  defp allowed?([], [], _list), do: true
  defp allowed?(only, prefix, [h | _]) do
    h in only or match?({0, _}, prefix != [] and :binary.match(h, prefix))
  end

  defp serve_static({:ok, conn, file_info, path}, segments, range, options) do
    %{
      qs_cache: qs_cache,
      et_cache: et_cache,
      et_generation: et_generation,
      headers: headers,
      content_types: types
    } = options
    case put_cache_header(conn, qs_cache, et_cache, et_generation, file_info, path) do
      {:stale, conn} ->
        # We cannot simply use "path" since the types contain simply the "content_types" filenames instead of the fully
        # quailified path.
        filename =
          case String.split(path, ["/"]) do
            [] -> ""
            parts -> List.last(parts)
          end
        content_type = Map.get(types, filename) || MIME.from_path(filename)
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> merge_resp_headers(headers)
        |> serve_range(file_info, path, range, options)

      {:fresh, conn} ->
        conn
        |> send_resp(304, "")
        |> halt()
    end
  end
  defp serve_static({:error, conn}, _segments, _range, _options) do
    conn
  end

  defp serve_range(conn, file_info, path, [range], options) do
    file_info(size: file_size) = file_info

    with %{"bytes" => bytes} <- Plug.Conn.Utils.params(range),
         {range_start, range_end} <- start_and_end(bytes, file_size),
         :ok <- check_bounds(range_start, range_end, file_size) do
      send_range(conn, path, range_start, range_end, file_size)
    else
      _ -> send_entire_file(conn, path, options)
    end
  end
  defp serve_range(conn, _file_info, path, _range, options) do
    send_entire_file(conn, path, options)
  end

  defp start_and_end("-" <> rest, file_size) do
    case Integer.parse(rest) do
      {last, ""} -> {file_size - last, file_size - 1}
      _ -> :error
    end
  end
  defp start_and_end(range, file_size) do
    case Integer.parse(range) do
      {first, "-"} ->
        {first, file_size - 1}
      {first, "-" <> rest} ->
        case Integer.parse(rest) do
          {last, ""} -> {first, last}
          _ -> :error
        end
      _ ->
        :error
    end
  end

  defp check_bounds(range_start, range_end, file_size)
       when range_start < 0 or range_end >= file_size or range_start > range_end do
    :error
  end
  defp check_bounds(0, range_end, file_size) when range_end == file_size - 1 do
    :error
  end
  defp check_bounds(_range_start, _range_end, _file_size) do
    :ok
  end

  defp send_range(conn, path, range_start, range_end, file_size) do
    length = (range_end - range_start) + 1

    conn
    |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{file_size}")
    |> send_file(206, path, range_start, length)
    |> halt()
  end

  defp send_entire_file(conn, path, %{gzip?: gzip?, brotli?: brotli?} = _options) do
    conn
    |> maybe_add_vary(gzip?, brotli?)
    |> send_file(200, path)
    |> halt()
  end

  defp maybe_add_vary(conn, gzip?, brotli?) do
    # If we serve gzip or brotli at any moment, we need to set the proper vary
    # header regardless of whether we are serving gzip content right now.
    # See: http://www.fastly.com/blog/best-practices-for-using-the-vary-header/
    if gzip? or brotli? do
      update_in conn.resp_headers, &[{"vary", "Accept-Encoding"} | &1]
    else
      conn
    end
  end

  defp put_cache_header(%Conn{query_string: "vsn=" <> _} = conn, qs_cache, _et_cache, _et_generation, _file_info, _path)
       when is_binary(qs_cache) do
    {:stale, put_resp_header(conn, "cache-control", qs_cache)}
  end

  defp put_cache_header(conn, _qs_cache, et_cache, et_generation, file_info, path) when is_binary(et_cache) do
    etag = etag_for_path(file_info, et_generation, path)

    conn =
      conn
      |> put_resp_header("cache-control", et_cache)
      |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      {:fresh, conn}
    else
      {:stale, conn}
    end
  end

  defp put_cache_header(conn, _, _, _, _, _) do
    {:stale, conn}
  end

  defp etag_for_path(file_info, et_generation, path) do
    case et_generation do
      {module, function, args} ->
        apply(module, function, [path | args])
      nil ->
        file_info(size: size, mtime: mtime) = file_info
        {size, mtime}
        |> :erlang.phash2()
        |> Integer.to_string(16)
    end
  end

  defp file_encoding(conn, path, index, [_range], _gzip?, _brotli?) do
    # We do not support compression for range queries.
    file_encoding(conn, path, index, nil, false, false)
  end
  defp file_encoding(conn, path, index, _range, gzip?, brotli?) do
    cond do
      match = brotli? and accept_encoding?(conn, "br") && regular_file_info(path <> ".br", index) ->
        {new_path, file_info} = match
        {:ok, put_resp_header(conn, "content-encoding", "br"), file_info, new_path <> ".br"}
      match = gzip? and accept_encoding?(conn, "gzip") && regular_file_info(path <> ".gz", index) ->
        {new_path, file_info} = match
        {:ok, put_resp_header(conn, "content-encoding", "gzip"), file_info, new_path <> ".gz"}
      match = regular_file_info(path, index) ->
        case match do
          nil -> {:ok, conn, nil, path}
          {new_path, file_info} -> {:ok, conn, file_info, new_path}
        end
      true ->
        {:error, conn}
    end
  end

  defp fallback_file_info(_, []) do
    nil
  end
  defp fallback_file_info(path, [try | t]) do
    path = Enum.join([path, try], "/")
    case regular_file_info(path, false) do
      nil -> fallback_file_info(path, t)
      file_info -> file_info
    end
  end

  @spec regular_file_info(String.t, boolean | list) :: {String.t, record(:file_info)} | nil
  defp regular_file_info(path, fallback) do
    case :prim_file.read_file_info(path) do
      {:ok, file_info(type: :regular) = file_info} -> {path, file_info}
      {:ok, file_info(type: :directory)} ->
        case fallback do
          false -> nil
          _ -> fallback_file_info(path, fallback)
        end
      {:ok, _} -> nil
      {:error, :enoent} ->
        case fallback do
          false -> nil
          _ -> fallback_file_info(path, fallback)
        end
      {:error, _} -> nil
    end
  end

  defp accept_encoding?(conn, encoding) do
    encoding? = &String.contains?(&1, [encoding, "*"])
    Enum.any? get_req_header(conn, "accept-encoding"), fn accept ->
      accept
      |> Plug.Conn.Utils.list()
      |> Enum.any?(encoding?)
    end
  end

  defp path({app, from}, segments) when is_atom(app) and is_binary(from),
       do: Path.join([Application.app_dir(app), from | segments])
  defp path(from, segments),
       do: Path.join([from | segments])

  defp subset([h | expected], [h | actual]),
       do: subset(expected, actual)
  defp subset([], actual),
       do: actual
  defp subset(_, _),
       do: []

  defp invalid_path?(list) do
    invalid_path?(list, :binary.compile_pattern(["/", "\\", ":", "\0"]))
  end

  defp invalid_path?([h | _], _match) when h in [".", "..", ""], do: true
  defp invalid_path?([h | t], match), do: String.contains?(h, match) or invalid_path?(t)
  defp invalid_path?([], _match), do: false
end
