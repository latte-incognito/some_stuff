using Genie, Genie.Router, Genie.Renderer.Html, Genie.Requests
using HTTP, JSON

const MAX_MB = 15
const SAGE_CMD = `sage chat --model claude-3-5-sonnet --input -`  # change model if you want

# tiny helpers
escape_html(s::AbstractString) = replace(String(s), "&"=>"&amp;", "<"=>"&lt;", ">"=>"&gt;")
escape_attr(s::AbstractString) = replace(escape_html(s), "\""=>"&quot;")
is_valid_url(url::String) = startswith(url, "http://") || startswith(url, "https://")

# ── Helpers ───────────────────────────────────────────────────────────────────
function fetch_bytes(url::String; max_mb::Int = MAX_MB)
    r = HTTP.get(url; retry=false, status_exception=false, readtimeout=30)
    if r.status ÷ 100 != 2
        error("fetch failed: HTTP $(r.status)")
    end
    body = r.body
    if sizeof(body) > max_mb*1024*1024
        error("file too large (> $(max_mb)MB)")
    end
    return body
end

function redact(s::AbstractString)
    s = replace(String(s),
        r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}" => "<email>"; count=0)
    s = replace(s, r"https?://\S+" => "<url>"; count=0)
    s = replace(s, r"\s+" => " "; count=0)
    return s
end

# Parse Playwright "results.json" → (run_context::Dict, tests::Vector{Dict})
function parse_playwright_all(body::Vector{UInt8})
    data = JSON.parse(String(body))::Dict{String,Any}
    tests = Vector{Dict{String,Any}}()
    per_suite = Dict{String,Tuple{Int,Int}}()  # suite -> (passed, failed)

    full_title(node::Dict{String,Any}, titles::Vector{String}) = begin
        if haskey(node,"titlePath") && (node["titlePath"] isa Vector)
            join(String.(node["titlePath"]), " ")
        else
            t = haskey(node,"title") ? String(node["title"]) : "test"
            join(vcat(titles, [t]), " ")
        end
    end

    function walk(node, titles::Vector{String}=String[], file::String="")
        if node isa Dict{String,Any}
            t2 = copy(titles)
            if haskey(node,"title") && (node["title"] isa AbstractString)
                push!(t2, String(node["title"]))
            end
            f2 = file
            if haskey(node,"file") && (node["file"] isa AbstractString)
                f2 = String(node["file"])
            elseif haskey(node,"location") && (node["location"] isa Dict{String,Any}) && haskey(node["location"],"file")
                f2 = String(node["location"]["file"])
            end

            if haskey(node,"results") && (node["results"] isa Vector) && (haskey(node,"title") || haskey(node,"titlePath"))
                title = full_title(node, t2)
                id = isempty(f2) ? title : string(f2,"::",title)
                results = Vector{Any}(node["results"])
                final_status = "passed"
                duration_ms = 0
                err_type = ""
                err_msg  = ""
                any_pass = false
                tries = 0

                for res_any in results
                    res = res_any::Dict{String,Any}
                    st = haskey(res,"status") ? String(res["status"]) :
                         (haskey(res,"outcome") ? String(res["outcome"]) : final_status)
                    final_status = st

                    d = haskey(res,"durationMs") ? Int(res["durationMs"]) :
                        (haskey(res,"duration") ? Int(res["duration"]) : 0)
                    duration_ms = max(duration_ms, d)

                    err = haskey(res,"error") ? res["error"] :
                          (haskey(res,"errors") && (res["errors"] isa Vector) && !isempty(res["errors"]) ? res["errors"][1] : nothing)
                    if err isa Dict{String,Any}
                        msg = string(get(err,"message",""), " ", get(err,"stack",""))
                        if !isempty(msg) && isempty(err_msg)
                            err_msg = msg
                        end
                        et = get(err, "name", get(err, "type", ""))
                        if (et isa AbstractString) && isempty(err_type)
                            err_type = String(et)
                        end
                    end

                    any_pass |= (st == "passed")
                    tries += 1
                end

                status = (final_status in ("failed","timedOut","interrupted","unexpected") || !isempty(err_msg)) ? "failed" : "passed"
                t = Dict("test_id"=>id, "status"=>status, "time_ms"=>duration_ms)
                if status == "failed"
                    msg = redact(err_msg)
                    msg = msg[1:min(end,300)]
                    t["err_type"] = err_type
                    t["err_msg"]  = msg
                    t["retries"]  = max(tries-1, 0)
                    t["passed_on_retry"] = any_pass
                end
                push!(tests, t)
                per_suite[f2] = get(per_suite, f2, (0,0)) .+ (status=="passed" ? (1,0) : (0,1))
            end

            for (_,v) in node
                if v isa Dict{String,Any} || v isa Vector
                    walk(v, t2, f2)
                end
            end
        elseif node isa Vector
            for v in node
                walk(v, titles, file)
            end
        end
    end

    walk(data)
    total = length(tests)
    failed = count(t -> t["status"]=="failed", tests)
    per_suite_arr = [Dict("suite"=>k, "passed"=>p, "failed"=>f) for (k,(p,f)) in per_suite]
    run_ctx = Dict(
        "total_tests"=>total,
        "failed"=>failed,
        "pass_rate" => total==0 ? 0.0 : round((total-failed)/total; digits=3),
        "per_suite" => per_suite_arr,
    )
    return run_ctx, tests
