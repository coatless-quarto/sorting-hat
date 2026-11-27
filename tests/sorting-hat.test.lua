-- sorting-hat tests. Run from the repo root: quarto pandoc lua path/to/qtest.lua
-- The fixtures run no code: plain code blocks, and cells written out in the
-- shape knitr and Jupyter give them (a .cell div with the cell options as
-- attributes), so no engine is needed.
local t = require("qtest")

--- Check which of the fixtures' three code blocks made it into the output.
---@param text string
---@param kept string[] markers that must be present
---@param gone string[] markers that must be absent
local function blocks(text, kept, gone)
  for _, m in ipairs(kept) do t.contains(text, m) end
  for _, m in ipairs(gone) do t.not_contains(text, m) end
end

t.test("html: keep leaves only that language, and wins over remove", function()
  local r = t.render("keep.qmd", "html")
  r:succeeded()
  r:no_warnings()
  blocks(r.text, { "py-marker" }, { "r-marker", "bash-marker" })
end)

t.test("typst: filtering works outside HTML", function()
  local r = t.render("keep.qmd", "typst")
  r:succeeded()
  blocks(r.text, { "py-marker" }, { "r-marker", "bash-marker" })
end)

-- Regression: a YAML list was stringified as a whole, so keep: [python, bash]
-- became the one language "pythonbash" and removed every block, and
-- remove: [r, bash] removed nothing.
t.test("keep and remove take a list of languages", function()
  local k = t.render("lists.qmd", "html")
  k:succeeded()
  blocks(k.text, { "py-marker", "bash-marker" }, { "r-marker" })
  local r = t.render("remove-list.qmd", "html")
  r:succeeded()
  blocks(r.text, { "py-marker" }, { "r-marker", "bash-marker" })
end)

t.test("action: collapse puts filtered code in a labelled <details>", function()
  local r = t.render("collapse.qmd", "html")
  r:succeeded()
  t.count(r.text, '<details><summary>R code (click to expand)</summary>', 1)
  t.in_order(r.text, { "<details>", "r-marker", "</details>" })
  t.not_contains(r.text:match("<details>.-</details>") or "", "py-marker")
end)

t.test("collapse outside HTML shows the code in full, without the label", function()
  local r = t.render("collapse.qmd", "typst")
  r:succeeded()
  blocks(r.text, { "py-marker", "r-marker", "bash-marker" }, { "click to expand" })
end)

t.test("placeholder and placeholder-style replace removed code", function()
  local r = t.render("placeholder.qmd", "html")
  r:succeeded()
  t.contains(r.text, '<div class="sorting-hat-placeholder" style="color: teal;">')
  t.contains(r.text, "<em>[r code hidden]</em>")
  t.not_contains(r.text, "r-marker")
end)

t.test("a sorting-hat cell option wins over keep, in any case", function()
  local r = t.render("overrides.qmd", "html")
  r:succeeded()
  blocks(r.text, { "r-override-keep", "py-override-collapse" },
    { "py-override-remove", "r-cell-filtered" })
  t.in_order(r.text, { "<summary>PYTHON code (click to expand)</summary>", "py-override-collapse" })
end)

-- Regression: logging only listened to an undocumented DEBUG key, so the
-- documented debug: true printed nothing.
t.test("debug: true logs each decision", function()
  local r = t.render("debug.qmd", "html")
  r:succeeded()
  t.contains(r.log, "Decision: Filter CodeBlock (r)")
end)

-- A page combines its options with the project's (Quarto 1.11), and
-- sorting-hat: false turns them off. Regression: a boolean
-- extensions: sorting-hat: value crashed the filter.
t.test("in a project, a page takes the project's options; sorting-hat: false turns them off", function()
  local r = t.render("project", "html", { output = "project/inherit.html", read = { "project/off.html" } })
  r:succeeded()
  blocks(r.text, { "py-marker" }, { "r-marker", "bash-marker" })
  blocks(r.extra["project/off.html"] or "", { "py-marker", "r-marker", "bash-marker" }, {})
end)
