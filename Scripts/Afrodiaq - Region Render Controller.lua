@description Region Render Controller
@version 1.0
@author Xavier 'Afrodiaq' Oshinowo
@about
--This script allows you to control the region render matrix without manually using it. Can search for the regions by name, filter by region number.

-- ---------- palette (from user-provided swatch) ----------
local PAL = {
  fog   = 0xD7D9E3FF, -- light gray-lavender  (window bg)
  sky   = 0x9BC0F7FF, -- light blue           (hover / header accent)
  denim = 0x6089BEFF, -- medium blue          (assigned cells / active)
  camel = 0xB89971FF, -- tan                  (buttons)
  cream = 0xF0E3C6FF, -- warm cream           (unassigned cells / fields)
}

-- ---------- dependency check ----------
if not reaper.ImGui_CreateContext then
  reaper.MB(
    "This script needs the ReaImGui extension.\n\n" ..
    "Install it via:\nExtensions > ReaPack > Browse packages > search 'ReaImGui' " ..
    "> install 'ReaImGui: ReaScript binding for Dear ImGui'.\n\n" ..
    "Then restart REAPER and run this script again.",
    "Missing dependency: ReaImGui", 0)
  return
end

local ctx  = reaper.ImGui_CreateContext('Region Render Matrix Manager')
local FONT = reaper.ImGui_CreateFont('sans-serif', 15)
reaper.ImGui_Attach(ctx, FONT)

-- ---------- state ----------
local regions = {}   -- { {enumidx, num, name, character}, ... }
local tracks  = {}   -- { {track, name}, ... }
local matrix  = {}   -- matrix[enumidx][tostring(track)] = true
local filter_text = ""
local range_text = ""
local selected_track_idx = 0
local group_by_character = true
local range_mode = 0   -- 0 = matrix row order (1..N), 1 = REAPER region number
local sort_by_name = false

-- parse "1-30", "20-200", or "1-5,12,30-40" into a lookup set of region numbers
local function parse_range(str)
  str = str:gsub("%s+", "")
  if str == "" then return nil end
  local set = {}
  for part in str:gmatch("[^,]+") do
    local a, b = part:match("^(%d+)%-(%d+)$")
    if a then
      a, b = tonumber(a), tonumber(b)
      if a > b then a, b = b, a end
      for n = a, b do set[n] = true end
    else
      local n = tonumber(part)
      if n then set[n] = true end
    end
  end
  return set
end

local function split_character(name)
  return name:match("^([%w]+)[_%- ]") or name
end

local function refresh_data()
  regions, tracks, matrix = {}, {}, {}

  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local total = num_markers + num_regions
  for i = 0, total - 1 do
    local ok, isrgn, pos, _, name, num = reaper.EnumProjectMarkers3(0, i)
    if ok and isrgn then
      if name == "" then name = "Region " .. num end
      table.insert(regions, { enumidx = i, num = num, pos = pos, name = name, character = split_character(name) })
    end
  end

  -- timeline order = the order REAPER's own render matrix lists regions in.
  -- 'ord' is that 1-based row position; 'num' is REAPER's display number,
  -- which can differ (shared marker/region numbering, deletions, renumbering).
  table.sort(regions, function(a, b)
    if a.pos == b.pos then return a.enumidx < b.enumidx end
    return a.pos < b.pos
  end)
  for i, r in ipairs(regions) do r.ord = i end

  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    local _, tname = reaper.GetTrackName(tr)
    table.insert(tracks, { track = tr, name = tname })
  end

  for _, r in ipairs(regions) do
    matrix[r.enumidx] = {}
    local ti = 0
    while true do
      local tr = reaper.EnumRegionRenderMatrix(0, r.enumidx, ti)
      if not tr then break end
      matrix[r.enumidx][tostring(tr)] = true
      ti = ti + 1
    end
  end
end
refresh_data()

local function is_assigned(r, t)
  local m = matrix[r.enumidx]
  return m ~= nil and m[tostring(t.track)] == true
end

local function set_assigned(r, t, state)
  reaper.SetRegionRenderMatrix(0, r.enumidx, t.track, state and 1 or -1)
  matrix[r.enumidx] = matrix[r.enumidx] or {}
  matrix[r.enumidx][tostring(t.track)] = state or nil
end

local function toggle(r, t) set_assigned(r, t, not is_assigned(r, t)) end

