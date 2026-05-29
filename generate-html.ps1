$ErrorActionPreference = 'Stop'

function Escape-Html {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Convert-Inline {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    $result = New-Object System.Text.StringBuilder
    $matches = [regex]::Matches($Text, '`([^`]+)`')
    $position = 0

    foreach ($match in $matches) {
        $before = $Text.Substring($position, $match.Index - $position)
        [void]$result.Append((Escape-Html $before))

        $codeText = $match.Groups[1].Value
        [void]$result.Append('<button class="speak speak-code" type="button" data-speak="' +
            (Escape-Html $codeText) + '">' + (Escape-Html $codeText) + '</button>')

        $position = $match.Index + $match.Length
    }

    $tail = $Text.Substring($position)
    [void]$result.Append((Escape-Html $tail))

    return $result.ToString()
}

function Convert-TableCell {
    param([string]$Text)

    $trimmed = $Text.Trim()
    if ($trimmed -match '^[A-Za-z0-9][A-Za-z0-9\s\-/().:]*$') {
        return '<button class="speak speak-code" type="button" data-speak="' +
            (Escape-Html $trimmed) + '">' + (Escape-Html $trimmed) + '</button>'
    }
    return Convert-Inline $trimmed
}

function Get-SpeakText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $parts = New-Object System.Collections.Generic.List[string]
    $codeMatches = [regex]::Matches($Text, '`([^`]+)`')
    foreach ($match in $codeMatches) {
        $value = $match.Groups[1].Value.Trim()
        if ($value) { $parts.Add($value) }
    }

    if ($parts.Count -gt 0) {
        return (($parts | Select-Object -Unique) -join ' ')
    }

    $plain = $Text -replace '<br>', ' '
    $plain = $plain.Trim()

    if ($plain -match '^[A-Za-z0-9][A-Za-z0-9\s\-/().,:?''"]*$') {
        return $plain
    }

    $englishMatches = [regex]::Matches($plain, '(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9\-/]*(?:\s+[A-Za-z0-9][A-Za-z0-9\-/]*)*)(?![A-Za-z0-9])')
    foreach ($match in $englishMatches) {
        $value = $match.Groups[1].Value.Trim()
        if ($value) { $parts.Add($value) }
    }

    return (($parts | Select-Object -Unique) -join ' ').Trim()
}

function Add-LineSpeakButton {
    param(
        [string]$Html,
        [string]$SpeakText
    )

    if ([string]::IsNullOrWhiteSpace($SpeakText)) {
        return $Html
    }

    return $Html + ' <button class="speak-line" type="button" data-speak="' +
        (Escape-Html $SpeakText) + '" aria-label="朗读本句">Read</button>'
}

function Flush-List {
    param([System.Collections.Generic.List[string]]$ListBuffer)

    if ($ListBuffer.Count -eq 0) { return '' }
    $html = "<ul>`n" + (($ListBuffer | ForEach-Object { "  <li>$_</li>" }) -join "`n") + "`n</ul>"
    $ListBuffer.Clear()
    return $html
}

function Flush-Table {
    param([System.Collections.Generic.List[object]]$TableBuffer)

    if ($TableBuffer.Count -eq 0) { return '' }

    $rows = @($TableBuffer)
    $header = $rows[0]
    $bodyRows = @()
    if ($rows.Count -ge 3 -and ($rows[1] -join '') -match '^-+$') {
        $bodyRows = $rows[2..($rows.Count - 1)]
    } elseif ($rows.Count -gt 1) {
        $bodyRows = $rows[1..($rows.Count - 1)]
    }

    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<div class="table-wrap">')
    [void]$html.AppendLine('<table>')
    [void]$html.AppendLine('<thead><tr>')
    foreach ($cell in $header) {
        [void]$html.AppendLine('<th>' + (Convert-TableCell $cell) + '</th>')
    }
    [void]$html.AppendLine('</tr></thead>')
    if ($bodyRows.Count -gt 0) {
        [void]$html.AppendLine('<tbody>')
        foreach ($row in $bodyRows) {
            [void]$html.AppendLine('<tr>')
            foreach ($cell in $row) {
                [void]$html.AppendLine('<td>' + (Convert-TableCell $cell) + '</td>')
            }
            [void]$html.AppendLine('</tr>')
        }
        [void]$html.AppendLine('</tbody>')
    }
    [void]$html.AppendLine('</table>')
    [void]$html.AppendLine('</div>')
    $TableBuffer.Clear()
    return $html.ToString().TrimEnd()
}

