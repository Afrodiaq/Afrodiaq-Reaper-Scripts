@description Rename selected media item and create a region with the clipboard content
@version 1.0
@author Xavier
@about This script renames the selected media item and creates a region with the clipboard content.-- Requires SWS Extension for CF_GetClipboard()

local clipboard = reaper.CF_GetClipboard()

if clipboard == "" then
    reaper.ShowMessageBox("Clipboard is empty.", "Error", 0)
    return
end

local tsStart, tsEnd = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

if tsStart == tsEnd then
    reaper.ShowMessageBox("No time selection found.", "Error", 0)
    return
end

local item = reaper.GetSelectedMediaItem(0, 0)

if not item then
    reaper.ShowMessageBox("Select an item first.", "Error", 0)
    return
end

reaper.Undo_BeginBlock()

-- Split at end first
reaper.SplitMediaItem(item, tsEnd)

-- Split at start
local middlePiece = reaper.SplitMediaItem(item, tsStart)

if middlePiece then

    -- Select only the extracted piece
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(middlePiece, true)

    -- Create region
    reaper.AddProjectMarker2(
        0,
        true,
        tsStart,
        tsEnd,
        clipboard,
        -1,
        0
    )

    -- Rename active take
    local take = reaper.GetActiveTake(middlePiece)

    if take then
        reaper.GetSetMediaItemTakeInfo_String(
            take,
            "P_NAME",
            clipboard,
            true
        )
    end

    -- Ensure only the processed item is selected
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(middlePiece, true)

    -- Apply Track/Take FX as New Take (Mono Output)
    reaper.Main_OnCommand(41999, 0)

    -- Apply fades AFTER render
    local itemLength = reaper.GetMediaItemInfo_Value(middlePiece, "D_LENGTH")
    local fadeLength = math.min(0.1, itemLength / 2)

    reaper.SetMediaItemInfo_Value(
        middlePiece,
        "D_FADEINLEN",
        fadeLength
    )

    reaper.SetMediaItemInfo_Value(
        middlePiece,
        "D_FADEOUTLEN",
        fadeLength
    )

end

reaper.UpdateArrange()

reaper.Undo_EndBlock(
    "Extract Selection, Create Region, Render Mono Take, Add Fades",
    -1
)
