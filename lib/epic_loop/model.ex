defmodule EpicLoop.Model do
  @moduledoc "The only place a model is called. One shot, schema-bound, no memory."
  alias EpicLoop.{Log, Sh}

  def one_shot(name, model, prompt, schema, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 180_000)
    args = ["--bare", "-p", "--model", model, "--output-format", "json", "--json-schema", JSON.encode!(schema), "--permission-mode", "dontAsk", "--tools", ""]
    t0 = System.monotonic_time(:millisecond)
    r = Sh.json("claude", args, input: prompt, timeout: timeout, cwd: opts[:cwd] || System.tmp_dir!(), label: "model #{name} via #{model}")
    ms = System.monotonic_time(:millisecond) - t0
    out = (r.json && r.json["structured_output"]) || (r.json && is_binary(r.json["result"]) && Sh.decode(r.json["result"])) || nil
    Log.info("model", "#{name} via #{model} in #{ms}ms#{if out, do: "", else: " (no structured output)"}", out || %{code: r.code, stderr: String.slice(r.err, 0, 300)})
    out
  end

  def stall_schema,
    do: %{"type" => "object", "additionalProperties" => false, "required" => ["verdict", "reason"],
      "properties" => %{"verdict" => %{"type" => "string", "enum" => ["working", "stalled"]}, "reason" => %{"type" => "string"}}}

  def plan_answer_schema,
    do: %{"type" => "object", "additionalProperties" => false, "required" => ["answered", "answer", "reason"],
      "properties" => %{"answered" => %{"type" => "boolean"}, "answer" => %{"type" => "string"}, "reason" => %{"type" => "string"}}}

  def retry_schema,
    do: %{"type" => "object", "additionalProperties" => false, "required" => ["kind", "reason"],
      "properties" => %{"kind" => %{"type" => "string", "enum" => ["flaky", "environment", "defect"]}, "reason" => %{"type" => "string"}}}

  def review_schema,
    do: %{"type" => "object", "additionalProperties" => false, "required" => ["findings"],
      "properties" => %{"findings" => %{"type" => "array", "items" => %{"type" => "object", "additionalProperties" => false,
        "required" => ["severity", "path", "line", "rule", "summary", "check"],
        "properties" => %{
          "severity" => %{"type" => "string", "enum" => ["blocker", "warning", "note"]},
          "path" => %{"type" => "string"},
          "line" => %{"type" => ["integer", "null"]},
          "rule" => %{"type" => "string"},
          "summary" => %{"type" => "string"},
          "check" => %{"type" => ["string", "null"], "description" => "shell command run from the repo root that exits 0 once the finding is fixed and non-zero now; null if none exists"}}}}}}
end