function Convert-MarkdownToHtml {
    param([string]$Markdown)

    $lines = $Markdown -split "`r?`n"
    $htmlParts = New-Object System.Collections.Generic.List[string]
    $listBuffer = New-Object System.Collections.Generic.List[string]
    $tableBuffer = New-Object System.Collections.Generic.List[object]
    $inCodeBlock = $false
    $codeBuffer = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line.TrimStart().StartsWith('```')) {
            if ($inCodeBlock) {
                $htmlParts.Add((Flush-List $listBuffer))
                $htmlParts.Add((Flush-Table $tableBuffer))
                $codeHtml = "<pre><code>" + (Escape-Html (($codeBuffer -join "`n"))) + "</code></pre>"
                $htmlParts.Add($codeHtml)
                $codeBuffer.Clear()
                $inCodeBlock = $false
            } else {
                $htmlParts.Add((Flush-List $listBuffer))
                $htmlParts.Add((Flush-Table $tableBuffer))
                $inCodeBlock = $true
            }
            continue
        }

        if ($inCodeBlock) {
            $codeBuffer.Add($line)
            continue
        }

        if ($line.Trim() -eq '---') {
            $htmlParts.Add((Flush-List $listBuffer))
            $htmlParts.Add((Flush-Table $tableBuffer))
            $htmlParts.Add('<hr>')
            continue
        }

        if ($line.Trim() -match '^\|.*\|$') {
            $htmlParts.Add((Flush-List $listBuffer))
            $cells = ($line.Trim().Trim('|') -split '\|')
            $trimmed = @()
            foreach ($cell in $cells) { $trimmed += $cell.Trim() }
            $tableBuffer.Add($trimmed)
            continue
        } else {
            $tableHtml = Flush-Table $tableBuffer
            if ($tableHtml) { $htmlParts.Add($tableHtml) }
        }

        if ($line.Trim() -eq '') {
            $listHtml = Flush-List $listBuffer
            if ($listHtml) { $htmlParts.Add($listHtml) }
            continue
        }

        if ($line -match '^(#{1,6})\s+(.*)$') {
            $htmlParts.Add((Flush-List $listBuffer))
            $level = $matches[1].Length
            $htmlParts.Add("<h$level>" + (Convert-Inline $matches[2].Trim()) + "</h$level>")
            continue
        }

        if ($line -match '^\s*[-*]\s+(.*)$') {
            $itemText = $matches[1].Trim()
            $listBuffer.Add((Add-LineSpeakButton -Html (Convert-Inline $itemText) -SpeakText (Get-SpeakText $itemText)))
            continue
        }

        if ($line -match '^\s*\d+\.\s+(.*)$') {
            $itemText = $matches[1].Trim()
            $listBuffer.Add((Add-LineSpeakButton -Html (Convert-Inline $itemText) -SpeakText (Get-SpeakText $itemText)))
            continue
        }

        $htmlParts.Add((Flush-List $listBuffer))

        $trimmedLine = $line.TrimEnd()
        $content = Convert-Inline $trimmedLine.Trim()
        if ($line -match '\s{2}$') {
            $content += '<br>'
        }
        $content = Add-LineSpeakButton -Html $content -SpeakText (Get-SpeakText $trimmedLine.Trim())
        $htmlParts.Add('<p>' + $content + '</p>')
    }

    $htmlParts.Add((Flush-List $listBuffer))
    $htmlParts.Add((Flush-Table $tableBuffer))

    return ($htmlParts | Where-Object { $_ -and $_.Trim() -ne '' }) -join "`n"
}