end

function call_sage(payload_json::String)
    prompt = """
You are a strict classifier for Playwright test results.
Input JSON has {run_context, tests}. Return ONLY a JSON array for FAILED tests:
{
  "test_id": "...",
  "verdict": "Likely Flaky"|"Likely Real Bug"|"Unknown",
  "confidence": 0..1,
  "reason": "timeout|selector|network|assert|app-error|client-4xx|other",
  "rationale": "1–2 sentences using run_context & sibling pass info",
  "next_action": "one practical step"
}
JSON only.
"""
    txt = prompt * "\nInput:\n" * payload_json
    # Capture stdout; many CLIs print clean JSON to stdout
    out = read(pipeline(SAGE_CMD; stdin=IOBuffer(txt)), String)
    # Slice from first '[' or '{' in case CLI prints headers
    s = findfirst('[', out); s === nothing && (s = findfirst('{', out))
    return s === nothing ? out : out[first(s):end]
end

# ── UI (same dark/violet theme) ───────────────────────────────────────────────
function page_html(; url_value::String="",
                     summary::String="Submit to see results…",
                     llm::String="",
                     error_msg::String="")
    css = """
    body{background:#0b0a10;color:#EDE9FE;font-family:ui-sans-serif,system-ui;}
    .bar{padding:12px 16px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
    input{flex:1;padding:8px 12px;border:2px solid #7c3aed;border-radius:8px;background:#1a1325;color:#EDE9FE;min-width:280px}
    button{padding:8px 16px;border-radius:8px;background:#a855f7;color:#EDE9FE;border:none}
    .cols{display:grid;grid-template-columns:1fr 1fr;gap:12px;height:calc(100vh - 160px);padding:0 16px 16px}
    .card{background:#120d1a;border-radius:12px;padding:12px;display:flex;flex-direction:column}
    .title{color:#c084fc;margin-bottom:6px}
    pre{background:#0f0b18;border-radius:8px;flex:1;overflow:auto;padding:10px;white-space:pre-wrap}
    .err{margin:8px 16px 0 16px;padding:8px 12px;border-radius:8px;
         background:#2a0f19;border:1px solid #ef4444;color:#fecaca;}
    """
    err_html = isempty(error_msg) ? "" : "<div class=\"err\">$(escape_html(error_msg))</div>"
    return """
<!doctype html><html><head><meta charset="utf-8"><title>Playwright Analyzer (Julia)</title>
<style>$css</style></head><body>
  <div class="bar">
    <div style="color:#c084fc">Playwright Last-Run Analyzer</div>
    <form method="post" action="/analyze" style="display:flex;gap:8px;flex:1">
      <input name="url" value="$(escape_attr(url_value))"
             placeholder="Presigned S3 URL to results.json…"
             required pattern="https?://.*">
      <button type="submit">Send</button>
    </form>
  </div>
  $err_html
  <div class="cols">
    <div class="card"><div class="title">Errors summary</div><pre>$(summary)</pre></div>
    <div class="card"><div class="title">Claude response</div><pre>$(replace(llm, "&"=>"&amp;"))</pre></div>
  </div>
</body></html>
"""
end


# ── Routes (no macros, version-agnostic) ──────────────────────────────────────
route("/", method = GET) do
    html(page_html())
end

route("/analyze", method = POST) do
    url = get(params(), :url, "")

    # quick client-friendly validation
    if !is_valid_url(url)
        return html(page_html(url_value=url, error_msg="Please paste a valid http(s) URL."))
    end

    try
        body = fetch_bytes(url)
        run_ctx, tests = parse_playwright_all(body)

        # compact payload; trim failed messages
        for t in tests
            if t["status"] == "failed" && haskey(t, "err_msg")
                msg = String(t["err_msg"])
                t["err_msg"] = msg[1: min(end, 300)]
            end
        end
        payload = JSON.json(Dict("run_context"=>run_ctx, "tests"=>tests))
        out = call_sage(payload)

        # summary (left)
        head = "total=$(run_ctx["total_tests"]) failed=$(run_ctx["failed"]) pass_rate=$(run_ctx["pass_rate"])\n\n"
        buf = IOBuffer()
        for t in tests
            if t["status"] == "failed"
                println(buf, "[", t["test_id"], "] time=", t["time_ms"], "ms")
                println(buf, "  ", get(t,"err_type",""), " :: ", get(t,"err_msg",""), "\n")
            end
        end
        summary = head * String(take!(buf))

        # render the same page with results and keep URL in the box
        html(page_html(url_value=url, summary=summary, llm=out))

    catch e
        # show friendly inline error banner, stay on page
        html(page_html(url_value=url, error_msg="Error: $(sprint(showerror, e))"))
    end
end


Genie.config.run_as_server = true
Genie.config.server_host = "127.0.0.1"
Genie.config.server_port = 8080
Genie.up()                    # blocking; or Genie.up(async=false)

