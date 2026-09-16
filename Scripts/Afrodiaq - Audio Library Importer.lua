@description Batch Import Audio Library Folder
@version 1.0
@author Xavier 'Afrodiaq' Oshinowo
@about
--   Batch-imports an audio library folder into the current project.
--   Lets you set the gap between files, choose Single Track or
--   Track Per Folder layout, and optionally drop folder markers
--   and/or regions around each imported batch.

if not reaper.ImGui_GetVersion then
  reaper.MB(
    "This script requires the ReaImGui extension.\n\n" ..
    "Install it via Extensions > ReaPack > Browse packages, " ..
    "search for \"ReaImGui\", then restart Reaper.",
    "Afrodiaq Audio Library Importer", 0)
  return
end

local ctx  = reaper.ImGui_CreateContext('Afrodiaq Audio Library Importer')
local FONT = reaper.ImGui_CreateFont('sans-serif', 15)
local FONT_TITLE = reaper.ImGui_CreateFont('sans-serif', 18)
reaper.ImGui_Attach(ctx, FONT)
reaper.ImGui_Attach(ctx, FONT_TITLE)

------------------------------------------------------------
-- Color palette (from the provided swatch), 0xRRGGBBAA
------------------------------------------------------------
local COL_LAVENDER  = 0xD7D9E3FF -- pale gray-lavender (background base)
local COL_LIGHTBLUE = 0xA3C6F5FF -- light periwinkle blue
local COL_MEDBLUE   = 0x6389B8FF -- medium slate blue (accent / active)
local COL_TAN       = 0xB8916BFF -- warm tan/camel (buttons)
local COL_CREAM     = 0xF0E4C9FF -- cream (window background)
local COL_TEXT      = 0x3A4A5CFF -- dark blue-gray text
local COL_TEXT_LIGHT= 0xFBF7ECFF -- near-white cream text (on dark buttons)

------------------------------------------------------------
-- Persistent settings
------------------------------------------------------------
local EXT_SECTION = "AfrodiaqAudioImporter"

local function get_ext(key, default)
  local val = reaper.GetExtState(EXT_SECTION, key)
  if val == "" or val == nil then return default end
  return val
end
local function set_ext(key, value)
  reaper.SetExtState(EXT_SECTION, key, tostring(value), true)
end

------------------------------------------------------------
-- Preset storage
--   preset_names   -> "|" separated list of preset names
--   preset_data_<name> -> "gap|layout|markers|regions|trimsilence|forcemono"
------------------------------------------------------------
local function get_preset_list()
  local raw = get_ext("preset_names", "")
  local list = {}
  for name in raw:gmatch("([^|]+)") do table.insert(list, name) end
  local has_default = false
  for _, n in ipairs(list) do if n == "Default" then has_default = true end end
  if not has_default then table.insert(list, 1, "Default") end
  return list
end

local function set_preset_list(list)
  set_ext("preset_names", table.concat(list, "|"))
end

local function save_preset_data(name, gap, layout, markers, regions, trim_silence, force_mono)
  set_ext("preset_data_" .. name, string.format("%.2f|%d|%d|%d|%d|%d",
    gap, layout, markers and 1 or 0, regions and 1 or 0, trim_silence and 1 or 0, force_mono and 1 or 0))
end

local function load_preset_data(name)
  local raw = get_ext("preset_data_" .. name, "")
  if raw == "" then return 3.0, 0, true, true, false, false end
  local fields = {}
  for part in (raw .. "|"):gmatch("([^|]*)|") do table.insert(fields, part) end
  local gap          = tonumber(fields[1]) or 3.0
  local layout        = tonumber(fields[2]) or 0
  local markers        = fields[3] == "1"
  local regions        = fields[4] == "1"
  local trim_silence   = fields[5] == "1" -- absent in presets saved before this feature -> defaults false
  local force_mono     = fields[6] == "1"
  return gap, layout, markers, regions, trim_silence, force_mono
end

local function delete_preset(name, list)
  local new_list = {}
  for _, n in ipairs(list) do
    if n ~= name then table.insert(new_list, n) end
  end
  set_preset_list(new_list)
  reaper.DeleteExtState(EXT_SECTION, "preset_data_" .. name, true)
  return new_list
end

