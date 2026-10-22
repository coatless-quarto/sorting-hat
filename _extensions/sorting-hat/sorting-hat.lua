local function is_empty(t)
  if t == nil then return true end
  if type(t) == "table" then
    return next(t) == nil
  end
  return false
end

local function has_value(tab, val)
  for _, value in ipairs(tab) do
    if value == val then
      return true
    end
  end
  return false
end

-- Extract string from Pandoc Meta types
local function extract_string(meta_value)
  if type(meta_value) == "string" then
    return meta_value
  elseif type(meta_value) == "table" then
    -- Try pandoc.utils.stringify
    local success, result = pcall(pandoc.utils.stringify, meta_value)
    if success and result then
      return result
    end
  end
  return tostring(meta_value)
end

-- Extract list of strings from Pandoc Meta types
local function extract_string_list(meta_value)
  local result = {}
  
  if type(meta_value) == "string" then
    -- Single string value
    table.insert(result, meta_value)
  elseif type(meta_value) == "table" then
    -- A YAML list arrives as a MetaList, so read one language per item.
    -- Anything else (MetaInlines, MetaString) is a single language.
    local items = pandoc.utils.type(meta_value) == "List" and meta_value or {meta_value}
    for _, item in ipairs(items) do
      local item_str = extract_string(item)
      if item_str and item_str ~= "" and not item_str:match("^table:") then
        table.insert(result, item_str)
      end
    end
  end
  
  return result
end

-- Determine if a language should be kept based on configuration
local function should_keep_language(language)
  -- If no language is specified, always keep
  if not language then
    return true
  end
  
  -- If keep list is specified, only keep blocks in that list
  if KEEP_LANGUAGES and not is_empty(KEEP_LANGUAGES) then
    local should_keep = has_value(KEEP_LANGUAGES, language)
    if DEBUG then
      quarto.log.output("Checking language '" .. language .. "' against keep list: " .. tostring(should_keep))
    end
    return should_keep
  end
  
  -- If remove list is specified, remove blocks in that list
  if REMOVE_LANGUAGES and not is_empty(REMOVE_LANGUAGES) then
    local should_remove = has_value(REMOVE_LANGUAGES, language)
    local should_keep = not should_remove
    if DEBUG then
      quarto.log.output("Checking language '" .. language .. "' against remove list: " .. tostring(should_keep))
    end
    return should_keep
  end
  
  -- If no configuration is set, keep all blocks
  return true
end

-- Check for cell-level override in attributes
local function get_cell_override(div)
  if not div.attributes then
    return nil
  end
  
  -- Check for sorting-hat attribute
  local override = div.attributes["sorting-hat"]
  if override then
    override = override:lower()
    if override == "keep" or override == "remove" or override == "collapse" then
      return override
    end
  end
  
  return nil
end

-- Create a placeholder div for removed content
local function create_placeholder(language)
  if not PLACEHOLDER then
    return {}
  end
  
  -- Replace {language} placeholder in text
  local text = PLACEHOLDER:gsub("{language}", language or "code")
  
  -- Create a div with the placeholder text
  local placeholder_div = pandoc.Div(
    {pandoc.Para({pandoc.Emph({pandoc.Str(text)})})},
    pandoc.Attr("", {"sorting-hat-placeholder"}, {})
  )
  
  -- Add custom style if specified
  if PLACEHOLDER_STYLE then
    placeholder_div.attributes["style"] = PLACEHOLDER_STYLE
  else
    -- Default style
    placeholder_div.attributes["style"] = "color: #888; font-style: italic; padding: 0.5em; border-left: 3px solid #ddd; margin: 1em 0;"
  end
  
  return placeholder_div
end

-- Create a collapsed version of the cell
local function create_collapsed_cell(div, language)
  -- Create a details/summary structure for collapsing
  local summary_text = language and (language:upper() .. " code (click to expand)") or "Code (click to expand)"
  
  -- Wrap the cell content in a details element
  local details = pandoc.Div(
    div.content,
    pandoc.Attr("", {"cell-collapsed"}, {})
  )
  
  -- For HTML output, use HTML details/summary
  -- For other formats, just add a note
  local collapsed_content = {
    pandoc.RawBlock("html", "<details><summary>" .. summary_text .. "</summary>"),
    details,
    pandoc.RawBlock("html", "</details>")
  }
  
  local collapsed_div = pandoc.Div(
    collapsed_content,
    pandoc.Attr("", {"sorting-hat-collapsed"}, {})
  )
  
  return collapsed_div
end

