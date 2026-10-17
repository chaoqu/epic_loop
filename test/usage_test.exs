defmodule EpicLoop.UsageTest do
  use ExUnit.Case, async: true
  alias EpicLoop.Usage

  @root "/wt/ticket-e1-1"

  setup do
    dir = Path.join(System.tmp_dir!(), "epic-loop-usage-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{f: Path.join(dir, "s1.jsonl")}
  end

  defp usage(cache_read, output), do: %{"input_tokens" => 10, "cache_read_input_tokens" => cache_read, "cache_creation_input_tokens" => 0, "output_tokens" => output}
  defp a(id, ctx, out, blocks), do: %{"type" => "assistant", "message" => %{"id" => id, "model" => "claude-opus-5-5", "usage" => usage(ctx - 10, out), "content" => blocks}}
  defp use_(id, name, input), do: %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  # A result whose content is `size` bytes as JSON, quotes included.
  defp result(id, size), do: %{"type" => "user", "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => String.duplicate("x", size - 2)}]}}

  # Each request's context, less the previous one's, is what was added between them; the numbers are
  # chosen so every share is exact.
  defp lines do
    [
      %{"type" => "user", "message" => %{"content" => "Read the brief"}},
      a("m1", 40_000, 100, [use_("r1", "Read", %{"file_path" => "#{@root}/a/B.kt"})]),
      result("r1", 4000),
      # +5100: the model's 100, then the Read's 5000
      a("m2", 45_100, 200, [use_("b1", "Bash", %{"command" => "cd a && cat C.kt \"D.kt\" | head -50"})]),
      a("m2", 45_100, 200, [use_("b2", "Bash", %{"command" => "./gradlew test > /tmp/out 2>&1"})]),
      %{"type" => "assistant", "isSidechain" => true, "message" => %{"id" => "x", "usage" => usage(900_000, 5), "content" => []}},
      result("b1", 3000),
      result("b2", 1000),
      # +4200: the model's 200, then 4000 split 3:1 between the two Bash calls
      a("m3", 49_300, 300, [%{"type" => "thinking", "thinking" => ""}]),
      a("m3", 49_300, 300, [use_("b3", "Bash", %{"command" => "cat E.kt"})]),
      result("b3", 1000),
      # a compaction: the context shrinks, and nothing is added
      a("m4", 40_000, 300, [%{"type" => "text", "text" => "Waiting."}]),
      %{"type" => "user", "message" => %{"content" => "Answer: yes"}},
      # +1000: the model's 300, then the prompt's 700
      a("m5", 41_000, 50, [%{"type" => "text", "text" => "Done."}])
    ]
    |> Enum.map(&JSON.encode!/1)
  end

  test "tokens, context, and what filled it: the model, prompts, each tool and each file read", %{f: f} do
    File.write!(f, Enum.join(lines(), "\n") <> "\n")
    st = Usage.read(f, @root, nil)

    assert st.tokens == %{input: 50, cache_read: 40_000 + 45_100 + 49_300 + 40_000 + 41_000 - 50, cache_write: 0, output: 950}
    assert {st.context, st.peak, st.model, st.prompts} == {41_000, 49_300, 600, 700}
    assert st.tools["Read"] == %{calls: 1, reads: 0, tokens: 5000}
    assert st.tools["Bash:read"] == %{calls: 2, reads: 0, tokens: 3000}
    assert st.tools["Bash:check"] == %{calls: 1, reads: 0, tokens: 1000}
    assert st.files == %{"a/B.kt" => %{calls: 0, reads: 1, tokens: 5000}, "a/C.kt" => %{calls: 0, reads: 1, tokens: 1500}, "a/D.kt" => %{calls: 0, reads: 1, tokens: 1500}, "a/E.kt" => %{calls: 0, reads: 1, tokens: 0}}

    s = Usage.summary(st, 2)
    assert [%{tool: "Read", tokens: 5000}, %{tool: "Bash:read", tokens: 3000, calls: 2}] = s.tools
    assert [%{path: "a/B.kt", tokens: 5000, reads: 1}, %{tokens: 1500}] = s.files
    assert s.filled == %{model: 600, prompts: 700, tools: 9000}
    assert {s.tool_count, s.file_count, s.window} == {3, 4, 1_000_000}
  end

  test "a transcript read in pieces, with a line still being written, adds up to one read whole", %{f: f} do
    {head, tail} = Enum.split(lines(), 6)
    [half_a, half_b] = (fn l -> [binary_part(l, 0, 20), binary_part(l, 20, byte_size(l) - 20)] end).(hd(tail))
    File.write!(f, Enum.join(head, "\n") <> "\n" <> half_a)
    st = Usage.read(f, @root, nil)
    assert st.offset == byte_size(Enum.join(head, "\n") <> "\n")

    File.write!(f, half_b <> "\n" <> Enum.join(tl(tail), "\n") <> "\n", [:append])
    whole = Usage.read(f, @root, nil)
    assert Map.delete(Usage.read(f, @root, nil, st), :pending) == Map.delete(whole, :pending)
    assert Usage.read(f, @root, nil, whole) == whole
  end

  test "files: Read paths, shell readers, and the working directory a cd leaves" do
    home = System.user_home!()
    assert Usage.files("Read", %{"file_path" => "#{@root}/web/Page.kt"}, "", @root) == {["web/Page.kt"], ""}
    assert Usage.files("Bash", %{"command" => "cd web && sed -n 1,80p Page.kt; head -n 20 ../README.md"}, "", @root) == {["web/Page.kt", "README.md"], "web"}
    assert Usage.files("Bash", %{"command" => "cat Page.kt > /tmp/copy; nl \"$f\""}, "web", @root) == {["web/Page.kt"], "web"}
    assert Usage.files("Bash", %{"command" => "cd /tmp && cat x.txt"}, "web", @root) == {["/tmp/x.txt"], ""}
    assert Usage.files("Bash", %{"command" => "cat ~/notes.md"}, "", @root) == {["~/notes.md"], ""}
    assert Usage.files("Bash", %{"command" => "grep -n page web/Page.kt"}, "", @root) == {[], ""}
    assert Usage.rel("#{home}/.claude/projects/-wt/abc/tool-results/b1.txt", @root) == "(saved tool output) b1.txt"
  end

  test "sessions combine: tokens and fills add up, the latest gives the context, the highest the peak" do
    a = %{Usage.new(@root) | tokens: %{input: 1, cache_read: 2, cache_write: 3, output: 4}, context: 300, peak: 500, model: 10, tools: %{"Read" => %{calls: 1, reads: 0, tokens: 7}}}
    b = %{Usage.new(@root) | tokens: %{input: 1, cache_read: 1, cache_write: 1, output: 1}, context: 100, peak: 200, model: 5, tools: %{"Read" => %{calls: 2, reads: 0, tokens: 3}}}
    c = Usage.combine([a, b])
    assert {c.tokens, c.context, c.peak, c.model, c.tools["Read"]} == {%{input: 2, cache_read: 3, cache_write: 4, output: 5}, 100, 500, 15, %{calls: 3, reads: 0, tokens: 10}}
    assert Usage.combine([]) == nil
  end
end
