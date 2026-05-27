script "com.hyperxtalk.library.macscrollenhancement2"

on extensionInitialize
   if the target is not me then pass extensionInitialize
   insert the script of me into back
   if the platform is "MacOS" then
      send "seScrollEnhancementEnable" to me in 0 milliseconds
   end if
   if the environment contains "development" then
      set the _ideoverride of me to true
   end if
end extensionInitialize

on extensionFinalize
   if the target is not me then pass extensionFinalize
   remove the script of me from back
   seScrollEnhancementDisable
end extensionFinalize


/**

Title: Mac Scroll Enhancement

Author: HyperXTalk

Type: library

Version: 1.0.0

Description:
  Generic smooth-scroll library for HyperXTalk.

  Intercepts precise trackpad scroll events application-wide via a C
  NSEvent monitor and applies accumulated pixel deltas to whichever
  scrollable LiveCode control is currently under the mouse ‚Äî fields,
  groups with scrollbars, etc.

  Call seScrollEnhancementEnable from any openStack handler that should
  benefit from smooth scrolling. Call seScrollEnhancementDisable from the
  matching closeStack. Reference-counted ‚Äî the poll keeps running until
  every caller has disabled it.
*/

-- ---------------------------------------------------------------------------
-- Script-local state
-- ---------------------------------------------------------------------------

local sRefCount         -- number of active callers; poll runs while > 0
local sMonitorInstalled -- true when the C NSEvent monitor is active

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

/**
seScrollEnhancementEnable pWindowId
Start smooth scrolling. Call from openStack (or equivalent).
pWindowId is accepted for backward compatibility; no longer used internally.
Safe to call from multiple windows ‚Äî reference-counted.
*/
command seScrollEnhancementEnable
   if the platform is not "MacOS" then exit seScrollEnhancementEnable
   add 1 to sRefCount
   if sRefCount > 1 then exit seScrollEnhancementEnable
   macScrollEnhancementRemove
   macScrollEnhancementInstall 0   -- pre-install so monitor is ready before mouseControl updates
   put true into sMonitorInstalled
   send "seScrollPoll" to me in 16 milliseconds
end seScrollEnhancementEnable

/**
seScrollEnhancementDisable
Stop smooth scrolling. Call from closeStack (or equivalent).
Reference-counted ‚Äî poll stops only when every caller has disabled.
*/
command seScrollEnhancementDisable
   if the platform is not "MacOS" then exit seScrollEnhancementDisable
   subtract 1 from sRefCount
   if sRefCount > 0 then exit seScrollEnhancementDisable  -- others still active
   if sMonitorInstalled then macScrollEnhancementRemove
   put false into sMonitorInstalled
   put 0 into sRefCount   -- clamp in case of unbalanced calls
