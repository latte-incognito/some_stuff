using Genie, Genie.Router, Genie.Renderer.Html, Genie.Requests
using HTTP, JSON

const MAX_MB = 15

# tiny helpers
escape_html(s::AbstractString) = replace(String(s), "&"=>"&amp;", "<"=>"&lt;", ">"=>"&gt;")
escape_attr(s::AbstractString) = replace(escape_html(s), "\""=>"&quot;")
is_valid_url(url::String) = startswith(url, "http://") || startswith(url, "https://")

function escape_html_safe(s::AbstractString)
    s = replace(String(s), "&"=>"&amp;", "<"=>"&lt;", ">"=>"&gt;", "\"" => "&quot;")
    s = replace(s, "\u0024" => "\uFF04")  # escape dollar sign for Genie-generated Julia code
    return s
end


"""
    extract_test_data_with_hierarchy(path::String) -> Vector{Dict}

Extracts structured test results:
- title
- full_title (joined ancestorTitles + title)
- status
- duration
- retry count
- list of error messages (only .message)
"""
function extract_test_data_with_hierarchy(json_str::String)
    json = JSON.parse(json_str)

    results = []

   function walk_suites(suites, parent_titles=[])
        for suite in suites
            if !(suite isa Dict)
                continue
            end

            suite_title = get(suite, "title", "")
            new_parent_titles = isempty(suite_title) ? parent_titles : vcat(parent_titles, suite_title)

            # Recurse into child suites
            if haskey(suite, "suites") && suite["suites"] isa Vector
                walk_suites(suite["suites"], new_parent_titles)
            end

            # Process specs (leaf nodes)
            if haskey(suite, "specs") && suite["specs"] isa Vector
                for spec in suite["specs"]
                    if !(spec isa Dict)
                        continue
                    end

                    spec_title = get(spec, "title", "")
                    for test in get(spec, "tests", [])
                        if !(test isa Dict)
                            continue
                        end

                        test_title = get(test, "title", "")
                        full_title = join(vcat(new_parent_titles, spec_title, test_title), " > ")

                        for result in get(test, "results", [])
                            if !(result isa Dict)
                                continue
                            end

                            error_msg = ""
                            if haskey(result, "error") && result["error"] isa Dict
                                error_msg = get(result["error"], "message", "")
                            end

                            push!(results, Dict(
                                "full_title" => full_title,
                                "status"     => get(result, "status", "unknown"),
                                "duration"   => get(result, "duration", missing),
                                "error"      => error_msg,
                                "retry"      => get(result, "retry", missing)
                            ))
                        end
                    end
                end
            end
        end
    end

    if haskey(json, "suites") && json["suites"] isa Vector
        walk_suites(json["suites"])
    end

    return results
end

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

"""
call_llm(url::String, headers::Dict, payload::Dict) -> String

Sends a POST request with given headers and JSON payload.
Returns the body as String (UTF-8).
"""
function call_llm(url::String, headers::Dict{String,String}, payload::Dict)
    data = JSON.json(payload)
    r = HTTP.post(url; headers=headers, body=data)
    if r.status ÷ 100 != 2
        error("LLM request failed: HTTP $(r.status)")
    end
    return String(r.body)
end

# ── UI (same dark/violet theme) ───────────────────────────────────────────────
function page_html(; url_value::String="",
                     summary::String="Submit to see results…",
                     llm::String="",
                     error_msg::String="")
    
    safe_summary = escape_html_safe(summary)
    safe_llm     = escape_html_safe(llm)  # optional, but safe for consistency
    safe_error   = escape_html_safe(error_msg)

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
    <div class="card"><div class="title">Fetched content</div><pre>$safe_summary</pre></div>
    <div class="card"><div class="title">Claude response</div><pre>$safe_llm</pre></div>
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
       
        # Prepare your LLM payload (whatever JSON you want to send)
        payload = extract_test_data_with_hierarchy(content) # here `content` is the fetched body string

        api_key = get(ENV, "MY_LLM_KEY", nothing)
        if api_key === nothing
            error("Environment variable MY_LLM_KEY is not set")
        end
        # Change headers here
        headers = Dict(
            "Content-Type"  => "application/json",
            "Accept"        => "application/json",
            "X-Api-Key"     => "$api_key",
            "User-Agent"    => "Julia-Client/1.0"
        )

        llm_response = call_llm("https://example.com/endpoint", headers, payload)

        # escape to avoid HTML injection
        llm_html = escape_html(llm_response)

        html(page_html(url_value=url, summary=summary, llm=llm_html))

    catch e
        # show friendly inline error banner, stay on page
        html(page_html(url_value=url, error_msg="Error: $(sprint(showerror, e))"))
    end
end


Genie.config.run_as_server = true
Genie.config.server_host = "127.0.0.1"
Genie.config.server_port = 8080
Genie.up()                    # blocking; or Genie.up(async=false)

