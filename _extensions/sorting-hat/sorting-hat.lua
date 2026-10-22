-- What a `sorting-hat:` cell option asks for
---@alias Action "keep"|"remove"|"collapse"

---@class SortingHatConfig
---@field keep pandoc.List Languages to keep; when non-empty, all others are filtered
---@field remove pandoc.List Languages to filter when `keep` is empty
---@field action string How to handle filtered code: "collapse", or "remove" (the default)
---@field placeholder? string Text shown where code was removed; `{language}` is replaced
---@field placeholder_style? string CSS for the placeholder div
---@field debug boolean Log each decision

---@type SortingHatConfig
local config = {
  keep = pandoc.List(),
  remove = pandoc.List(),
  action = "remove",
  debug = false
}

local DEFAULT_PLACEHOLDER_STYLE = "color: #888; font-style: italic; padding: 0.5em; border-left: 3px solid #ddd; margin: 1em 0;"

-- Print a message when `debug: true` is set
---@param message string
local function log(message)
  if config.debug then
    quarto.log.output(message)
  end
end

-- Extract string from Pandoc Meta types
---@param value any
---@return string
local function read_string(value)
  if type(value) == "table" then
    return pandoc.utils.stringify(value)
  end
  return tostring(value)
end

-- Extract list of languages from Pandoc Meta types
---@param value any A single language or a YAML list of them
---@return pandoc.List languages
local function read_list(value)
  -- A YAML boolean names no language
  if type(value) == "boolean" then
    return pandoc.List()
  end
  -- A YAML list arrives as a MetaList, so read one language per item.
  -- Anything else (MetaInlines, MetaString) is a single language.
  local items = pandoc.utils.type(value) == "List" and value or {value}
  return pandoc.List(items):map(read_string):filter(function(language)
    return language ~= ""
  end)
end

-- Read configuration from `extensions: sorting-hat:` metadata
---@param meta pandoc.Meta
local function read_config(meta)
  local extensions = meta.extensions
  if type(extensions) ~= "table" then
    return
  end
  local options = extensions['sorting-hat']
  if type(options) ~= "table" then
    return
  end

  -- Get debug setting first
  if options.debug then
    config.debug = true
    log("=== Sorting Hat Extension Initialized ===")
  end

  if options.keep then
    config.keep = read_list(options.keep)
    log("Keep languages: " .. table.concat(config.keep, ", "))
  end

  if options.remove then
    config.remove = read_list(options.remove)
    log("Remove languages: " .. table.concat(config.remove, ", "))
  end

  if options.action then
    config.action = read_string(options.action)
    log("Action: " .. config.action)
  end

  if options.placeholder then
    local placeholder = read_string(options.placeholder)
    config.placeholder = placeholder
    log("Placeholder: " .. placeholder)
  end

  if options['placeholder-style'] then
    local style = read_string(options['placeholder-style'])
    config.placeholder_style = style
    log("Placeholder style: " .. style)
  end
end

-- Determine if a language should be kept based on configuration
---@param language string
---@return boolean
local function should_keep_language(language)
  -- If keep list is specified, only keep blocks in that list
  if #config.keep > 0 then
    local should_keep = config.keep:includes(language)
    log("Checking language '" .. language .. "' against keep list: " .. tostring(should_keep))
    return should_keep
  end

  -- If remove list is specified, remove blocks in that list
  if #config.remove > 0 then
    local should_keep = not config.remove:includes(language)
    log("Checking language '" .. language .. "' against remove list: " .. tostring(should_keep))
    return should_keep
  end

  -- If no configuration is set, keep all blocks
  return true
end

-- Check for a `sorting-hat:` cell option
---@param div pandoc.Div
---@return Action|nil
local function get_cell_override(div)
  local override = (div.attributes["sorting-hat"] or ""):lower()
  if override == "keep" or override == "remove" or override == "collapse" then
    return override
  end
  return nil
end

