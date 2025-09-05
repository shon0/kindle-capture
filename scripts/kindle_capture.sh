#!/usr/bin/env bash
set -euo pipefail

# kindle_capture.sh
# 使い方:
#   ./scripts/kindle_capture.sh "<TITLE>"
#   ./scripts/kindle_capture.sh --pdf-only "<TITLE>"

# 既定値（環境変数で上書き可能）
INTERVAL=${INTERVAL:-0.6}
TOP_PAD=${TOP_PAD:-0}
LEFT_PAD=${LEFT_PAD:-0}
RIGHT_PAD=${RIGHT_PAD:-0}
BOTTOM_PAD=${BOTTOM_PAD:-0}
ACTIVATE_EVERY=${ACTIVATE_EVERY:-20}
DIRECTION=${DIRECTION:-right}
# 自動モード用の安全上限（0=無制限）
MAX_PAGES=${MAX_PAGES:-0}

# 重複ページ検出のしきい値（画像比較用）
# ImageMagick がある場合: -fuzz に渡す割合（例: 0.5%）
FUZZ_PERCENT=${FUZZ_PERCENT:-0.5%}
# sips で BMP に変換して比較するフォールバックを使うか（true/false）
SIPS_FALLBACK=${SIPS_FALLBACK:-true}

# 対象アプリ識別子（環境に合わせて上書き可）
KINDLE_BUNDLE_ID=${KINDLE_BUNDLE_ID:-com.amazon.Kindle}
KINDLE_APP_NAME=${KINDLE_APP_NAME:-Kindle}

readonly INTERVAL TOP_PAD LEFT_PAD RIGHT_PAD BOTTOM_PAD ACTIVATE_EVERY DIRECTION KINDLE_BUNDLE_ID KINDLE_APP_NAME MAX_PAGES
readonly FUZZ_PERCENT SIPS_FALLBACK

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)

notifier() {
  local msg="$1"
  # ベストエフォートの通知送信（失敗しても無視）
  /usr/bin/osascript -e "display notification \"${msg}\" with title \"Kindle Capture\"" >/dev/null 2>&1 || true
}