function Build-HtmlDocument {
    param(
        [string]$Title,
        [string]$BodyHtml
    )

    $safeTitle = Escape-Html $Title
    return @"
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$safeTitle</title>
  <style>
    :root {
      --bg: #f4efe6;
      --panel: #fffaf2;
      --ink: #1f2937;
      --muted: #5b6472;
      --line: #e3d6c3;
      --accent: #b45309;
      --accent-soft: #fde7c7;
      --accent-strong: #7c2d12;
      --shadow: 0 14px 40px rgba(68, 42, 18, 0.08);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, #fff7ed 0, transparent 30%),
        linear-gradient(180deg, #f8f4ec 0%, #f0e6d8 100%);
      line-height: 1.7;
    }

    .page {
      max-width: 980px;
      margin: 0 auto;
      padding: 32px 18px 64px;
    }

    .hero {
      background: rgba(255, 250, 242, 0.92);
      border: 1px solid rgba(180, 83, 9, 0.16);
      border-radius: 24px;
      box-shadow: var(--shadow);
      padding: 24px 24px 18px;
      margin-bottom: 24px;
      backdrop-filter: blur(10px);
    }

    .hero h1 {
      margin: 0 0 10px;
      font-size: clamp(1.8rem, 4vw, 2.8rem);
      line-height: 1.2;
    }

    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 12px;
      color: var(--muted);
      font-size: 14px;
    }

    .badge {
      padding: 6px 10px;
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent-strong);
      border: 1px solid rgba(180, 83, 9, 0.18);
    }

    .player-controls {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 14px;
    }

    .player-btn {
      border: 1px solid rgba(180, 83, 9, 0.24);
      background: #fff7ed;
      color: #7c2d12;
      border-radius: 999px;
      padding: 8px 14px;
      font: inherit;
      cursor: pointer;
    }

    .player-btn:hover,
    .player-btn:focus-visible {
      background: #ffedd5;
      outline: none;
    }

    .content {
      background: rgba(255, 250, 242, 0.94);
      border: 1px solid rgba(180, 83, 9, 0.12);
      border-radius: 24px;
      padding: 26px;
      box-shadow: var(--shadow);
    }

    h1, h2, h3, h4, h5, h6 {
      line-height: 1.3;
      margin: 1.4em 0 0.6em;
      color: #2f2419;
    }

    h1:first-child, h2:first-child { margin-top: 0; }
    h2 { padding-top: 10px; border-top: 1px solid var(--line); }
    p { margin: 0.6em 0; }
    ul { padding-left: 1.4em; }
    li { margin: 0.35em 0; }
    hr { border: none; border-top: 1px solid var(--line); margin: 22px 0; }

    pre {
      background: #2a211b;
      color: #f8efe2;
      padding: 14px;
      border-radius: 14px;
      overflow: auto;
    }

    .table-wrap { overflow-x: auto; margin: 14px 0; }
    table {
      width: 100%;
      border-collapse: collapse;
      background: #fffdf8;
      border-radius: 16px;
      overflow: hidden;
    }

    th, td {
      border: 1px solid var(--line);
      padding: 10px 12px;
      text-align: left;
      vertical-align: top;
    }

    th {
      background: #f8ead6;
      color: #4a2d16;
    }

    .speak {
      border: none;
      background: none;
      padding: 0 2px;
      margin: 0;
      font: inherit;
      color: var(--accent-strong);
      cursor: pointer;
      border-radius: 6px;
      transition: background-color 0.15s ease, color 0.15s ease, transform 0.12s ease;
    }

    .speak:hover,
    .speak:focus-visible {
      background: var(--accent-soft);
      outline: none;
    }

    .speak.playing {
      background: #fed7aa;
      color: #7c2d12;
      transform: translateY(-1px);
    }

    .speak-code {
      padding: 2px 8px;
      background: #fff1db;
      border: 1px solid rgba(180, 83, 9, 0.2);
      font-family: Consolas, "Courier New", monospace;
    }

    .speak-line {
      margin-left: 8px;
      border: 1px solid rgba(180, 83, 9, 0.2);
      background: #fff7ed;
      color: #92400e;
      border-radius: 999px;
      padding: 2px 8px;
      font-size: 12px;
      cursor: pointer;
      vertical-align: middle;
    }

    .speak-line.playing {
      background: #fdba74;
      color: #7c2d12;
    }

    .tip {
      margin: 0;
      color: var(--muted);
    }

    @media (max-width: 640px) {
      .page { padding: 18px 12px 40px; }
      .hero, .content { padding: 18px; border-radius: 18px; }
      th, td { padding: 8px 9px; }
    }
  </style>