local library_folder     = get_ext("library_folder", "")
local presets             = get_preset_list()
local preset              = get_ext("preset", "Default")
local new_preset_name     = ""
local gap_seconds, layout_mode, opt_folder_markers, opt_regions, opt_trim_silence, opt_force_mono = load_preset_data(preset)
local opt_remember_folder  = get_ext("opt_remember_folder", "1") == "1"
local silence_threshold_db = tonumber(get_ext("silence_threshold_db", "-48.0"))
local stereo_report        = {}   -- filenames found to be stereo/multichannel
local show_report_popup    = false

------------------------------------------------------------
-- File system helpers
------------------------------------------------------------
local AUDIO_EXTS = { wav=true, mp3=true, flac=true, aif=true, aiff=true, ogg=true, wv=true, w64=true }

local function is_audio_file(fn)
  if fn:sub(1, 2) == "._" then return false end
  local ext = fn:match("%.([%a%d]+)$")
  return ext ~= nil and AUDIO_EXTS[ext:lower()] == true
end

local function get_files_in_folder(folder)
  local files, i = {}, 0
  while true do
    local fn = reaper.EnumerateFiles(folder, i)
    if not fn then break end
    if is_audio_file(fn) then table.insert(files, folder .. "/" .. fn) end
    i = i + 1
  end
  table.sort(files)
  return files
end

local function get_subfolders(folder)
  local subs, i = {}, 0
  while true do
    local sf = reaper.EnumerateSubdirectories(folder, i)
    if not sf then break end
    table.insert(subs, folder .. "/" .. sf)
    i = i + 1
  end
  table.sort(subs)
  return subs
end

local function base_name(path)
  return path:match("([^/\\]+)$") or path
end

