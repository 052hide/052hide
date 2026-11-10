# 1年分のメトリクス SVG を組み立てる
# 入力: .cache/metrics/commits-<年>.json  {year, total, repos: {リポジトリ名: コミット数}}
# 引数: --argjson calendar  その年の contributionCalendar
#       --argjson langs     {リポジトリ名: [{name, color, size}]}


def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");
def comma: tostring | if length <= 3 then . else (.[0:-3] | comma) + "," + .[-3:] end;
def r1: . * 10 | round / 10;
def level:
  { "NONE": 0, "FIRST_QUARTILE": 1, "SECOND_QUARTILE": 2, "THIRD_QUARTILE": 3, "FOURTH_QUARTILE": 4 }[.] // 0;

. as $c

# ---- 言語: リポジトリの言語構成をコミット数で重み付けして集計 ----
| ($c.repos | to_entries
   | map(.value as $n
         | ($langs[.key] // []) as $ls
         | (($ls | map(.size) | add) // 0) as $sum
         | select($sum > 0)
         | $ls[] | { name, color, w: ($n * .size / $sum) })
   | group_by(.name)
   | map({ name: .[0].name, color: .[0].color, w: (map(.w) | add) })
   | sort_by(-.w)) as $all
| (($all | map(.w) | add) // 0) as $total
| ($all[:7] + (if ($all | length) > 7
                then [{ name: "Other", color: "#8b949e", w: ($all[7:] | map(.w) | add) }]
                else [] end)
   | map(. + { pct: (if $total > 0 then .w * 100 / $total else 0 end) })) as $ls

# ---- レイアウト ----
| 480 as $W
| 26 as $gx       # カレンダーの左端
| 60 as $gy       # カレンダーの上端
| 150 as $by      # 言語バーの上端
| 176 as $ly      # 凡例の1行目
| (if ($ls | length) > 0 then $ly + ((($ls | length) + 1) / 2 | floor) * 18 + 6 else $by + 30 end) as $H

| [
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\($W)\" height=\"\($H)\" viewBox=\"0 0 \($W) \($H)\">",
    "<style>",
    "text{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Helvetica,Arial,sans-serif;fill:#1f2328}",
    ".bg{fill:#ffffff;stroke:#d0d7de}.m{fill:#59636e}.b{font-weight:600}.e{fill:#eff2f5}",
    ".l0{fill:#eff2f5}.l1{fill:#aceebb}.l2{fill:#4ac26b}.l3{fill:#2da44e}.l4{fill:#116329}",
    "@media (prefers-color-scheme:dark){text{fill:#f0f6fc}.bg{fill:#0d1117;stroke:#30363d}.m{fill:#9198a1}.e{fill:#151b23}",
    ".l0{fill:#151b23}.l1{fill:#033a16}.l2{fill:#196c2e}.l3{fill:#2ea043}.l4{fill:#56d364}}",
    "</style>",
    "<rect class=\"bg\" x=\"0.5\" y=\"0.5\" width=\"\($W - 1)\" height=\"\($H - 1)\" rx=\"6\"/>",

    # ヘッダー
    "<text x=\"20\" y=\"36\" font-size=\"20\" class=\"b\">\($c.year)</text>",
    "<text x=\"\($W - 20)\" y=\"36\" font-size=\"12\" class=\"m\" text-anchor=\"end\">"
      + "<tspan class=\"b\" style=\"fill:currentColor\">\($c.total | comma)</tspan> commits · "
      + "\($calendar.totalContributions | comma) contributions</text>",

    # 草
    ($calendar.weeks
     | to_entries
     | map(.key as $w
           | .value.contributionDays[]
           | "<rect class=\"l\(.contributionLevel | level)\" x=\"\($gx + $w * 8)\" y=\"\($gy + .weekday * 8)\" width=\"7\" height=\"7\" rx=\"1.5\"/>")
     | join("")),

    # 言語
    "<text x=\"20\" y=\"140\" font-size=\"12\" class=\"b\">Languages</text>",
    "<clipPath id=\"bar\"><rect x=\"20\" y=\"\($by)\" width=\"\($W - 40)\" height=\"8\" rx=\"4\"/></clipPath>",
    "<g clip-path=\"url(#bar)\"><rect class=\"e\" x=\"20\" y=\"\($by)\" width=\"\($W - 40)\" height=\"8\"/>",
    ([foreach $ls[] as $l (0; . + $l.pct; { l: $l, end: . })]
     | map(((.end - .l.pct) * ($W - 40) / 100) as $x0
           | "<rect x=\"\(20 + $x0 | r1)\" y=\"\($by)\" width=\"\(.l.pct * ($W - 40) / 100 + 0.5 | r1)\" height=\"8\" fill=\"\(.l.color)\"/>")
     | join("")),
    "</g>",
    (if ($ls | length) == 0 then
       "<text x=\"20\" y=\"\($by + 24)\" font-size=\"11\" class=\"m\">No data</text>"
     else
       $ls
       | to_entries
       | map((20 + (.key % 2) * 230) as $x
             | ($ly + (.key / 2 | floor) * 18) as $y
             | "<circle cx=\"\($x + 4)\" cy=\"\($y - 4)\" r=\"4\" fill=\"\(.value.color)\"/>"
             + "<text x=\"\($x + 14)\" y=\"\($y)\" font-size=\"12\">\(.value.name | esc)</text>"
             + "<text x=\"\($x + 210)\" y=\"\($y)\" font-size=\"11\" class=\"m\" text-anchor=\"end\">\(.value.pct | r1)%</text>")
       | join("")
     end),

    "</svg>"
  ]
| join("\n")