</head>
<body>
  <div class="page">
    <section class="hero">
      <h1>$safeTitle</h1>
      <p class="tip">Click English words, phrases, or sentence buttons to play audio. Works with your browser's local speech engine.</p>
      <div class="toolbar">
        <span class="badge">Tap to Speak</span>
        <span class="badge">Mobile and Desktop</span>
        <span class="badge">Sentence Playback</span>
      </div>
      <div class="player-controls">
        <button class="player-btn" type="button" id="play-all">Play All</button>
        <button class="player-btn" type="button" id="play-next">Next</button>
        <button class="player-btn" type="button" id="stop-play">Stop</button>
      </div>
    </section>
    <main class="content">
$BodyHtml
    </main>
  </div>
  <script>
    (() => {
      const synth = 'speechSynthesis' in window ? window.speechSynthesis : null;
      const canUseSpeech = synth && typeof window.SpeechSynthesisUtterance === 'function';
      let voices = [];
      let activeButton = null;
      let activeAudio = null;
      let sequence = [];
      let currentIndex = -1;
      let autoPlay = false;
      let playToken = 0;

      function clearActive() {
        if (activeButton) {
          activeButton.classList.remove('playing');
          activeButton = null;
        }
      }

      function stopAudio() {
        if (!activeAudio) return;
        activeAudio.pause();
        activeAudio.removeAttribute('src');
        activeAudio.load();
        activeAudio = null;
      }

      function markActive(button) {
        clearActive();
        activeButton = button;
        if (activeButton) activeButton.classList.add('playing');
      }

      function loadVoices() {
        if (!synth) return [];
        voices = synth.getVoices();
        return voices;
      }

      function startVoiceLoading() {
        if (!synth) return;

        loadVoices();

        if (typeof synth.addEventListener === 'function') {
          synth.addEventListener('voiceschanged', loadVoices);
        } else if ('onvoiceschanged' in synth) {
          synth.onvoiceschanged = loadVoices;
        }

        const timer = window.setInterval(() => {
          if (loadVoices().length) window.clearInterval(timer);
        }, 250);

        window.setTimeout(() => window.clearInterval(timer), 5000);
      }

      function chooseVoice() {
        const voiceList = voices.length ? voices : loadVoices();
        const preferred = voiceList.find(v => /^en-US/i.test(v.lang) || /United States|US English|Jenny|Aria|Samantha/i.test(v.name))
          || voiceList.find(v => /^en-GB/i.test(v.lang) || /UK English|Daniel|George|Hazel/i.test(v.name))
          || voiceList.find(v => /^en/i.test(v.lang));
        return preferred || null;
      }

      function getSequenceButtons() {
        return Array.from(document.querySelectorAll('.speak-line'));
      }

      function normalizeText(text) {
        return (text || '').replace(/\s+/g, ' ').trim();
      }

      function audioUrl(text) {
        const shortText = text.length > 450 ? text.slice(0, 450) : text;
        return 'https://dict.youdao.com/dictvoice?type=2&audio=' + encodeURIComponent(shortText);
      }

      function finishPlayback(token, onEnd) {
        if (token !== playToken) return;
        stopAudio();
        clearActive();
        if (typeof onEnd === 'function') onEnd();
      }

      function speakWithAudio(text, token, onEnd, onError) {
        stopAudio();

        const audio = new Audio(audioUrl(text));
        activeAudio = audio;
        audio.preload = 'auto';
        audio.onended = () => finishPlayback(token, onEnd);
        audio.onerror = () => {
          stopAudio();
          if (typeof onError === 'function') {
            onError();
          } else {
            finishPlayback(token, onEnd);
          }
        };
        audio.play().catch(() => {
          stopAudio();
          if (typeof onError === 'function') {
            onError();
          } else {
            finishPlayback(token, onEnd);
          }
        });
      }

      function speakWithBrowser(text, token, onEnd) {
        if (!canUseSpeech) {
          finishPlayback(token, onEnd);
          return;
        }

        if (synth.paused) synth.resume();

        const utterance = new SpeechSynthesisUtterance(text);
        utterance.lang = 'en-US';
        const voice = chooseVoice();
        if (voice) utterance.voice = voice;
        utterance.volume = 1;
        utterance.rate = 0.92;
        utterance.pitch = 1;

        let completed = false;

        utterance.onend = () => {
          if (completed) return;
          completed = true;
          finishPlayback(token, onEnd);
        };
        utterance.onerror = () => {
          if (completed) return;
          completed = true;
          finishPlayback(token, onEnd);
        };

        try {
          synth.speak(utterance);
          if (synth.paused) synth.resume();
        } catch (error) {
          finishPlayback(token, onEnd);
        }
      }

      function speak(text, button, onEnd) {
        text = normalizeText(text);
        if (!text) return;

        const token = ++playToken;
        stopAudio();
        markActive(button);

        if (synth) synth.cancel();
        speakWithAudio(text, token, onEnd, () => speakWithBrowser(text, token, onEnd));
      }

      function playIndex(index) {
        sequence = getSequenceButtons();
        if (!sequence.length) return;
        if (index < 0 || index >= sequence.length) {
          autoPlay = false;
          currentIndex = -1;
          return;
        }
        currentIndex = index;
        const button = sequence[currentIndex];
        const text = button.dataset.speak || button.textContent.trim();
        speak(text, button, () => {
          if (autoPlay) playIndex(currentIndex + 1);
        });
      }

      startVoiceLoading();

      window.addEventListener('beforeunload', () => {
        playToken += 1;
        stopAudio();
        if (synth) synth.cancel();
      });

      document.addEventListener('click', event => {
        const button = event.target.closest('.speak');
        if (button) {
          event.preventDefault();
          autoPlay = false;
          const text = button.dataset.speak || button.textContent.trim();
          speak(text, button);
          return;
        }

        const lineButton = event.target.closest('.speak-line');
        if (lineButton) {
          event.preventDefault();
          autoPlay = false;
          sequence = getSequenceButtons();
          currentIndex = sequence.indexOf(lineButton);
          const text = lineButton.dataset.speak || lineButton.textContent.trim();
          speak(text, lineButton);
          return;
        }
      });

      document.getElementById('play-all')?.addEventListener('click', () => {
        sequence = getSequenceButtons();
        if (!sequence.length) return;
        autoPlay = true;
        playIndex(currentIndex >= 0 ? currentIndex : 0);
      });

      document.getElementById('play-next')?.addEventListener('click', () => {
        sequence = getSequenceButtons();
        if (!sequence.length) return;
        autoPlay = false;
        const nextIndex = currentIndex >= 0 ? Math.min(currentIndex + 1, sequence.length - 1) : 0;
        playIndex(nextIndex);
      });

      document.getElementById('stop-play')?.addEventListener('click', () => {
        autoPlay = false;
        playToken += 1;
        stopAudio();
        if (synth) synth.cancel();
        clearActive();
      });
    })();
  </script>
</body>
</html>
"@
}

$files = Get-ChildItem -LiteralPath . -Filter *.md | Sort-Object Name

foreach ($file in $files) {
    $markdown = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
    $titleMatch = [regex]::Match($markdown, '^\s*#\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
    $bodyHtml = Convert-MarkdownToHtml $markdown
    $document = Build-HtmlDocument -Title $title -BodyHtml $bodyHtml
    $outputPath = Join-Path $file.DirectoryName ($file.BaseName + '.html')
    Set-Content -LiteralPath $outputPath -Value $document -Encoding UTF8
}

Write-Output "Generated $($files.Count) HTML files."