sanitize_title() {
  # '/' を '／' に置換し、前後の空白をトリム
  # shellcheck disable=SC2001
  local t
  t=$(printf '%s' "$1" | sed 's,/,／,g')
  # 先頭/末尾のみトリム（中間スペースは維持）
  t=$(printf '%s' "$t" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  printf '%s' "$t"
}

ensure_img2pdf() {
  if ! command -v img2pdf >/dev/null 2>&1; then
    printf 'img2pdf is not installed. Run: make install\n' >&2
    return 1
  fi
}

kindle_activate() {
  # 起動の堅牢化: bundle id を優先し、既知の名称でフォールバック
  /usr/bin/open -b "${KINDLE_BUNDLE_ID}" >/dev/null 2>&1 \
    || /usr/bin/open -a "${KINDLE_APP_NAME}" >/dev/null 2>&1 \
    || /usr/bin/open -a "Amazon Kindle" >/dev/null 2>&1 \
    || /usr/bin/open -a "Kindle" >/dev/null 2>&1 \
    || true
}

kindle_send_arrow() {
  # Kindle を最前面にしてから矢印キーを送信
  # 右: 124 / 左: 123（key code）
  local code
  if [ "$DIRECTION" = "left" ]; then
    code=123
  else
    code=124
  fi
  /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1 || true
try
  -- System Events 経由で最前面へ（bundle id 優先、名称でフォールバック）
  tell application "System Events"
    set kProcs to (application processes whose bundle identifier is "${KINDLE_BUNDLE_ID}")
    if (count of kProcs) = 0 then set kProcs to (application processes whose name is "${KINDLE_APP_NAME}")
    if (count of kProcs) = 0 then set kProcs to (application processes whose name is "Amazon Kindle")
    if (count of kProcs) = 0 then set kProcs to (application processes whose name is "Kindle")
    if (count of kProcs) > 0 then set frontmost of item 1 of kProcs to true
  end tell
  delay 0.05
  tell application "System Events" to key code ${code}
end try
APPLESCRIPT
}

kindle_window_rect() {
  # 出力: x y w h（取得できない場合は空文字を返す）
  /usr/bin/osascript <<APPLESCRIPT
-- System Events でウィンドウの位置/サイズを取得（bundle id 優先、名称でフォールバック）
try
  tell application "System Events"
    set kProcs to (application processes whose bundle identifier is "${KINDLE_BUNDLE_ID}")
    if (count of kProcs) = 0 then error "Kindle not running"
    set kp to item 1 of kProcs
    if (exists window 1 of kp) then
      set p to position of window 1 of kp
      set s to size of window 1 of kp
      set x to item 1 of p
      set y to item 2 of p
      set w to item 1 of s
      set h to item 2 of s
      return (x as string) & " " & (y as string) & " " & (w as string) & " " & (h as string)
    else
      error "No Kindle window"
    end if
  end tell
on error errMsg
  try
    tell application "System Events"
      set kProcsByName to {}
      if (exists process "${KINDLE_APP_NAME}") then set end of kProcsByName to process "${KINDLE_APP_NAME}"
      if (exists process "Amazon Kindle") then set end of kProcsByName to process "Amazon Kindle"
      if (exists process "Kindle") then set end of kProcsByName to process "Kindle"
      if (count of kProcsByName) = 0 then error "Kindle not running"
      set kp to item 1 of kProcsByName
      if (exists window 1 of kp) then
        set p to position of window 1 of kp
        set s to size of window 1 of kp
        set x to item 1 of p
        set y to item 2 of p
        set w to item 1 of s
        set h to item 2 of s
        return (x as string) & " " & (y as string) & " " & (w as string) & " " & (h as string)
      else
        error "No Kindle window"
      end if
    end tell
  on error
    return ""
  end try
end try
APPLESCRIPT
}

region_with_padding() {
  # 入力: x y w h / 出力: 余白適用後の x y w h
  local x y w h
  x=$1; y=$2; w=$3; h=$4
  # 余白を適用（負値にならないよう検証）
  local nx ny nw nh
  nx=$(( x + LEFT_PAD ))
  ny=$(( y + TOP_PAD ))
  nw=$(( w - LEFT_PAD - RIGHT_PAD ))
  nh=$(( h - TOP_PAD - BOTTOM_PAD ))
  if [ $nw -le 0 ] || [ $nh -le 0 ]; then
    printf 'Error: Padding too large for current window size.\n' >&2
    return 1
  fi
  printf '%d %d %d %d' "$nx" "$ny" "$nw" "$nh"
}

next_index_from_existing() {
  # 既存の page_###.png から次に使う1始まりの連番を決定
  # 最大値+1を出力。存在しなければ1を出力
  local shots_dir="$1"
  local max=0 f base n
  if [ -d "$shots_dir" ]; then
    shopt -s nullglob
    for f in "$shots_dir"/page_[0-9][0-9][0-9].png; do
      base=${f##*/}
      n=${base#page_}
      n=${n%.png}
      n=$((10#$n))
      if [ "$n" -gt "$max" ]; then max=$n; fi
    done
    shopt -u nullglob
  fi
  printf '%d' $((max + 1))
}

zpad3() {
  # 3桁ゼロ埋め
  printf '%03d' "$1"
}

build_pdf() {
  local title="$1"
  local safe_title
  safe_title=$(sanitize_title "$title")
  local out_dir shots_dir pdf_path
  out_dir="${repo_root}/out/${safe_title}"
  shots_dir="${out_dir}/shots"
  pdf_path="${out_dir}/${safe_title}.pdf"

  ensure_img2pdf || return 1

  # 画像が存在することを前提にチェック
  if ! /bin/ls -1 "${shots_dir}"/page_*.png >/dev/null 2>&1; then
    printf 'No images found in %s\n' "${shots_dir}" >&2
    return 1
  fi

  # 並び順を維持して非再圧縮で PDF 作成
  img2pdf "${shots_dir}"/page_*.png -o "${pdf_path}"
}

# 見た目が同一かを判定（0: 同一, 1: 相違, その他: 失敗だが相違とみなす）
images_equal() {
  local a="$1" b="$2"

  # 1) ImageMagick の compare が使える場合（最も確実）
  if command -v magick >/dev/null 2>&1 || command -v compare >/dev/null 2>&1; then
    # コマンド名を決定
    local cmp_cmd ident_cmd
    if command -v magick >/dev/null 2>&1; then
      cmp_cmd=(magick compare)
      ident_cmd=(magick identify)
    else
      cmp_cmd=(compare)
      ident_cmd=(identify)
    fi

    # 総画素数を取得（割合判定に利用）
    local total_pixels
    if total_pixels=$("${ident_cmd[@]}" -format '%[fx:w*h]' "$a" 2>/dev/null); then
      :
    else
      total_pixels=0
    fi

    # AE: 差分ピクセル数、fuzz: 指定割合以内の色差は同一扱い
    local diff_pixels
    diff_pixels=$("${cmp_cmd[@]}" -metric AE -fuzz "$FUZZ_PERCENT" "$a" "$b" null: 2>&1 || true)

    # diff_pixels が数値で、0 なら同一
    if [[ "$diff_pixels" =~ ^[0-9]+$ ]]; then
      if [ "$diff_pixels" -eq 0 ]; then
        return 0
      fi
      # 画像サイズが分かれば極小割合（例: 0.001% 未満）も同一扱い
      if [ "$total_pixels" -gt 0 ]; then
        # 0.001% (= 1e-5) を閾値にする
        # bash で浮動小数が扱えないため、整数演算に変換: diff * 1_000_000 / total <= 100 (≒ 0.0001%)
        local scaled=$(( diff_pixels * 1000000 / total_pixels ))
        if [ "$scaled" -le 100 ]; then
          return 0
        fi
      fi
      return 1
    fi
    # 数値が取れない場合は相違とみなす
    return 1
  fi

  # 2) sips フォールバック: BMP へ無圧縮変換してバイト比較
  if [ "$SIPS_FALLBACK" = true ] && command -v sips >/dev/null 2>&1; then
    local ta tb rc=1
    ta=$(/usr/bin/mktemp -t kc_a.XXXXXX).bmp || return 1
    tb=$(/usr/bin/mktemp -t kc_b.XXXXXX).bmp || { /bin/rm -f -- "$ta"; return 1; }
    # 変換（quiet）
    /usr/bin/sips -s format bmp "$a" --out "$ta" >/dev/null 2>&1 || true
    /usr/bin/sips -s format bmp "$b" --out "$tb" >/dev/null 2>&1 || true
    if /usr/bin/cmp -s "$ta" "$tb"; then
      rc=0
    else
      rc=1
    fi
    /bin/rm -f -- "$ta" "$tb" || true
    return "$rc"
  fi

  # 3) 最後の手段: バイト比較（PNG のメタデータ差で誤判定の可能性あり）
  if /usr/bin/cmp -s "$a" "$b"; then
    return 0
  fi
  return 1
}

pdf_only_mode=false

case "${1-}" in
  --pdf-only)
    pdf_only_mode=true; shift || true ;;
esac

if [ "$pdf_only_mode" = true ]; then
  if [ $# -ne 1 ]; then
    printf 'Usage: %s --pdf-only "<TITLE>"\n' "$0" >&2
    exit 2
  fi
  build_pdf "$1"
  exit 0
fi

if [ $# -ne 1 ]; then
  printf 'Usage: %s "<TITLE>"\n' "$0" >&2
  exit 2
fi

TITLE="$1"

SAFE_TITLE=$(sanitize_title "$TITLE")
readonly SAFE_TITLE

OUT_DIR="${repo_root}/out/${SAFE_TITLE}"
SHOTS_DIR="${OUT_DIR}/shots"
PDF_PATH="${OUT_DIR}/${SAFE_TITLE}.pdf"

/bin/mkdir -p "${SHOTS_DIR}"

notifier "開始: ${TITLE} (自動検出)"

# スリープ抑止
/usr/bin/caffeinate -dimsu &
CAFFE_PID=$!
cleanup() {
  /bin/kill "$CAFFE_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# 初回のアクティベート
kindle_activate
/bin/sleep 0.2

# 開始インデックスを判定
next_index=$(next_index_from_existing "${SHOTS_DIR}")

# 新規開始（既存画像なし）の場合、矢印送信せず先頭ページを先に撮影
prev_file=""
if [ "$next_index" -eq 1 ]; then
  rect=$(kindle_window_rect)
  if [ -z "$rect" ]; then
    printf 'Unable to locate Kindle window. Is Kindle open?\n' >&2
    exit 1
  fi
  read -r x y w h <<< "$rect"
  read -r rx ry rw rh <<< "$(region_with_padding "$x" "$y" "$w" "$h")"
  fname="${SHOTS_DIR}/page_$(zpad3 "$next_index").png"
  /usr/sbin/screencapture -R "${rx},${ry},${rw},${rh}" -x "${fname}"
  next_index=$(( next_index + 1 ))
  prev_file="$fname"
  # 自動モードのみ。pages_remaining は未使用
else
  # 再開時は直前ページのファイルを prev_file に設定
  prev_idx=$(( next_index - 1 ))
  prev_file="${SHOTS_DIR}/page_$(zpad3 "$prev_idx").png"
fi

i=0
auto_captured=0
while : ; do
  i=$(( i + 1 ))
  # 定期的に Kindle を再アクティブ化してフォーカス維持（安全対策）
  if [ $(( i % ACTIVATE_EVERY )) -eq 0 ]; then
    kindle_activate
    # ごく短い待機
    /bin/sleep 0.2
  fi

  kindle_send_arrow
  /bin/sleep "$INTERVAL"

  rect=$(kindle_window_rect)
  if [ -z "$rect" ]; then
    printf 'Unable to locate Kindle window during capture.\n' >&2
    break
  fi
  read -r x y w h <<< "$rect"
  read -r rx ry rw rh <<< "$(region_with_padding "$x" "$y" "$w" "$h")"

  fname="${SHOTS_DIR}/page_$(zpad3 "$next_index").png"
  /usr/sbin/screencapture -R "${rx},${ry},${rw},${rh}" -x "${fname}"

  # 前ページと実質同一ならページが進んでいない=最終ページと判断
  if [ -n "$prev_file" ] && images_equal "$prev_file" "$fname"; then
    # 重複画像を削除して停止
    /bin/rm -f -- "$fname"
    notifier "最終ページを検出: ${TITLE}"
    break
  fi
  prev_file="$fname"
  auto_captured=$(( auto_captured + 1 ))
  # 安全上限（MAX_PAGES）に到達したら停止
  if [ "$MAX_PAGES" -gt 0 ] && [ "$auto_captured" -ge "$MAX_PAGES" ]; then
    printf 'Reached MAX_PAGES=%s in auto mode, stopping.\n' "$MAX_PAGES" >&2
    break
  fi
  next_index=$(( next_index + 1 ))
done

# img2pdf があれば PDF を生成
if command -v img2pdf >/dev/null 2>&1; then
  build_pdf "$TITLE" || true
else
  printf 'Note: img2pdf not found; skipping PDF generation.\n' >&2
fi

notifier "完了: ${TITLE}"

printf 'Done. Images: %s\n' "${SHOTS_DIR}"
printf 'PDF: %s\n' "${PDF_PATH}"
