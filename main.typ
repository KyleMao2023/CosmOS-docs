#import "@preview/codelst:2.0.2": sourcecode, sourcefile, lineref, code-frame
#import "@preview/hydra:0.5.2": hydra
#let code-block = block.with(inset: 0.65em, radius: 4pt)
#show raw.where(block: true):it => code-block(sourcecode(
  it,
  showlines: true,
  numbers-step: 1,
  numbers-first: 1,
  highlighted: (),
  gutter: 7pt,
  label-regex: regex("<(highlight)>"),
  highlight-labels: true,
  numbers-align: right + top,
  highlight-color: rgb("#eaeabdad"),
  numbers-style: (i) => text(fill: rgb("#a0a0a0"), i),
))
#show raw.where(block: true): set block(inset: (top: 0.6pt, bottom: 0.6pt))
#show raw.where(block: true): set par(leading: 2.5mm, justify: false)
#show raw.where(block: true): set text(hyphenate: false, cjk-latin-spacing: none)
#show raw.where(block: true): it => {
  show strong: it2 => {
    set text(font: "Cascadia Mono PL", weight: 480)
    it2.body
  }
  show emph: it2 => {
    set text(font: ("Cascadia Mono PL", "Microsoft YaHei"), style: "italic")
    it2.body
  }
  it
}

#set par(justify: true, leading: 1.1em, spacing: 1.3em, first-line-indent: (amount: 2em, all: true))
#set text(12pt, font: ("Source Han Serif", "SimSun"), weight: 370, lang: "zh", region: "cn")
#show emph: text.with(font: ("Times New Roman", "STKaiti"))
#let title(body) = align(center, box(height: 20pt, text(22pt)[#strong(body)]))

// #show strong: text.with(font: ("Times New Roman", "SimHei"))
#set strong(delta: 350)

#show raw: set text(font: ("Cascadia Mono PL", "Microsoft YaHEI"), weight: "light", 10pt)
#set heading(bookmarked: true)
#show heading.where(level: 1): it => {
  set align(center)
  // set text(17pt, font: ("Source Han Sans VF"), weight: 500, lang: "zh", region: "cn")
  set text(17pt, font: ("Source Han Serif", "SimSun"), weight: 700, lang: "zh", region: "cn")
  set block(above: 1.6em, below: 1.5em)
  counter(figure.where(kind: "图")).update(0)
  counter(figure.where(kind: "表")).update(0)
  it
}
#show heading.where(level: 2):set block(above: 1.4em, below: 1.1em)
// #show heading.where(level: 2): set text(15pt, font: ("Source Han Sans VF"), fill: rgb("#0a5ba4"), weight: 500, lang: "zh", region: "cn")
#show heading.where(level: 2): set text(14pt, font: ("Source Han Serif", "SimSun"), fill: rgb("#0a5ba4"), weight: 700, lang: "zh", region: "cn")
#show heading.where(level: 3): set text(12.6pt, font: ("Source Han Serif", "SimSun"), weight: 650, lang: "zh", region: "cn")
#show heading.where(level: 3): set block(above: 1.5em, below: 1.1em)
#show heading.where(level: 4): set text(12.1pt, font: ("Source Han Sans", "SimSun"), fill: rgb("#0a5ba4"), weight: 500, lang: "zh", region: "cn")
#set table(stroke: 0.5pt, fill: (x, y) =>
if y == 0 {
  blue.lighten(80%)
}, align: center)
#show raw.where(block: false): box.with(fill: luma(240), inset: (x: 3pt, y: 0pt), outset: (y: 3pt), radius: 2pt)
#show figure: set block(breakable: true)
#show figure.where(kind: table): set figure.caption(position: top)
#show figure.where(kind: table): set figure(numbering: it => context{
  text(weight: 550, str(counter(heading).at(here()).at(0)) + "-" + str(it))
}, kind: "表", supplement: text(weight: 550)[表])
#show figure.where(kind: image): set figure.caption(position: bottom)
#show figure.where(kind: image): set figure(numbering: it => context{
  text(weight: 550, str(counter(heading).at(here()).at(0)) + "-" + str(it))
}, kind: "图", supplement: text(weight: 550)[图])
#show figure.caption: set text(0.9em)

#set heading(
  numbering: (..numbers) => {
    let level = numbers.pos().len()
    if (level == 1) { return numbering("一 ", numbers.pos().at(level - 1)) } else if (level == 2) { return numbering("1. 1  ", numbers.pos().at(level - 2), numbers.pos().at(level - 1)) } else if (level == 3) {
      return numbering("1. 1. 1  ", numbers.pos().at(level - 3), numbers.pos().at(level - 2), numbers.pos().at(level - 1))
    }
  },
)
#show image: set align(center)

#set page(width: 210mm, height: 297mm, margin: 25mm, header: context 
{
  set par(leading: 5pt, spacing: 5pt)
  text(10pt)[#hydra(2, skip-starting: false)]
  line(stroke: 0.7pt + rgb("#707070"), length: 100%)
})

/* ------ 封面 ------ */

#set page(background: image("cover.svg"))

#v(4.1em)
#align(center)[
  #text(75pt, font:"Bauhaus 93", fill: rgb("#00363A"))[
    Cosm#text(fill: rgb("#008c96"))[OS]
  ]

  #v(-5.8em)
  #text(30pt, font: "Source Han Sans", weight: 800, fill: rgb("#00363A").lighten(20%))[
    设计文档
  ]
]

#set page(background: none)

#show outline.entry.where(level: 1): strong
#outline(title: [目~~录], depth: 2)

#set page(background: none, numbering: "1")
#counter(page).update(1)


= 概述

#include "ch1-summary.typ"

= 任务调度

#include "ch2-task.typ"

= 进程管理

#include "ch3-process.typ"

= 内存管理

#include "ch4-mm.typ"

= 文件子系统

#include "ch5-fs.typ"

= 信号、等待队列与Polling子系统

#include "ch6-signal.typ"

= 网络栈

#include "ch7-net.typ"

= 硬件抽象层

#include "ch8-hal.typ"

= 总结与展望

#include "ch9-conclusion.typ"