end seScrollEnhancementDisable

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- LiveCode cannot evaluate a long-id stored in a variable as an object
-- reference directly (e.g. `if tControl is a field` doesn't work). These
-- helpers use `do` to evaluate the property at runtime.

function seObjectKind pObject, pMouseStack
   -- Returns "field", "group", "button", "card", "stack", or empty.
   if pObject is empty then return empty
   local tScript, tResult
   put "put the name of " & pObject & " of stack " & QUOTE & pMouseStack & QUOTE & " into tResult" into tScript
   --   do tScript
   try
      do tScript
   catch tErr
      return empty
   end try
   return word 1 of tResult
end seObjectKind

function seObjectShortName pObject, pMouseStack
   if pObject is empty then return empty
   local tScript, tResult
   --   put "put the short name of " & pObject & " into tResult" into tScript
   put "put the short name of " & pObject & " of stack " & QUOTE & pMouseStack & QUOTE & " into tResult" into tScript
   --   do tScript
   try
      do tScript
   catch tErr
      return empty
   end try
   return tResult
end seObjectShortName

function seObjectOwner pObject, pMouseStack
   if pObject is empty then return empty
   local tScript, tResult
   --   put "put the owner of " & pObject & " into tResult" into tScript
   put "put the owner of " & pObject & " of stack " & QUOTE & pMouseStack & QUOTE & " into tResult" into tScript
   --   do tScript
   try
      do tScript
   catch tErr
      return empty
   end try
   return tResult
end seObjectOwner

function seObjectProp pObject, pMouseStack, pProp
   if pObject is empty then return empty
   local tScript, tResult
   --   put "put the " & pProp & " of " & pObject & " into tResult" into tScript
   put "put the " & pProp & " of " & pObject & " of stack " & QUOTE & pMouseStack & QUOTE & " into tResult" into tScript
   --   do tScript
   try
      do tScript
   catch tErr
      return empty
   end try
   return tResult
end seObjectProp

command seSetObjectProp pObject, pMouseStack, pProp, pValue
   if pObject is empty then exit seSetObjectProp
   local tScript
   put "set the " & pProp & " of " & pObject & " of stack " & QUOTE & pMouseStack & QUOTE & " to " & pValue into tScript
   do tScript
end seSetObjectProp

/**
seGetScrollTarget
Returns the long id of the best scrollable control under the mouse,
or empty if there is none. Walks up the owner chain from mouseControl
to find the first eligible control:
- A field (always potentially scrollable) ‚Äî except fields inside a
group named "Gutter" (line-number display in the script editor).
- A group that has vScrollbar or hScrollbar set to true.
*/
function seGetScrollTarget
   local tControl
   put the mouseControl into tControl
   
   -- Fallback when mouseControl hasn't updated yet (e.g. right after window opens)
   if tControl is empty and the mouseStack is not empty then
      local tN, tScript
      put "put the number of controls of stack " & QUOTE & the mouseStack & QUOTE & " into tN" into tScript
      do tScript
      local tMouseLoc
      put the mouseLoc into tMouseLoc
      repeat with i = tN down to 1
         local tCandidate, tRect
         put "control " & i & " of stack " & QUOTE & the mouseStack & QUOTE into tCandidate
         put "put the rect of " & tCandidate & " into tRect" into tScript
         do tScript
         if tMouseLoc is within tRect then
            put tCandidate into tControl
            exit repeat
         end if
      end repeat
   end if
   
   if tControl is empty then return empty
   repeat
      local tKind
      put seObjectKind(tControl, the mouseStack) into tKind
      
      if tKind is "field" then
         -- Skip fields inside the line-number gutter.
         local tParent
         put seObjectOwner(tControl, the mouseStack) into tParent
         if seObjectKind(tParent, the mousestack) is "group" and seObjectShortName(tParent, the mouseStack) is "Gutter" then
            put tParent into tControl   -- continue walking up from the gutter group
         else
            return tControl
         end if
         
      else if tKind is "group" then
         if seObjectProp(tControl, the mouseStack, "vScrollbar") then return tControl
         if seObjectProp(tControl, the mouseStack, "hScrollbar") then return tControl
         -- Not a scrolling group ‚Äî walk up.
         put seObjectOwner(tControl, the mouseStack) into tControl
         
      else
         -- card, stack, or unrecognised ‚Äî stop.
         return empty
      end if
      
      if tControl is empty then return empty
   end repeat
end seGetScrollTarget

/**
seSyncGutter pScrolledControl, pNewV
If the scrolled control is the Script field of a script editor, syncs
the line-number gutter to the same vertical scroll position.
*/
command seSyncGutter pScrolledControl, pNewV
   if seObjectShortName(pScrolledControl, the mouseStack) is not "Script" then exit seSyncGutter
   -- Owner chain: field ‚Üí card ‚Üí stack (the script editor).
   local tStackName
   put seObjectShortName(seObjectOwner(seObjectOwner(pScrolledControl, the mouseStack), the mouseStack), the mouseStack) into tStackName
   if tStackName is empty then exit seSyncGutter
   if there is not a group "Gutter" of stack tStackName then exit seSyncGutter
   local tOldDefault
   put the defaultStack into tOldDefault
   set the defaultStack to tStackName
   set the vScroll of field "Numbers" of group "Gutter" to pNewV
   set the defaultStack to tOldDefault
end seSyncGutter

-- ---------------------------------------------------------------------------
-- Internal: momentum poll loop
-- ---------------------------------------------------------------------------

on seScrollPoll
   -- Stop naturally when all callers have disabled.
   if sRefCount < 1 then exit seScrollPoll
   
   -- Find whatever scrollable control is under the mouse right now.
   local tScrollTarget
   put seGetScrollTarget() into tScrollTarget
   
   -- Install or remove the C monitor based on whether there is a target.
   -- Keeping the monitor installed when there is a target also blocks
   -- LiveCode's own coarse line-quantised scroll from reaching the control.
   if tScrollTarget is not empty then
      if not sMonitorInstalled then
         macScrollEnhancementInstall the windowId of stack (the mouseStack)
         put true into sMonitorInstalled
      end if
   else
      if sMonitorInstalled then
         macScrollEnhancementRemove
         put false into sMonitorInstalled
      end if
   end if
   
   -- Always drain both accumulators every tick so stale delta never carries
   -- over to a new scroll target.
   local tDeltaY, tDeltaX
   put macScrollEnhancementGetDelta() into tDeltaY
   put macScrollEnhancementGetDeltaX() into tDeltaX
   
   if tScrollTarget is not empty then
      -- Suppress scrolling while the script editor handler list popup is
      -- visible. The popup is drawn inside the same NSWindow as the field
      -- so the OS-level window check in the C layer cannot detect it; we
      -- handle it here instead.
      local tHandlerListObj
      --      put seHandlerListObject() into tHandlerListObj
      try
         put seHandlerListObject() into tHandlerListObj
      catch tErr
         put empty into tHandlerListObj
      end try
      if tHandlerListObj is not empty and the visible of tHandlerListObj then
         send "seScrollPoll" to me in 16 milliseconds
         exit seScrollPoll
      end if
      
      -- Apply vertical scroll.
      if abs(tDeltaY) > 0.5 then
         local tCurrentV, tMaxV, tNewV
         --         put the vScroll of tScrollTarget into tCurrentV
         put seObjectProp(tScrollTarget, the mouseStack, "vScroll") into tCurrentV
         --         put the formattedHeight of tScrollTarget - the height of tScrollTarget into tMaxV
         put seObjectProp(tScrollTarget, the mouseStack, "formattedHeight") - seObjectProp(tScrollTarget, the mouseStack, "height") into tMaxV
         if tMaxV < 0 then put 0 into tMaxV
         put tCurrentV + tDeltaY into tNewV
         if tNewV < 0 then put 0 into tNewV
         if tNewV > tMaxV then put tMaxV into tNewV
         --         set the vScroll of tScrollTarget to tNewV
         seSetObjectProp tScrollTarget, the mouseStack, vScroll, tNewV
         seSyncGutter tScrollTarget, tNewV
      end if
      
      -- Apply horizontal scroll.
      if abs(tDeltaX) > 0.5 then
         local tCurrentH, tMaxH, tNewH
         --         put the hScroll of tScrollTarget into tCurrentH
         put seObjectProp(tScrollTarget, the mouseStack, "hScroll") into tCurrentH
         --         put the formattedWidth of tScrollTarget - the width of tScrollTarget into tMaxH
         put seObjectProp(tScrollTarget, the mouseStack, "formattedWidth") - seObjectProp(tScrollTarget, the mouseStack, "width") into tMaxH
         if tMaxH < 0 then put 0 into tMaxH
         put tCurrentH + tDeltaX into tNewH
         if tNewH < 0 then put 0 into tNewH
         if tNewH > tMaxH then put tMaxH into tNewH
         --         set the hScroll of tScrollTarget to tNewH
         seSetObjectProp tScrollTarget, the mouseStack, hScroll, tNewH
      end if
   end if
   
   send "seScrollPoll" to me in 16 milliseconds
end seScrollPoll