-- Extract language from the first code block in a cell
---@param div pandoc.Div
---@return string|nil
local function cell_language(div)
  for _, block in ipairs(div.content) do
    if block.t == "CodeBlock" and #block.classes > 0 then
      -- Language is typically the first class (before "cell-code")
      local language = block.classes:find_if(function(class)
        return class ~= "cell-code"
      end)
      log("Found CodeBlock with classes: " .. table.concat(block.classes, ", "))
      log("Extracted language: " .. (language or "none"))
      return language
    end
  end
  return nil
end

-- Create a placeholder div for removed content
---@param language? string
---@return pandoc.Div|pandoc.Blocks
local function create_placeholder(language)
  local template = config.placeholder
  if not template then
    return {}
  end

  -- Replace {language} placeholder in text
  local text = template:gsub("{language}", language or "code")

  return pandoc.Div(
    {pandoc.Para({pandoc.Emph({pandoc.Str(text)})})},
    pandoc.Attr("", {"sorting-hat-placeholder"}, {
      style = config.placeholder_style or DEFAULT_PLACEHOLDER_STYLE
    })
  )
end

-- Wrap a cell or code block in an HTML details/summary element
---@param el pandoc.Div|pandoc.CodeBlock
---@param language? string
---@return pandoc.Div
local function create_collapsed(el, language)
  local summary_text = language and (language:upper() .. " code (click to expand)") or "Code (click to expand)"

  -- A cell's content moves into a plain div, without the cell's attributes
  local inner = el
  if el.t == "Div" then
    inner = pandoc.Div(el.content, pandoc.Attr("", {"cell-collapsed"}, {}))
  end

  return pandoc.Div(
    {
      pandoc.RawBlock("html", "<details><summary>" .. summary_text .. "</summary>"),
      inner,
      pandoc.RawBlock("html", "</details>")
    },
    pandoc.Attr("", {"sorting-hat-collapsed"}, {})
  )
end

-- Keep a cell or code block, or collapse or remove it, based on its language
---@param el pandoc.Div|pandoc.CodeBlock
---@param language string
---@return pandoc.Div|pandoc.Blocks|nil
local function apply_action(el, language)
  local kind = el.t == "Div" and "cell" or "CodeBlock"
  if should_keep_language(language) then
    log("Decision: KEEP " .. kind .. " (" .. language .. ")")
    return nil
  end

  log("Decision: Filter " .. kind .. " (" .. language .. ") - action: " .. config.action)
  if config.action == "collapse" then
    return create_collapsed(el, language)
  end
  return create_placeholder(language)
end

-- Filter Div elements (for Quarto cells which wrap code blocks and outputs)
---@param div pandoc.Div
---@return pandoc.Div|pandoc.Blocks|nil
local function filter_cell(div)
  if not div.classes:includes("cell") then
    return nil
  end

  log("\n--- Processing Cell Div ---")
  log("Cell classes: " .. table.concat(div.classes, ", "))

  -- Check for cell-level override first
  local override = get_cell_override(div)
  if override then
    log("Cell-level override found: " .. override)
    log("Decision: " .. override:upper() .. " cell (override)")
    if override == "keep" then
      return nil
    elseif override == "collapse" then
      return create_collapsed(div, cell_language(div))
    elseif not config.placeholder then
      return {}
    end
    return create_placeholder(cell_language(div))
  end

  local language = cell_language(div)
  if not language then
    log("No language detected, keeping cell")
    return nil
  end

  return apply_action(div, language)
end

-- Filter standalone code blocks (cells are handled by filter_cell)
---@param block pandoc.CodeBlock
---@return pandoc.Div|pandoc.Blocks|nil
local function filter_code_block(block)
  local language = block.classes[1]
  if not language or block.classes:includes("cell-code") then
    return nil
  end

  log("\n--- Processing CodeBlock ---")
  log("Classes: " .. table.concat(block.classes, ", "))
  log("Language: " .. language)

  return apply_action(block, language)
end

-- Meta must be processed first so that the cells see the configuration
return {
  {Meta = read_config},
  {Div = filter_cell, CodeBlock = filter_code_block}
}
