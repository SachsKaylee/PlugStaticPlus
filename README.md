# PlugStaticPlus

See the original plug for the full documentation: [plug/static.ex](https://github.com/elixir-plug/plug/blob/master/lib/plug/static.ex)

## Features & Changes

  * Support for index handling. Requesting e.g. "/my-dir" while "/my-dir/index.html" exists will serve the "index.html" file. Respects the :custom_types setting if a reroute is performed.
    The index files can be specified by using the :index option with either a list of strings or a single string. The default is `["index.html", "index.htm", "index.js", "index.json"]`
  * Files can be served from the "/" directory. Will respect index definitions.

![Example](https://image.prntscr.com/image/sEUWelq9S9qJinBZxv9ZUA.png)

## License

Apache License 2.0

Based on parts of [Plug](https://github.com/elixir-plug/plug), which is licensed under the Apache License 2.0