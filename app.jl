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
    <div class="card"><div class="title">Fetched content</div><pre>$(summary)</pre></div>
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
        body = fetch_bytes(url)  # Vector{UInt8}
        # Try to show as UTF-8 text; fallback to Base64 if binary
        content = try
            String(body)
        catch
            "Binary content (" * string(sizeof(body)) * " bytes). Base64 below:\n\n" * base64encode(body)
        end
        # Escape before injecting into HTML
        content_escaped = escape_html(content)
        info = "Fetched $(sizeof(body)) bytes from:\n" * escape_html(url) * "\n\n"
        summary = info * content_escaped
        html(page_html(url_value=url, summary=summary, llm=""))

    catch e
        # show friendly inline error banner, stay on page
        html(page_html(url_value=url, error_msg="Error: $(sprint(showerror, e))"))
    end
end


Genie.config.run_as_server = true
Genie.config.server_host = "127.0.0.1"
Genie.config.server_port = 8080
Genie.up()                    # blocking; or Genie.up(async=false)