-- Read configuration from metadata
function Meta(meta)
  -- Reset global variables
  KEEP_LANGUAGES = nil
  REMOVE_LANGUAGES = nil
  DEBUG = false
  ACTION = "remove"  -- Default action: "remove" or "collapse"
  PLACEHOLDER = nil
  PLACEHOLDER_STYLE = nil
  
  -- Store configuration in global variables
  if meta.extensions and meta.extensions['sorting-hat'] then
    local config = meta.extensions['sorting-hat']
    
    -- Get debug setting first
    if config.debug then
      DEBUG = true
      quarto.log.output("=== Sorting Hat Extension Initialized ===")
    end
    
    -- Get list of languages to keep (if specified)
    if config.keep then
      KEEP_LANGUAGES = extract_string_list(config.keep)
      if DEBUG then
        quarto.log.output("Keep languages: " .. table.concat(KEEP_LANGUAGES, ", "))
      end
    end
    
    -- Get list of languages to remove (if specified)
    if config.remove then
      REMOVE_LANGUAGES = extract_string_list(config.remove)
      if DEBUG then
        quarto.log.output("Remove languages: " .. table.concat(REMOVE_LANGUAGES, ", "))
      end
    end
    
    -- Get action (remove or collapse)
    if config.action then
      ACTION = extract_string(config.action)
      if DEBUG then
        quarto.log.output("Action: " .. ACTION)
      end
    end
    
    -- Get placeholder text (if specified)
    if config.placeholder then
      PLACEHOLDER = extract_string(config.placeholder)
      if DEBUG then
        quarto.log.output("Placeholder: " .. PLACEHOLDER)
      end
    end
    
    -- Get placeholder style (if specified)
    if config['placeholder-style'] then
      PLACEHOLDER_STYLE = extract_string(config['placeholder-style'])
      if DEBUG then
        quarto.log.output("Placeholder style: " .. PLACEHOLDER_STYLE)
      end
    end
  end
  
  return meta
end

-- Filter Div elements (for Quarto cells which wrap code blocks and outputs)
function Div(div)
  -- Only process divs with class "cell"
  if not has_value(div.classes, "cell") then
    return div
  end
  
  if DEBUG then
    quarto.log.output("\n--- Processing Cell Div ---")
    quarto.log.output("Cell classes: " .. table.concat(div.classes, ", "))
  end
  
  -- Check for cell-level override first
  local override = get_cell_override(div)
  if override then
    if DEBUG then
      quarto.log.output("Cell-level override found: " .. override)
    end
    
    if override == "keep" then
      if DEBUG then
        quarto.log.output("Decision: KEEP cell (override)")
      end
      return div
    elseif override == "remove" then
      if DEBUG then
        quarto.log.output("Decision: REMOVE cell (override)")
      end
      -- Check if we should show a placeholder
      if PLACEHOLDER then
        local language = extract_cell_language(div)
        return create_placeholder(language)
      else
        return {}
      end
    elseif override == "collapse" then
      if DEBUG then
        quarto.log.output("Decision: COLLAPSE cell (override)")
      end
      local language = extract_cell_language(div)
      return create_collapsed_cell(div, language)
    end
  end
  
  -- Try to find language from code block inside the cell
  local language = extract_cell_language(div)
  
  if not language then
    if DEBUG then
      quarto.log.output("No language detected, keeping cell")
    end
    return div
  end
  
  -- Decide whether to keep the entire cell based on language
  if should_keep_language(language) then
    if DEBUG then
      quarto.log.output("Decision: KEEP cell (" .. language .. ")")
    end
    return div
  else
    -- Language should be filtered
    if DEBUG then
      quarto.log.output("Decision: Filter cell (" .. language .. ") - action: " .. ACTION)
    end
    
    if ACTION == "collapse" then
      return create_collapsed_cell(div, language)
    elseif PLACEHOLDER then
      return create_placeholder(language)
    else
      return {}
    end
  end
end

-- Extract language from a cell
function extract_cell_language(div)
  local language = nil
  
  if div.content then
    for _, block in ipairs(div.content) do
      -- Check for CodeBlock directly in cell
      if block.t == "CodeBlock" then
        if block.classes and #block.classes > 0 then
          -- Language is typically the first class (before "cell-code")
          for _, class in ipairs(block.classes) do
            if class ~= "cell-code" then
              language = class
              break
            end
          end
          if DEBUG then
            quarto.log.output("Found CodeBlock with classes: " .. table.concat(block.classes, ", "))
            quarto.log.output("Extracted language: " .. (language or "none"))
          end
          break
        end
      end
    end
  end
  
  return language
end

-- Filter standalone code blocks (for non-cell code blocks)
function CodeBlock(block)
  -- Skip if this is inside a cell (has cell-code class)
  if block.classes and has_value(block.classes, "cell-code") then
    return block
  end
  
  -- Get the language from the code block's classes
  local language = nil
  if block.classes and #block.classes > 0 then
    language = block.classes[1]
  end
  
  if DEBUG then
    if language then
      quarto.log.output("\n--- Processing CodeBlock ---")
      quarto.log.output("Classes: " .. table.concat(block.classes, ", "))
      quarto.log.output("Language: " .. language)
    end
  end
  
  -- Decide whether to keep or remove
  if should_keep_language(language) then
    if DEBUG and language then
      quarto.log.output("Decision: KEEP CodeBlock (" .. language .. ")")
    end
    return block
  else
    -- Language should be filtered
    if DEBUG and language then
      quarto.log.output("Decision: Filter CodeBlock (" .. language .. ") - action: " .. ACTION)
    end
    
    if ACTION == "collapse" then
      -- Wrap in a collapsed structure
      local summary_text = language and (language:upper() .. " code (click to expand)") or "Code (click to expand)"
      return pandoc.Div(
        {
          pandoc.RawBlock("html", "<details><summary>" .. summary_text .. "</summary>"),
          block,
          pandoc.RawBlock("html", "</details>")
        },
        pandoc.Attr("", {"sorting-hat-collapsed"}, {})
      )
    elseif PLACEHOLDER then
      return create_placeholder(language)
    else
      return {}
    end
  end
end

-- Return the filter functions in correct order
-- Meta must be processed first to set up globals
-- Then Div and CodeBlock can use those globals
return {
  {Meta = Meta},
  {Div = Div, CodeBlock = CodeBlock}
}