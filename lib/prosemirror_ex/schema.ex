defmodule ProsemirrorEx.Schema do
  @moduledoc """
  Optional convenience schemas matching the ProseMirror JavaScript packages
  [`prosemirror-schema-basic`](https://github.com/ProseMirror/prosemirror-schema-basic)
  and [`prosemirror-schema-list`](https://github.com/ProseMirror/prosemirror-schema-list).

  These modules expose node and mark specifications (without DOM parsing or
  serialization rules) that can be passed to `ProsemirrorEx.Model.Schema.new/1`
  or composed into custom schemas.

  * `ProsemirrorEx.Schema.Basic` — doc, paragraph, blockquote, heading, etc.
  * `ProsemirrorEx.Schema.List` — ordered and bullet lists (when available)
  """
end
