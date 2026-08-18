# Manual AI Test — Prove the Core Assumption First

This is **not executable code** and **does not require Xcode or a Mac**.
It's a step-by-step guide to manually testing the single riskiest
assumption behind this whole app — *"can Claude reliably solve a coding
question from a photo of my monitor?"* — before spending any time wiring
up cameras, CloudKit, or SwiftUI.

Do this first. If the AI can't solve real questions well from a real
screenshot, no amount of app-building fixes that — better to find out with
one `curl` command than after building the full pipeline.

## What you need

- Your Anthropic API key (from https://console.anthropic.com/ → API Keys).
- `curl` and `base64` — both are already on macOS/Linux by default.
- A real screenshot of a real coding-practice question (e.g. a CodeSignal
  question) as a `.png` or `.jpg` file.

## Step 1 — Take a real screenshot

Take an actual screenshot of an actual coding question on your monitor —
the more representative of what Phone A's camera will actually see, the
more useful this test is. If you want to test the "camera photo of a
monitor" scenario specifically (not just a clean screenshot), take a photo
with your phone's camera instead of a screenshot — that will more
realistically capture glare, angle, and resolution issues.

Save it somewhere easy to reference, e.g. `~/Desktop/question.png`.

## Step 2 — Set your API key as an environment variable

In your terminal:

```bash
export ANTHROPIC_API_KEY="sk-ant-...your-real-key-here..."
```

## Step 3 — Base64-encode the image

```bash
# macOS
base64 -i ~/Desktop/question.png -o ~/Desktop/question.b64

# Linux
base64 -w 0 ~/Desktop/question.png > ~/Desktop/question.b64
```

## Step 4 — Build and send the request

This uses a small script (still just `curl` + `jq` under the hood) so the
base64 data gets embedded into the JSON body correctly rather than fighting
shell quoting. Save this as `~/Desktop/test_claude_vision.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

IMAGE_PATH="$HOME/Desktop/question.png"
MEDIA_TYPE="image/png"   # change to "image/jpeg" if your file is a .jpg

IMAGE_B64=$(base64 < "$IMAGE_PATH" | tr -d '\n')

PROMPT='If this image shows a programming/coding practice question, extract and solve it in full with working code; otherwise respond exactly NONE.'

curl -sS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d @- <<EOF
{
  "model": "claude-opus-5",
  "max_tokens": 16000,
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "image",
          "source": {
            "type": "base64",
            "media_type": "$MEDIA_TYPE",
            "data": "$IMAGE_B64"
          }
        },
        {
          "type": "text",
          "text": "$PROMPT"
        }
      ]
    }
  ]
}
EOF
```

Then run it:

```bash
chmod +x ~/Desktop/test_claude_vision.sh
~/Desktop/test_claude_vision.sh | jq -r '.content[] | select(.type == "text") | .text'
```

(No `jq`? Drop the pipe and read the raw JSON response — the answer text
is in `content[0].text`, or a later element of the `content` array if a
`thinking` block precedes it.)

## Step 5 — Judge the result

You're checking for:

- **Did it correctly read the question from the image at all?** (OCR/
  vision quality — glare, angle, and resolution from a real phone-camera
  photo of a monitor can matter a lot more than from a clean screenshot.)
- **Is the solution actually correct** for the question shown?
- **Is the code complete and runnable**, not just a sketch/pseudocode?
- **Is the response well-formatted** for skimming at a glance on Phone B
  (this app doesn't do any post-processing of the answer text — whatever
  comes back from Claude is exactly what gets displayed) — if it isn't,
  consider tightening the prompt in `Services/AIVisionService.swift`
  (the `AIVisionService.prompt` constant) once you're in Xcode.

## Step 6 — Test the "NONE" path too

Repeat Step 4 with a screenshot of something that is clearly *not* a
coding question (e.g. your desktop background, an email, a video call).
Confirm the response text is exactly `NONE` — this is the signal
`AIVisionService.solveQuestion(from:)` in the real app relies on to know
"skip this frame, don't save anything to CloudKit."

## Once both cases look good

You've now validated the one part of this app that can't be debugged
by staring at Swift code — the actual "does the AI solve it correctly"
question. Move on to the Xcode setup steps in the top-level `README.md`.
