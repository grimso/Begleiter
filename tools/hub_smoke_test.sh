#!/usr/bin/env bash
#
# Local smoke test for the Hugging Face download path.
#
# Mirrors what the iOS HubClient does: downloads each file in
# mlx-community/gemma-4-e4b-it-4bit (or a model passed as the first arg)
# into a local cache directory, showing progress. Run this from the Mac
# to isolate whether a download problem is HF-side (would also fail here)
# or iOS-side (would succeed here but fail on the device).
#
# Usage:
#   tools/hub_smoke_test.sh                                # default: gemma-4-e4b-it-4bit
#   tools/hub_smoke_test.sh mlx-community/gemma-4-e2b-it-4bit
#
# Output: timing + sizes per file. Files are saved under .cache/hf-smoke/<model>/.

set -euo pipefail

MODEL="${1:-mlx-community/gemma-4-e4b-it-4bit}"
CACHE_DIR=".cache/hf-smoke/${MODEL//\//_}"
BASE_URL="https://huggingface.co/${MODEL}/resolve/main"
API_URL="https://huggingface.co/api/models/${MODEL}"

mkdir -p "$CACHE_DIR"

echo "Model:     $MODEL"
echo "Cache:     $CACHE_DIR"
echo

echo "--- repo metadata ---"
curl -sL "$API_URL" | python3 -c "
import sys, json
m = json.load(sys.stdin)
print('  id:           ', m.get('id'))
print('  lastModified: ', m.get('lastModified'))
print('  downloads:    ', m.get('downloads'))
siblings = m.get('siblings') or []
print(f'  files ({len(siblings)}):')
for s in siblings:
    print('   ', s.get('rfilename'))
print()
"

# Files the iOS HubClient would pull, in the same order the loader needs them.
FILES=(
  "config.json"
  "tokenizer.json"
  "tokenizer_config.json"
  "generation_config.json"
  "chat_template.jinja"
  "processor_config.json"
  "model.safetensors.index.json"
  "model.safetensors"
)

total_bytes=0
total_start=$(date +%s)

for f in "${FILES[@]}"; do
  url="${BASE_URL}/${f}"
  dst="${CACHE_DIR}/${f}"

  # Get size up front
  size=$(curl -sLI "$url" 2>/dev/null | grep -i '^Content-Length:' | tail -1 | awk '{print $2}' | tr -d '\r')
  if [ -z "${size:-}" ] || [ "$size" -lt 100 ]; then
    echo "  ${f}: missing or tiny (size=${size:-?}), skipping"
    continue
  fi
  human=$(python3 -c "print(f'{${size}/1024/1024:.2f} MB' if ${size} >= 1024*1024 else f'{${size}/1024:.1f} KB')")
  echo "Downloading ${f} (${human})"

  start=$(date +%s)
  curl --fail --location --progress-bar -o "$dst" "$url"
  end=$(date +%s)
  elapsed=$((end - start))
  actual=$(stat -f%z "$dst")
  total_bytes=$((total_bytes + actual))

  if [ "$elapsed" -gt 0 ]; then
    speed=$(python3 -c "print(f'{${actual}/${elapsed}/1024/1024:.1f} MB/s')")
    echo "  done in ${elapsed}s (${speed})"
  else
    echo "  done in <1s"
  fi
done

total_end=$(date +%s)
total_elapsed=$((total_end - total_start))
total_human=$(python3 -c "print(f'{${total_bytes}/1024/1024/1024:.2f} GB')")
echo
echo "--- summary ---"
echo "  Total downloaded: ${total_human} in ${total_elapsed}s"
echo "  Cache dir:        $(pwd)/$CACHE_DIR"
