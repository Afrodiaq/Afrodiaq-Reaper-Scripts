@description Trim left edge of item under mouse cursor 
@version 1.0
@author Xavier 'Afrodiaq' Oshinowo
@about 
-- This script allows you to move the region to your edit cursor after trimming an item on the left edge.
-- Moves edit cursor position and move region start if necessary



---------------------------------------------------
-- SETTINGS
---------------------------------------------------

local REGION_TOLERANCE = 0.01 -- seconds
local LEFT_TRIM_ACTION = reaper.NamedCommandLookup("_SWS_AWTRIMLEFT")

---------------------------------------------------
-- GET ITEM UNDER MOUSE
---------------------------------------------------

local item = reaper.BR_ItemAtMouseCursor()

if not item then
    return
end

---------------------------------------------------
-- STORE ORIGINAL ITEM START
---------------------------------------------------

local oldStart =
    reaper.GetMediaItemInfo_Value(item, "D_POSITION")

---------------------------------------------------
-- BEGIN UNDO
---------------------------------------------------

reaper.Undo_BeginBlock()

---------------------------------------------------
-- RUN NATIVE/SWS TRIM ACTION
---------------------------------------------------

reaper.Main_OnCommand(LEFT_TRIM_ACTION, 0)

---------------------------------------------------
-- GET NEW ITEM START
---------------------------------------------------

local newStart =
    reaper.GetMediaItemInfo_Value(item, "D_POSITION")

local delta = newStart - oldStart

---------------------------------------------------
-- ONLY CONTINUE IF ITEM ACTUALLY MOVED
---------------------------------------------------

if math.abs(delta) > 0.0000001 then

    local _, numMarkers, numRegions =
        reaper.CountProjectMarkers(0)

    ---------------------------------------------------
    -- FIND REGION ATTACHED TO OLD ITEM START
    ---------------------------------------------------

    for i = 0, numMarkers + numRegions - 1 do

        local _, isRegion, regionStart, regionEnd,
              regionName, regionID =
            reaper.EnumProjectMarkers(i)

        if isRegion then

            ---------------------------------------------------
            -- CHECK REGION START AGAINST ITEM START
            ---------------------------------------------------

            if math.abs(regionStart - oldStart)
                <= REGION_TOLERANCE then

                ---------------------------------------------------
                -- MOVE REGION START
                ---------------------------------------------------

                reaper.SetProjectMarker(
                    regionID,
                    true,
                    regionStart + delta,
                    regionEnd,
                    regionName
                )

                break
            end
        end
    end
end

---------------------------------------------------
-- UPDATE
---------------------------------------------------

reaper.UpdateArrange()

reaper.Undo_EndBlock(
    "Trim left edge + move region start",
    -1
)