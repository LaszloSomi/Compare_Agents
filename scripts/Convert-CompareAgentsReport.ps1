#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MarkdownPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$HtmlPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $MarkdownPath -PathType Leaf)) {
    throw "Markdown report not found: $MarkdownPath"
}

$resolvedMarkdownPath = (Resolve-Path -LiteralPath $MarkdownPath).Path
if ([string]::IsNullOrWhiteSpace($HtmlPath)) {
    $HtmlPath = [System.IO.Path]::ChangeExtension($resolvedMarkdownPath, '.html')
}

$outputDirectory = Split-Path -Parent $HtmlPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$markdown = Get-Content -Raw -LiteralPath $resolvedMarkdownPath
$converted = ConvertFrom-Markdown -InputObject $markdown
$reportBody = $converted.Html
$generatedAt = [System.Net.WebUtility]::HtmlEncode((Get-Date).ToString('yyyy-MM-dd HH:mm:ss K'))

$template = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Agent Builder Consolidation Assessment</title>
  <script>
    (() => {
      const param = new URLSearchParams(window.location.search).get("scoutTheme");
      const theme =
        param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
      document.documentElement.setAttribute("data-theme", theme);
    })();
  </script>
  <style>
    :root {
      color-scheme: light;
      --cp-bg: #f7f4ef;
      --cp-bg-elevated: #fcfbf8;
      --cp-surface: #ffffff;
      --cp-surface-soft: #f5f5f5;
      --cp-border: #dedede;
      --cp-border-strong: #919191;
      --cp-text: #242424;
      --cp-text-muted: #5c5c5c;
      --cp-text-soft: #6f6f6f;
      --cp-accent: #b11f4b;
      --cp-accent-hover: #9a1a41;
      --cp-accent-soft: rgba(177, 31, 75, 0.08);
      --cp-accent-fg: #ffffff;
      --cp-success: #16a34a;
      --cp-danger: #dc2626;
      --cp-warning: #f59e0b;
      --cp-link: #0078d4;
      --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
      --cp-overlay: rgba(255, 255, 255, 0.8);
      --cp-panel: rgba(255, 255, 255, 0.86);
      --cp-panel-strong: rgba(255, 255, 255, 0.96);
      --cp-sheen: rgba(255, 255, 255, 0.55);
      --cp-highlight: rgba(177, 31, 75, 0.12);
    }
    html[data-theme="dark"] {
      color-scheme: dark;
      --cp-bg: #3d3b3a;
      --cp-bg-elevated: #343231;
      --cp-surface: #292929;
      --cp-surface-soft: #2e2e2e;
      --cp-border: #474747;
      --cp-border-strong: #5f5f5f;
      --cp-text: #dedede;
      --cp-text-muted: #919191;
      --cp-text-soft: #b0b0b0;
      --cp-accent: #fd8ea1;
      --cp-accent-hover: #fb7b91;
      --cp-accent-soft: rgba(253, 142, 161, 0.14);
      --cp-accent-fg: #1a1a1a;
      --cp-success: #4ade80;
      --cp-danger: #f87171;
      --cp-warning: #fbbf24;
      --cp-link: #4da6ff;
      --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
      --cp-overlay: rgba(41, 41, 41, 0.88);
      --cp-panel: rgba(41, 41, 41, 0.72);
      --cp-panel-strong: rgba(41, 41, 41, 0.96);
      --cp-sheen: rgba(255, 255, 255, 0.04);
      --cp-highlight: rgba(253, 142, 161, 0.12);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      background: var(--cp-bg);
      color: var(--cp-text);
      font-family: "Segoe UI", Aptos, Calibri, -apple-system, BlinkMacSystemFont, sans-serif;
      line-height: 1.55;
    }
    main {
      width: min(96%, 100rem);
      margin: 2rem auto;
      padding: clamp(1rem, 3vw, 2.5rem);
      background: var(--cp-surface);
      border: 1px solid var(--cp-border);
      border-radius: 16px;
      box-shadow: var(--cp-shadow);
    }
    header {
      margin-bottom: 2rem;
      padding-bottom: 1rem;
      border-bottom: 1px solid var(--cp-border);
    }
    header p { margin: 0; color: var(--cp-text-muted); }
    h1, h2, h3, h4 { line-height: 1.2; scroll-margin-top: 1rem; }
    h1 { margin-top: 0; color: var(--cp-accent); }
    h2 {
      margin-top: 2.5rem;
      padding-bottom: 0.5rem;
      border-bottom: 1px solid var(--cp-border);
    }
    h3 {
      margin-top: 2rem;
      padding: 0.75rem 1rem;
      background: var(--cp-accent-soft);
      border-left: 0.25rem solid var(--cp-accent);
      border-radius: 0.625rem;
    }
    a { color: var(--cp-link); }
    a:hover { color: var(--cp-accent-hover); }
    code {
      padding: 0.125rem 0.3rem;
      background: var(--cp-surface-soft);
      border: 1px solid var(--cp-border);
      border-radius: 0.25rem;
      font-family: Consolas, "Courier New", Courier, monospace;
      overflow-wrap: anywhere;
    }
    pre {
      overflow-x: auto;
      padding: 1rem;
      background: var(--cp-surface-soft);
      border: 1px solid var(--cp-border);
      border-radius: 0.625rem;
    }
    pre code { padding: 0; border: 0; }
    blockquote {
      margin-left: 0;
      padding: 0.75rem 1rem;
      color: var(--cp-text-soft);
      background: var(--cp-surface-soft);
      border-left: 0.25rem solid var(--cp-border-strong);
    }
    table {
      display: block;
      width: 100%;
      margin: 1rem 0 1.5rem;
      overflow-x: auto;
      border-collapse: collapse;
      border: 1px solid var(--cp-border);
      border-radius: 0.625rem;
    }
    th, td {
      min-width: 8rem;
      padding: 0.65rem 0.75rem;
      text-align: left;
      vertical-align: top;
      border-right: 1px solid var(--cp-border);
      border-bottom: 1px solid var(--cp-border);
    }
    th {
      position: sticky;
      top: 0;
      background: var(--cp-bg-elevated);
      color: var(--cp-text);
      font-weight: 650;
    }
    tr:nth-child(even) td { background: var(--cp-surface-soft); }
    ul, ol { padding-left: 1.5rem; }
    footer {
      margin-top: 2.5rem;
      padding-top: 1rem;
      color: var(--cp-text-muted);
      border-top: 1px solid var(--cp-border);
      font-size: 0.875rem;
    }
    @media (max-width: 48rem) {
      main { width: 100%; margin: 0; border: 0; border-radius: 0; }
      th, td { min-width: 10rem; }
    }
    @media print {
      body { background: var(--cp-surface); }
      main { width: 100%; margin: 0; padding: 0; border: 0; box-shadow: none; }
      table { display: table; overflow: visible; font-size: 0.75rem; }
      a { color: var(--cp-text); text-decoration: none; }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <p>Microsoft 365 Copilot Agent Builder governance report</p>
    </header>
    __REPORT_BODY__
    <footer>Generated from the Markdown assessment on __GENERATED_AT__.</footer>
  </main>
</body>
</html>
'@

$html = $template.Replace('__REPORT_BODY__', $reportBody).Replace('__GENERATED_AT__', $generatedAt)
Set-Content -LiteralPath $HtmlPath -Value $html -Encoding utf8

Write-Host "HTML report created: $HtmlPath"