-- Path relative to the chosen library folder, e.g. "ADR/Player_01"
local function relative_path(folder)
  if folder == library_folder then return base_name(library_folder) end
  local prefix = library_folder:gsub("[/\\]+$", "")
  if folder:sub(1, #prefix) == prefix then
    return (folder:sub(#prefix + 2):gsub("\\", "/"))
  end
  return base_name(folder)
end

-- First path segment under the library root, e.g. "ADR" or "Wild"
local function top_level_category(folder)
  local rel = relative_path(folder)
  return rel:match("^([^/]+)") or rel
end

local function browse_folder()
  local ok, folder
  if reaper.JS_Dialog_BrowseForFolder then
    ok, folder = reaper.JS_Dialog_BrowseForFolder("Select Library Folder", library_folder)
  else
    -- Fallback when js_ReaScriptAPI isn't installed: pick any file inside the target folder
    local ok2, filepath = reaper.GetUserFileNameForRead(library_folder, "Pick any file INSIDE the target library folder", "")
    ok = ok2
    if ok2 then folder = filepath:match("(.+)[/\\][^/\\]+$") end
  end
  if ok and folder and folder ~= "" then
    library_folder = folder
  end
end

------------------------------------------------------------
-- Import logic
------------------------------------------------------------

-- Reads sample blocks from a take's audio accessor to find speech bounds.
-- Returns the first/last positions (in seconds) where audio exceeds the
-- threshold, or nil if the file is entirely below it (so we don't trim).
local function find_speech_bounds_from_take(take, pcm_source, threshold_db)
  local length = reaper.GetMediaSourceLength(pcm_source)
  local srate  = reaper.GetMediaSourceSampleRate(pcm_source)
  local nch    = reaper.GetMediaSourceNumChannels(pcm_source)
  if not srate or srate <= 0 or length <= 0 or nch <= 0 then return nil end

  local accessor = reaper.CreateTakeAudioAccessor(take)
  if not accessor then return nil end

  local threshold  = 10 ^ (threshold_db / 20)
  local block_size = 4096
  local buf = reaper.new_array(block_size * nch)

  local first_hit, last_hit = nil, nil
  local pos = 0.0

  while pos < length do
    buf.clear()
    local ok = reaper.GetAudioAccessorSamples(accessor, srate, nch, pos, block_size, buf)
    if ok ~= 1 then break end
    local tbl = buf.table(1, block_size * nch)
    for i = 1, block_size * nch do
      local v = tbl[i]
      if v and v < 0 then v = -v end
      if v and v > threshold then
        local sample_index = math.floor((i - 1) / nch)
        local t = pos + (sample_index / srate)
        if not first_hit then first_hit = t end
        last_hit = t
      end
    end
    pos = pos + (block_size / srate)
  end

  reaper.DestroyAudioAccessor(accessor)

  if not first_hit then return nil end
  return first_hit, last_hit
end

local function insert_audio_item(track, filepath, position)
  local pcm_source = reaper.PCM_Source_CreateFromFile(filepath)
  if not pcm_source then return 0 end

  -- Flag stereo/multichannel files (dialogue should normally be mono)
  local nch = reaper.GetMediaSourceNumChannels(pcm_source)
  if nch and nch > 1 then
    table.insert(stereo_report, string.format("%s  (%d ch)", base_name(filepath), nch))
  end

  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, pcm_source)
  local length = reaper.GetMediaSourceLength(pcm_source)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", base_name(filepath), true)

  -- Force mono playback on multichannel files (non-destructive: downmixes
  -- to a single channel via the take's channel mode, source file untouched)
  if opt_force_mono and nch and nch > 1 then
    -- 2 = mono (downmix of all channels)
    reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", 2)
  end

  -- Trim head/tail silence (non-destructive: adjusts item bounds + start offset)
  if opt_trim_silence then
    local pad = 0.05 -- 50ms of breathing room either side
    local first_hit, last_hit = find_speech_bounds_from_take(take, pcm_source, silence_threshold_db)
    if first_hit and last_hit and last_hit > first_hit then
      local new_start = math.max(0, first_hit - pad)
      local new_end   = math.min(length, last_hit + pad)
      local new_len   = new_end - new_start
      if new_len > 0.01 then
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_start)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_len)
        length = new_len
      end
    end
  end

  return length
end

local function do_import()
  if library_folder == "" then
    reaper.MB("Please choose a library folder first.", "Afrodiaq Audio Library Importer", 0)
    return
  end

  stereo_report = {}
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  if opt_remember_folder then set_ext("library_folder", library_folder) end

  if layout_mode == 0 then
    ------------------------------------------------------------
    -- Single Track: everything sequential on one new track
    ------------------------------------------------------------
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
      local track_idx = reaper.CountTracks(0)
      reaper.InsertTrackAtIndex(track_idx, true)
      track = reaper.GetTrack(0, track_idx)
      reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "Afrodiaq Import - " .. base_name(library_folder), true)
    end

    local pos = reaper.GetCursorPositionEx(0)
    local last_category = nil
    local CATEGORY_MARKER_COLOR = reaper.ColorToNative(99, 137, 184) | 0x1000000

    local function process_folder(folder)
      local files = get_files_in_folder(folder)
      if #files == 0 then return end

      local label = relative_path(folder)

      if folder ~= library_folder then
        local category = top_level_category(folder)
        if category ~= last_category then
          reaper.AddProjectMarker2(0, false, pos, 0, "=== " .. category .. " ===", -1, CATEGORY_MARKER_COLOR)
          last_category = category
        end
      end

      if opt_folder_markers then
        reaper.AddProjectMarker2(0, false, pos, 0, label, -1, 0)
      end
      for _, f in ipairs(files) do
        local item_start = pos
        local length = insert_audio_item(track, f, pos)
        pos = pos + length + gap_seconds
        if opt_regions then
          reaper.AddProjectMarker2(0, true, item_start, item_start + length, base_name(f), -1, 0)
        end
      end
    end

    local function recurse(folder)
      for _, sub in ipairs(get_subfolders(folder)) do
        process_folder(sub)
        recurse(sub)
      end
    end

    process_folder(library_folder)
    recurse(library_folder)

  else
    ------------------------------------------------------------
    -- Track Per Folder: one new track per folder that has files
    ------------------------------------------------------------
    local start_pos = reaper.GetCursorPositionEx(0)

    local function make_track_for_folder(folder)
      local files = get_files_in_folder(folder)
      if #files == 0 then return end

      local label = relative_path(folder)
      local track_idx = reaper.CountTracks(0)
      reaper.InsertTrackAtIndex(track_idx, true)
      local track = reaper.GetTrack(0, track_idx)
      reaper.GetSetMediaTrackInfo_String(track, "P_NAME", label, true)

      local pos = start_pos
      if opt_folder_markers then
        reaper.AddProjectMarker2(0, false, start_pos, 0, label, -1, 0)
      end
      for _, f in ipairs(files) do
        local item_start = pos
        local length = insert_audio_item(track, f, pos)
        pos = pos + length + gap_seconds
        if opt_regions then
          reaper.AddProjectMarker2(0, true, item_start, item_start + length, base_name(f), -1, 0)
        end
      end
    end

    local function recurse(folder)
      for _, sub in ipairs(get_subfolders(folder)) do
        make_track_for_folder(sub)
        recurse(sub)
      end
    end

    make_track_for_folder(library_folder)
    recurse(library_folder)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Afrodiaq: Import Audio Library", -1)

  -- Report any non-mono files found (dialogue should normally be mono)
  if #stereo_report > 0 then
    local lines = {}
    local max_list = 25
    for i, entry in ipairs(stereo_report) do
      if i > max_list then
        table.insert(lines, string.format("...and %d more", #stereo_report - max_list))
        break
      end
      table.insert(lines, "  - " .. entry)
    end
    local action = opt_force_mono
      and "These were set to mono playback (Force Mono is on; source files untouched)."
      or  "Force Mono is off, so these were imported as-is."
    reaper.MB(
      string.format("%d non-mono file(s) found:\n\n%s\n\n%s",
        #stereo_report, table.concat(lines, "\n"), action),
      "Afrodiaq Importer - Channel Check", 0)
  end
end

------------------------------------------------------------
-- Theme
------------------------------------------------------------
local function push_theme()
  local pairs_pushed = {
    { reaper.ImGui_Col_WindowBg(),        COL_CREAM },
    { reaper.ImGui_Col_PopupBg(),         COL_CREAM },
    { reaper.ImGui_Col_TitleBg(),         COL_MEDBLUE },
    { reaper.ImGui_Col_TitleBgActive(),   COL_MEDBLUE },
    { reaper.ImGui_Col_Text(),            COL_TEXT },
    { reaper.ImGui_Col_Border(),          COL_MEDBLUE },
    { reaper.ImGui_Col_FrameBg(),         COL_LAVENDER },
    { reaper.ImGui_Col_FrameBgHovered(),  COL_LIGHTBLUE },
    { reaper.ImGui_Col_FrameBgActive(),   COL_LIGHTBLUE },
    { reaper.ImGui_Col_Button(),          COL_TAN },
    { reaper.ImGui_Col_ButtonHovered(),   COL_MEDBLUE },
    { reaper.ImGui_Col_ButtonActive(),    COL_MEDBLUE },
    { reaper.ImGui_Col_CheckMark(),       COL_MEDBLUE },
    { reaper.ImGui_Col_SliderGrab(),      COL_MEDBLUE },
    { reaper.ImGui_Col_SliderGrabActive(),COL_TAN },
    { reaper.ImGui_Col_Header(),          COL_LIGHTBLUE },
    { reaper.ImGui_Col_HeaderHovered(),   COL_MEDBLUE },
    { reaper.ImGui_Col_HeaderActive(),    COL_MEDBLUE },
  }
  for _, p in ipairs(pairs_pushed) do
    reaper.ImGui_PushStyleColor(ctx, p[1], p[2])
  end
  return #pairs_pushed
end

------------------------------------------------------------
-- Main loop
------------------------------------------------------------
local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoCollapse()

local function loop()
  reaper.ImGui_SetNextWindowSize(ctx, 460, 680, reaper.ImGui_Cond_FirstUseEver())
  local n_colors = push_theme()
  reaper.ImGui_PushFont(ctx, FONT, 15)

  local visible, open = reaper.ImGui_Begin(ctx, 'Afrodiaq Audio Library Importer', true, WINDOW_FLAGS)
  if visible then
    -- Title
    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_PushFont(ctx, FONT_TITLE, 18)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_MEDBLUE)
    local title = "AFRODIAQ AUDIO LIBRARY IMPORTER"
    local win_w = reaper.ImGui_GetWindowWidth(ctx)
    local text_w = reaper.ImGui_CalcTextSize(ctx, title)
    reaper.ImGui_SetCursorPosX(ctx, math.max(0, (win_w - text_w) * 0.5))
    reaper.ImGui_Text(ctx, title)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopFont(ctx)
    reaper.ImGui_Dummy(ctx, 0, 12)

    -- Library folder
    reaper.ImGui_Text(ctx, "Library Folder")
    reaper.ImGui_SetNextItemWidth(ctx, -60)
    local changed, new_folder = reaper.ImGui_InputText(ctx, "##library_folder", library_folder)
    if changed then library_folder = new_folder end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Browse", 52, 0) then browse_folder() end

    reaper.ImGui_Dummy(ctx, 0, 10)

    -- Preset
    reaper.ImGui_Text(ctx, "Preset")
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    if reaper.ImGui_BeginCombo(ctx, "##preset", preset) then
      for _, p in ipairs(presets) do
        if reaper.ImGui_Selectable(ctx, p, p == preset) then
          preset = p
          gap_seconds, layout_mode, opt_folder_markers, opt_regions, opt_trim_silence, opt_force_mono = load_preset_data(preset)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    -- Save / delete preset
    local save_w, del_w, spacing = 84, 60, 8
    local row_avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local reserved = save_w + spacing + (preset ~= "Default" and (del_w + spacing) or 0)
    reaper.ImGui_SetNextItemWidth(ctx, row_avail - reserved)
    local nchanged, nval = reaper.ImGui_InputTextWithHint(ctx, "##new_preset_name", "New preset name...", new_preset_name)
    if nchanged then new_preset_name = nval end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Save Preset", save_w, 0) then
      local name = new_preset_name:gsub("^%s+", ""):gsub("%s+$", "")
      if name ~= "" then
        save_preset_data(name, gap_seconds, layout_mode, opt_folder_markers, opt_regions, opt_trim_silence, opt_force_mono)
        local exists = false
        for _, p in ipairs(presets) do if p == name then exists = true end end
        if not exists then
          table.insert(presets, name)
          set_preset_list(presets)
        end
        preset = name
        new_preset_name = ""
      end
    end
    if preset ~= "Default" then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Delete", del_w, 0) then
        presets = delete_preset(preset, presets)
        preset = "Default"
        gap_seconds, layout_mode, opt_folder_markers, opt_regions, opt_trim_silence, opt_force_mono = load_preset_data(preset)
      end
    end

    reaper.ImGui_Dummy(ctx, 0, 10)

    -- Gap between files
    reaper.ImGui_Text(ctx, "Gap Between Files")
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local gchanged, gval = reaper.ImGui_SliderDouble(ctx, "##gap", gap_seconds, 0.0, 30.0, "%.1f sec")
    if gchanged then gap_seconds = gval end

    reaper.ImGui_Dummy(ctx, 0, 10)

    -- Import layout
    reaper.ImGui_Text(ctx, "Import Layout")
    if reaper.ImGui_RadioButton(ctx, "Single Track", layout_mode == 0) then layout_mode = 0 end
    if reaper.ImGui_RadioButton(ctx, "Track Per Folder", layout_mode == 1) then layout_mode = 1 end

    reaper.ImGui_Dummy(ctx, 0, 10)

    -- Checkboxes
    local c1, c2, c3, c4, c5
    c1, opt_folder_markers  = reaper.ImGui_Checkbox(ctx, "Folder Markers", opt_folder_markers)
    c2, opt_regions         = reaper.ImGui_Checkbox(ctx, "Regions", opt_regions)
    c3, opt_remember_folder = reaper.ImGui_Checkbox(ctx, "Remember Last Folder", opt_remember_folder)

    reaper.ImGui_Dummy(ctx, 0, 8)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 6)

    -- Dialogue-specific options
    reaper.ImGui_Text(ctx, "Dialogue Options")

    c4, opt_force_mono = reaper.ImGui_Checkbox(ctx, "Force Mono (flags + downmixes stereo)", opt_force_mono)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        "Non-mono files are always reported after import.\n" ..
        "When this is on, they're also set to mono playback via take\n" ..
        "channel mode. Source files on disk are never modified.")
    end

    c5, opt_trim_silence = reaper.ImGui_Checkbox(ctx, "Trim Head/Tail Silence", opt_trim_silence)
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx,
        "Trims dead air before/after speech, leaving 50ms padding.\n" ..
        "Non-destructive (adjusts item bounds only).\n" ..
        "Leave OFF for studios that require zero cropping.")
    end

    if opt_trim_silence then
      reaper.ImGui_Indent(ctx, 20)
      reaper.ImGui_Text(ctx, "Silence Threshold")
      reaper.ImGui_SetNextItemWidth(ctx, -1)
      local tchanged, tval = reaper.ImGui_SliderDouble(ctx, "##silence_threshold", silence_threshold_db, -80.0, -20.0, "%.1f dB")
      if tchanged then silence_threshold_db = tval end
      reaper.ImGui_Unindent(ctx, 20)
    end

    reaper.ImGui_Dummy(ctx, 0, 18)

    -- Import button
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_TEXT_LIGHT)
    if reaper.ImGui_Button(ctx, "IMPORT", avail_w, 42) then
      do_import()
    end
    reaper.ImGui_PopStyleColor(ctx)

    -- Persist settings (cheap; ExtState writes are lightweight)
    set_ext("preset", preset)
    set_ext("silence_threshold_db", silence_threshold_db)
    set_ext("opt_remember_folder", opt_remember_folder and "1" or "0")

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopFont(ctx)
  reaper.ImGui_PopStyleColor(ctx, n_colors)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)