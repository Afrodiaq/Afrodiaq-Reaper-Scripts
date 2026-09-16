@description Trim right edge of item under mouse cursor to edit cursor position and move region end if necessary
@version 1.0
@author Afrodiaq
@about This script allows you to move the region to your edit cursor after trimming an item on the right edge.

---------------------------------------------------
-- SETTINGS
---------------------------------------------------

local REGION_TOLERANCE = 0.01 -- seconds
local RIGHT_TRIM_ACTION = reaper.NamedCommandLookup("_SWS_AWTRIMRIGHT")

---------------------------------------------------
-- GET ITEM UNDER MOUSE
---------------------------------------------------

local item = reaper.BR_ItemAtMouseCursor()

if not item then
    return
end

---------------------------------------------------
-- STORE ORIGINAL ITEM EDGES
---------------------------------------------------

local oldStart =
    reaper.GetMediaItemInfo_Value(item, "D_POSITION")

local oldLength =
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

local oldEnd = oldStart + oldLength

---------------------------------------------------
-- BEGIN UNDO
---------------------------------------------------

reaper.Undo_BeginBlock()

---------------------------------------------------
-- RUN NATIVE/SWS TRIM ACTION
---------------------------------------------------

reaper.Main_OnCommand(RIGHT_TRIM_ACTION, 0)

---------------------------------------------------
-- GET NEW ITEM END
---------------------------------------------------

local newStart =
    reaper.GetMediaItemInfo_Value(item, "D_POSITION")

local newLength =
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

local newEnd = newStart + newLength

---------------------------------------------------
-- CALCULATE MOVEMENT
---------------------------------------------------

local delta = newEnd - oldEnd

---------------------------------------------------
-- ONLY CONTINUE IF ITEM ACTUALLY MOVED
---------------------------------------------------

if math.abs(delta) > 0.0000001 then

    local _, numMarkers, numRegions =
        reaper.CountProjectMarkers(0)

    ---------------------------------------------------
    -- FIND REGION ATTACHED TO OLD ITEM END
    ---------------------------------------------------

    for i = 0, numMarkers + numRegions - 1 do

        local _, isRegion, regionStart, regionEnd,
              regionName, regionID =
            reaper.EnumProjectMarkers(i)

        if isRegion then

            ---------------------------------------------------
            -- CHECK REGION END AGAINST ITEM END
            ---------------------------------------------------

            if math.abs(regionEnd - oldEnd)
                <= REGION_TOLERANCE then

                ---------------------------------------------------
                -- MOVE REGION END
                ---------------------------------------------------

                reaper.SetProjectMarker(
                    regionID,
                    true,
                    regionStart,
                    regionEnd + delta,
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
    "Trim right edge + move region end",
    -1
)