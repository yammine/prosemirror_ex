defimpl Inspect, for: ProsemirrorEx.Model.Node do
  def inspect(node, _opts) do
    ProsemirrorEx.Model.Node.debug_string(node)
  end
end

defimpl Inspect, for: ProsemirrorEx.Model.Fragment do
  def inspect(%ProsemirrorEx.Model.Fragment{content: [], size: 0}, _opts) do
    "<fragment>"
  end

  def inspect(fragment, _opts) do
    inner = ProsemirrorEx.Model.Fragment.to_string_inner(fragment)
    "<#{inner}>"
  end
end

defimpl Inspect, for: ProsemirrorEx.Model.Mark do
  def inspect(mark, _opts) do
    name = mark.type.name

    if mark.attrs == nil or mark.attrs == %{} do
      "#{name}"
    else
      attrs_str =
        mark.attrs
        |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{Kernel.inspect(v)}" end)

      "#{name}(#{attrs_str})"
    end
  end
end

defimpl Inspect, for: ProsemirrorEx.Model.Slice do
  def inspect(slice, _opts) do
    ProsemirrorEx.Model.Slice.to_string(slice)
  end
end

defimpl Inspect, for: ProsemirrorEx.Model.ResolvedPos do
  def inspect(rpos, _opts) do
    ProsemirrorEx.Model.ResolvedPos.to_string(rpos)
  end
end

defimpl Inspect, for: ProsemirrorEx.Model.NodeRange do
  def inspect(range, _opts) do
    from_s = ProsemirrorEx.Model.ResolvedPos.to_string(range.from)
    to_s = ProsemirrorEx.Model.ResolvedPos.to_string(range.to)
    "<NodeRange #{from_s}..#{to_s} depth=#{range.depth}>"
  end
end

defimpl String.Chars, for: ProsemirrorEx.Model.Node do
  def to_string(node) do
    ProsemirrorEx.Model.Node.debug_string(node)
  end
end

defimpl String.Chars, for: ProsemirrorEx.Model.Fragment do
  def to_string(%ProsemirrorEx.Model.Fragment{content: [], size: 0}) do
    "<fragment>"
  end

  def to_string(fragment) do
    inner = ProsemirrorEx.Model.Fragment.to_string_inner(fragment)
    "<#{inner}>"
  end
end

defimpl String.Chars, for: ProsemirrorEx.Model.Mark do
  def to_string(mark) do
    name = mark.type.name

    if mark.attrs == nil or mark.attrs == %{} do
      "#{name}"
    else
      attrs_str =
        mark.attrs
        |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{Kernel.inspect(v)}" end)

      "#{name}(#{attrs_str})"
    end
  end
end

defimpl String.Chars, for: ProsemirrorEx.Model.Slice do
  def to_string(slice) do
    ProsemirrorEx.Model.Slice.to_string(slice)
  end
end

defimpl String.Chars, for: ProsemirrorEx.Model.ResolvedPos do
  def to_string(rpos) do
    ProsemirrorEx.Model.ResolvedPos.to_string(rpos)
  end
end

defimpl String.Chars, for: ProsemirrorEx.Model.NodeRange do
  def to_string(range) do
    from_s = ProsemirrorEx.Model.ResolvedPos.to_string(range.from)
    to_s = ProsemirrorEx.Model.ResolvedPos.to_string(range.to)
    "<NodeRange #{from_s}..#{to_s} depth=#{range.depth}>"
  end
end

defimpl Jason.Encoder, for: ProsemirrorEx.Model.Node do
  def encode(node, opts) do
    node
    |> ProsemirrorEx.Model.Node.to_json()
    |> Jason.Encode.map(opts)
  end
end

defimpl Jason.Encoder, for: ProsemirrorEx.Model.Fragment do
  def encode(fragment, opts) do
    case ProsemirrorEx.Model.Fragment.to_json(fragment) do
      nil -> Jason.Encode.list([], opts)
      json -> Jason.Encode.list(json, opts)
    end
  end
end

defimpl Jason.Encoder, for: ProsemirrorEx.Model.Mark do
  def encode(mark, opts) do
    mark
    |> ProsemirrorEx.Model.Mark.to_json()
    |> Jason.Encode.map(opts)
  end
end

defimpl Jason.Encoder, for: ProsemirrorEx.Model.Slice do
  def encode(slice, opts) do
    case ProsemirrorEx.Model.Slice.to_json(slice) do
      nil -> Jason.Encode.map(%{}, opts)
      json -> Jason.Encode.map(json, opts)
    end
  end
end