local char_colors = {}
local accent_cycle = { PAL.denim, PAL.camel, PAL.sky, 0x8FA6C9FF, 0xC9AE86FF }
local function color_for_character(char)
  if not char_colors[char] then
    local n = 0
    for _ in pairs(char_colors) do n = n + 1 end
    char_colors[char] = accent_cycle[(n % #accent_cycle) + 1]
  end
  return char_colors[char]
end

-- returns regions passing both the name filter and the number-range filter
local function regions_matching_filters()
  local range_set = parse_range(range_text)
  local out = {}
  for _, r in ipairs(regions) do
    local name_ok = filter_text == '' or r.name:lower():find(filter_text:lower(), 1, true)
    local key = (range_mode == 0) and r.ord or r.num
    local range_ok = range_set == nil or range_set[key]
    if name_ok and range_ok then table.insert(out, r) end
  end
  if sort_by_name then
    table.sort(out, function(a, b) return a.name < b.name end)
  end
  return out
end

-- ---------- bulk actions ----------
local function bulk_set_for_track(state)
  local t = tracks[selected_track_idx + 1]
  if not t then return end
  reaper.Undo_BeginBlock()
  for _, r in ipairs(regions_matching_filters()) do
    set_assigned(r, t, state)
  end
  reaper.Undo_EndBlock(state and "Assign selected regions to track" or "Unassign selected regions from track", -1)
end

local function assign_by_name_match()
  reaper.Undo_BeginBlock()
  for _, r in ipairs(regions) do
    local lname = r.name:lower()
    for _, t in ipairs(tracks) do
      if t.name ~= "" and lname:find(t.name:lower(), 1, true) then
        set_assigned(r, t, true)
      end
    end
  end
  reaper.Undo_EndBlock("Auto-assign region render matrix by name match", -1)
end

local function clear_all()
  reaper.Undo_BeginBlock()
  for _, r in ipairs(regions) do
    for _, t in ipairs(tracks) do
      if is_assigned(r, t) then set_assigned(r, t, false) end
    end
  end
  reaper.Undo_EndBlock("Clear region render matrix", -1)
end

local function toggle_column(t)
  reaper.Undo_BeginBlock()
  local all_on = true
  for _, r in ipairs(regions) do
    if not is_assigned(r, t) then all_on = false break end
  end
  for _, r in ipairs(regions) do set_assigned(r, t, not all_on) end
  reaper.Undo_EndBlock("Toggle render matrix column", -1)
end

local function toggle_row(r)
  reaper.Undo_BeginBlock()
  local all_on = true
  for _, t in ipairs(tracks) do
    if not is_assigned(r, t) then all_on = false break end
  end
  for _, t in ipairs(tracks) do set_assigned(r, t, not all_on) end
  reaper.Undo_EndBlock("Toggle render matrix row", -1)
end

-- ---------- UI ----------
local function apply_theme()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), PAL.fog)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), PAL.denim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(), PAL.sky)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), PAL.camel)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.denim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), PAL.denim)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), PAL.cream)
  return 7
end

