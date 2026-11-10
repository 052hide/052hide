#!/usr/bin/env bash
# 年ごとのメトリクス SVG(metrics/<年>.svg)を gh CLI だけで生成する
#
# 使い方:
#   ./scripts/update-metrics.sh
#
# 必要なもの: gh(ログイン済み), jq
#
# 年ごとのコミット情報は Search API(30回/分の制限あり)で取得するため、
# 過去の年の結果は .cache/metrics/ にキャッシュし、今年の分だけ毎回取り直す。
set -euo pipefail

cd "$(dirname "$0")/.."

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "$cmd が見つかりません" >&2; exit 1; }
done

if ! gh auth status >/dev/null 2>&1; then
  echo "gh にログインしていません。先に 'gh auth login' を実行してください" >&2
  exit 1
fi

CACHE=.cache/metrics
OUT=metrics
mkdir -p "$CACHE" "$OUT"
THIS_YEAR=$(date +%Y)

LOGIN=$(gh api user --jq .login)
FIRST_YEAR=$(gh api user --jq '.created_at[0:4]')
YEARS=$(seq "$FIRST_YEAR" "$THIS_YEAR")

# ---- 年ごとの草 ----
# 複数年を1クエリにまとめるとタイムアウトするので1年ずつ取得する
fetch_calendar() { # $1=年
  gh api graphql -f query="query {
    viewer {
      contributionsCollection(from: \"$1-01-01T00:00:00+09:00\", to: \"$1-12-31T23:59:59+09:00\") {
        contributionCalendar { totalContributions weeks { contributionDays { weekday contributionLevel } } }
      }
    }
  }" --jq .data.viewer.contributionsCollection.contributionCalendar
}

# ---- 年ごとのコミット(Search API) ----
search_page() { # $1=日付範囲 $2=ページ
  local attempt res
  for attempt in 1 2 3 4 5; do
    sleep 3
    if res=$(gh api -X GET search/commits \
        -f q="author:$LOGIN author-date:$1" -f per_page=100 -f page="$2" \
        --jq '{total: .total_count, repos: [.items[].repository.full_name]}' 2>/dev/null); then
      echo "$res"
      return 0
    fi
    # 二次レート制限(HTTP 403)に当たったら少し待って再試行する
    echo "  rate limited ($1 page $2), retry $attempt/5 in 60s..." >&2
    sleep 60
  done
  echo "Search API の呼び出しに失敗しました: $1 page $2" >&2
  return 1
}

fetch_range() { # $1=日付範囲。最大1,000件(10ページ)までページごとのJSONを出力
  local first total pages p
  first=$(search_page "$1" 1)
  echo "$first"
  total=$(jq .total <<<"$first")
  pages=$(( (total + 99) / 100 ))
  (( pages > 10 )) && pages=10
  for (( p = 2; p <= pages; p++ )); do search_page "$1" "$p"; done
}

last_day() { # $1=年 $2=月
  case $2 in
    02) if (( $1 % 4 == 0 && ($1 % 100 != 0 || $1 % 400 == 0) )); then echo 29; else echo 28; fi ;;
    04|06|09|11) echo 30 ;;
    *) echo 31 ;;
  esac
}

fetch_year() { # $1=年。{year, total, repos: {リポジトリ名: コミット数}} を出力
  local y=$1 total m
  total=$(search_page "$y-01-01..$y-12-31" 1 | jq .total)
  {
    if (( total <= 1000 )); then
      fetch_range "$y-01-01..$y-12-31"
    else
      # 1回の検索で取れるのは1,000件までなので、超える年は月ごとに分割する
      for m in 01 02 03 04 05 06 07 08 09 10 11 12; do
        fetch_range "$y-$m-01..$y-$m-$(last_day "$y" "$m")"
      done
    fi
  } | jq -s --argjson year "$y" --argjson total "$total" \
      '{year: $year, total: $total, repos: (map(.repos[]) | group_by(.) | map({key: .[0], value: length}) | from_entries)}'
}

# ---- リポジトリの言語(未取得のものだけ取りに行く) ----
langs='{}'
fetch_langs() { # $1=リポジトリ名のJSON配列。結果をグローバル変数 langs に追加する
  local missing count i q res
  missing=$(jq --argjson langs "$langs" 'map(select($langs[.] == null))' <<<"$1")
  count=$(jq length <<<"$missing")
  for (( i = 0; i < count; i += 50 )); do
    q=$(jq -r --argjson i "$i" '
      .[$i:$i + 50] | to_entries
      | map((.value | split("/")) as [$o, $n]
            | "r\(.key): repository(owner: \"\($o)\", name: \"\($n)\") { languages(first: 20) { edges { size node { name color } } } }")
      | "query { " + join(" ") + " }"' <<<"$missing")
    # 削除済みなどでアクセスできないリポジトリがあるとエラー終了するが、取得できた分は使う
    res=$(gh api graphql -f query="$q" 2>/dev/null || true)
    # 取得できなかったリポジトリは [] にして、同じ実行内で何度も取りに行かないようにする
    langs=$(jq -n --argjson acc "$langs" --argjson repos "$missing" --argjson i "$i" --argjson res "${res:-"{}"}" '
      $acc + ($repos[$i:$i + 50] | map({key: ., value: []}) | from_entries)
           + (($res.data // {}) | to_entries | map(select(.value != null))
              | map({ key: $repos[$i + (.key[1:] | tonumber)],
                      value: [.value.languages.edges[] | {name: .node.name, color: (.node.color // "#8b949e"), size}] })
              | from_entries)')
  done
}

# ---- README の一覧を更新(生成済みの年だけ、新しい年が上) ----
update_readme() {
  local list y
  list=$(for y in $(seq "$THIS_YEAR" -1 "$FIRST_YEAR"); do
    [[ -s $OUT/$y.svg ]] && printf '![%s](%s/%s.svg)\n\n' "$y" "$OUT" "$y"
  done)
  # macOS の awk は -v で改行を含む値を渡せないので環境変数経由にする
  LIST="$list" awk '
    /<!-- metrics:start -->/ { print; print ""; print ENVIRON["LIST"]; skip = 1; next }
    /<!-- metrics:end -->/   { skip = 0 }
    !skip
  ' README.md > README.md.tmp
  mv README.md.tmp README.md
}

# ---- 1年ずつ「コミット取得 → 言語取得 → SVG 生成 → README 更新」 ----
for y in $YEARS; do
  f="$CACHE/commits-$y.json"
  if (( y == THIS_YEAR )) || [[ ! -s $f ]]; then
    echo "[$y] fetching commits..." >&2
    # `&&` でつなぐと set -e が効かないので分けて書く
    fetch_year "$y" > "$f.tmp"
    mv "$f.tmp" "$f"
  fi

  echo "[$y] fetching languages..." >&2
  fetch_langs "$(jq '.repos | keys' "$f")"

  jq -r \
    --argjson calendar "$(fetch_calendar "$y")" \
    --argjson langs "$langs" \
    -f scripts/render.jq "$f" > "$OUT/$y.svg"
  update_readme
  echo "[$y] rendered $OUT/$y.svg" >&2
done

echo "Done." >&2