local open = true
local function loop()
  reaper.ImGui_PushFont(ctx, FONT, 15)
  local n_colors = apply_theme()
  reaper.ImGui_SetNextWindowSize(ctx, 780, 560, reaper.ImGui_Cond_FirstUseEver())
  local visible
  visible, open = reaper.ImGui_Begin(ctx, 'Region Render Matrix Manager', true)

  if visible then
    if reaper.ImGui_Button(ctx, 'Refresh') then refresh_data() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Auto-assign by name match') then assign_by_name_match() end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, 'Clear all') then clear_all() end
    reaper.ImGui_SameLine(ctx)
    _, group_by_character = reaper.ImGui_Checkbox(ctx, 'Colour rows by character', group_by_character)

    reaper.ImGui_SetNextItemWidth(ctx, 220)
    _, filter_text = reaper.ImGui_InputTextWithHint(ctx, 'Filter regions', 'type to filter by name...', filter_text)

    reaper.ImGui_SetNextItemWidth(ctx, 220)
    _, sort_by_name = reaper.ImGui_Checkbox(ctx, 'Sort rows by name (timeline order otherwise)', sort_by_name)

    reaper.ImGui_SetNextItemWidth(ctx, 220)
    _, range_text = reaper.ImGui_InputTextWithHint(ctx, 'Range', 'e.g. 1-30, 45, 60-75', range_text)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    _, range_mode = reaper.ImGui_Combo(ctx, 'counts by', range_mode,
      'Matrix row (1..N)\0REAPER region number\0')
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, '(' .. #regions_matching_filters() .. ' match)')
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        'Matrix row = position in the render matrix list, top to bottom (1, 2, 3...).\n' ..
        'REAPER region number = the number shown on the region in the timeline.\n' ..
        'These differ when markers and regions share numbering, or after\n' ..
        'regions have been deleted/renumbered. Both are shown on each row.')
    end

    if #tracks > 0 then
      local items = {}
      for _, t in ipairs(tracks) do table.insert(items, t.name ~= '' and t.name or '(unnamed)') end
      if selected_track_idx > #tracks - 1 then selected_track_idx = 0 end
      reaper.ImGui_SetNextItemWidth(ctx, 220)
      _, selected_track_idx = reaper.ImGui_Combo(ctx, 'Target track', selected_track_idx, table.concat(items, '\0') .. '\0')
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, 'Assign matches to track') then bulk_set_for_track(true) end
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, 'Unassign matches from track') then bulk_set_for_track(false) end
    end
    reaper.ImGui_Spacing(ctx)

    if #tracks == 0 then
      reaper.ImGui_Text(ctx, 'No tracks in project.')
    elseif #regions == 0 then
      reaper.ImGui_Text(ctx, 'No regions in project.')
    else
      local flags = reaper.ImGui_TableFlags_Borders() | reaper.ImGui_TableFlags_ScrollX() |
                    reaper.ImGui_TableFlags_ScrollY() | reaper.ImGui_TableFlags_RowBg() |
                    reaper.ImGui_TableFlags_Resizable() | reaper.ImGui_TableFlags_Reorderable() |
                    reaper.ImGui_TableFlags_Hideable()
      if reaper.ImGui_BeginTable(ctx, 'matrix', #tracks + 1, flags, 0, 420) then
        reaper.ImGui_TableSetupScrollFreeze(ctx, 1, 1)
        reaper.ImGui_TableSetupColumn(ctx, 'Region',
          reaper.ImGui_TableColumnFlags_WidthFixed() | reaper.ImGui_TableColumnFlags_NoHide(), 280)
        for ci, t in ipairs(tracks) do
          local label = (t.name ~= '' and t.name or '(unnamed)') .. '##hdr' .. ci
          reaper.ImGui_TableSetupColumn(ctx, label, reaper.ImGui_TableColumnFlags_WidthFixed(), 110)
        end
        reaper.ImGui_TableHeadersRow(ctx)

        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableSetColumnIndex(ctx, 0)
        reaper.ImGui_TextDisabled(ctx, 'Toggle track:')
        for ci, t in ipairs(tracks) do
          reaper.ImGui_TableSetColumnIndex(ctx, ci)
          if reaper.ImGui_SmallButton(ctx, '||##col' .. ci) then toggle_column(t) end
        end

        for _, r in ipairs(regions_matching_filters()) do
          reaper.ImGui_TableNextRow(ctx)
          reaper.ImGui_TableSetColumnIndex(ctx, 0)
          if group_by_character then
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color_for_character(r.character))
          end
          if reaper.ImGui_SmallButton(ctx, '>##row' .. r.enumidx) then toggle_row(r) end
          reaper.ImGui_SameLine(ctx)
          reaper.ImGui_Text(ctx, string.format('%d | R%d  %s', r.ord, r.num, r.name))
          if group_by_character then reaper.ImGui_PopStyleColor(ctx) end
          if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, string.format(
              'Matrix row: %d\nREAPER region number: R%d\nName: %s', r.ord, r.num, r.name))
          end

          for ci, t in ipairs(tracks) do
            reaper.ImGui_TableSetColumnIndex(ctx, ci)
            local on = is_assigned(r, t)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), on and PAL.denim or PAL.cream)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), PAL.sky)
            if reaper.ImGui_Button(ctx, (on and 'X' or '') .. '##cell' .. r.enumidx .. '_' .. ci, 24, 24) then
              toggle(r, t)
            end
            reaper.ImGui_PopStyleColor(ctx, 2)
          end
        end
        reaper.ImGui_EndTable(ctx)
      end
    end
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleColor(ctx, n_colors)
  reaper.ImGui_PopFont(ctx)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)