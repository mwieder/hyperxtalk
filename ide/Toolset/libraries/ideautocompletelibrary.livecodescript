script "ideautocompletelibrary"

-- Word list cache: ruggedId -> return-separated sorted word list
local sWordListCache

-- Popup state
local sPopupShowing
local sCurrentEditorId

-- Pending debounce timer
local sUpdateTimer

constant kPopupName = "ideAutoCompletePopup"
constant kMinChars = 2
constant kMaxCompletions = 15
constant kPopupWidth = 220
constant kItemHeight = 18

--------------------------------------------------------------------------------
-- Library lifecycle
--------------------------------------------------------------------------------

on extensionInitialize
   if the target is me then
      insert the script of me into back
      put false into sPopupShowing
      ideAutocomplete_CreatePopup
   end if
end extensionInitialize

on extensionFinalize
   if the target is me then
      cancel sUpdateTimer
      if there is a stack kPopupName then
         delete stack kPopupName
      end if
      remove the script of me from back
   end if
end extensionFinalize

--------------------------------------------------------------------------------
-- Public entry points called by revsecommoneditorbehavior
--------------------------------------------------------------------------------

-- Called when the object being edited changes.
-- Builds and caches the word list for the object's message path.
command ideAutocompleteIntrospectMessagePath pObjectId
   ideAutocomplete_BuildWordList pObjectId
end ideAutocompleteIntrospectMessagePath

-- Called when an object's script editor tab is closed.
command ideAutocompleteClearObjectCache pObject
   delete variable sWordListCache[revRuggedId(pObject)]
end ideAutocompleteClearObjectCache

-- Called on every relevant keypress. Debounced to avoid firing on every char.
command ideAutocompleteUpdate pEditorId, pObjectId, pClasses
   cancel sUpdateTimer
   send "ideAutocomplete_DoUpdate" && quote & pEditorId & quote \
         && quote & pObjectId & quote to me in 150 milliseconds
   put the result into sUpdateTimer
end ideAutocompleteUpdate

-- Called on mouseMove, closeField, exitField, escapeKey, returnInField.
command ideAutocompleteCancelFind pEditorId
   cancel sUpdateTimer
   ideAutocomplete_HidePopup
end ideAutocompleteCancelFind

-- Called when Tab is pressed. Accepts the selected completion if popup is
-- showing. Returns false to suppress normal tab handling, true to pass it on.
command ideAutocompleteHandleTab pEditorId, pObjectId, @pPlaceholders, @pEditPlaceholder, @pEditChunks
   if not sPopupShowing then
      return true
   end if
   ideAutocomplete_AcceptCompletion pEditorId
   return false
end ideAutocompleteHandleTab

-- Called when an arrow key is pressed. Navigates the popup list if showing.
-- Returns false to consume the key, true to pass it on.
command ideAutocompleteHandleArrow pEditorId, pKeyName, pObjectId, @pPlaceholders, @pEditPlaceholder, @pEditChunks
   if not sPopupShowing then
      return true
   end if
   if pKeyName is "up" then
      ideAutocomplete_Navigate -1
   else if pKeyName is "down" then
      ideAutocomplete_Navigate 1
   end if
   return false
end ideAutocompleteHandleArrow

-- Called when the Help key is pressed. Opens the dictionary for the selected
-- completion if the popup is showing. Returns true if handled.
command ideAutocompleteHandleHelp pEditorId, pObjectId
   if not sPopupShowing then
      return false
   end if
   local tWord
   put ideAutocomplete_SelectedWord() into tWord
   if tWord is not empty then
      dispatch "revIDEOpenDictionary" with tWord
   end if
   return true
end ideAutocompleteHandleHelp

-- Replaces revEnvironmentEditionProperty("autocomplete") gate.
function ideAutocompleteIsEnabled
   return true
end ideAutocompleteIsEnabled

--------------------------------------------------------------------------------
-- Private: word list
--------------------------------------------------------------------------------

private command ideAutocomplete_BuildWordList pObjectId
   local tRuggedId
   put revRuggedId(pObjectId) into tRuggedId

   -- Already cached for this object
   if sWordListCache[tRuggedId] is not empty then
      exit ideAutocomplete_BuildWordList
   end if

   local tWords

   -- Built-in commands, functions and properties
   put commandNames() into tWords
   put return & functionNames() after tWords
   put return & propertyNames() after tWords

   -- Handler names from the object's full message path
   if there is a pObjectId then
      local tHandlers
      put the effective revAvailableHandlers of pObjectId into tHandlers
      local tLine
      repeat for each line tLine in tHandlers
         local tName
         put word 2 of tLine into tName
         if tName is not empty then
            put return & tName after tWords
         end if
      end repeat
   end if

   -- Sort and deduplicate
   sort lines of tWords ascending text
   put ideAutocomplete_Deduplicate(tWords) into tWords

   put tWords into sWordListCache[tRuggedId]
end ideAutocomplete_BuildWordList

private function ideAutocomplete_Deduplicate pList
   local tResult, tPrev
   repeat for each line tLine in pList
      if tLine is not empty and tLine is not tPrev then
         put tLine & return after tResult
         put tLine into tPrev
      end if
   end repeat
   -- Remove trailing return
   if tResult ends with return then
      delete the last char of tResult
   end if
   return tResult
end ideAutocomplete_Deduplicate

--------------------------------------------------------------------------------
-- Private: debounced update
--------------------------------------------------------------------------------

private command ideAutocomplete_DoUpdate pEditorId, pObjectId
   -- Get the partial word at the cursor
   dispatch "getCaretToken" to pEditorId
   local tToken
   put the result into tToken

   if the number of chars of tToken < kMinChars then
      ideAutocomplete_HidePopup
      exit ideAutocomplete_DoUpdate
   end if

   -- Ensure the word list exists for this object
   ideAutocomplete_BuildWordList pObjectId

   local tRuggedId
   put revRuggedId(pObjectId) into tRuggedId

   -- Filter: only words that begin with the typed token (case-insensitive)
   local tMatches
   repeat for each line tLine in sWordListCache[tRuggedId]
      if tLine begins with tToken then
         put tLine & return after tMatches
         if the number of lines of tMatches > kMaxCompletions then
            exit repeat
         end if
      end if
   end repeat
   if tMatches ends with return then
      delete the last char of tMatches
   end if

   -- Nothing to show, or the only match is exactly the token already typed
   if tMatches is empty or tMatches is tToken then
      ideAutocomplete_HidePopup
      exit ideAutocomplete_DoUpdate
   end if

   ideAutocomplete_ShowPopup pEditorId, tMatches
end ideAutocomplete_DoUpdate

--------------------------------------------------------------------------------
-- Private: popup creation
--------------------------------------------------------------------------------

private command ideAutocomplete_CreatePopup
   if there is a stack kPopupName then
      delete stack kPopupName
   end if

   create invisible stack kPopupName
   set the style of stack kPopupName to "palette"
   set the decorations of stack kPopupName to empty
   set the resizable of stack kPopupName to false
   set the width of stack kPopupName to kPopupWidth
   set the height of stack kPopupName to kItemHeight

   create field "completions" in stack kPopupName
   set the style of field "completions" of stack kPopupName to "list"
   set the lockText of field "completions" of stack kPopupName to true
   set the showBorder of field "completions" of stack kPopupName to true
   set the vScrollbar of field "completions" of stack kPopupName to false
   set the hScrollbar of field "completions" of stack kPopupName to false
   set the textSize of field "completions" of stack kPopupName to 12
   set the fixedLineHeight of field "completions" of stack kPopupName to true

   -- Wire up click-to-accept on the popup field
   set the script of field "completions" of stack kPopupName to \
         "on mouseUp" & return & \
         "   send ""ideAutocomplete_PopupClicked"" to stack " & \
         quote & kPopupName & quote & return & \
         "end mouseUp"
end ideAutocomplete_CreatePopup

--------------------------------------------------------------------------------
-- Private: show / hide
--------------------------------------------------------------------------------

private command ideAutocomplete_ShowPopup pEditorId, pMatches
   put pEditorId into sCurrentEditorId

   local tCount
   put the number of lines of pMatches into tCount

   local tPopupHeight
   put min(tCount, kMaxCompletions) * kItemHeight into tPopupHeight

   -- Resize stack and field together
   set the height of stack kPopupName to tPopupHeight
   set the width of stack kPopupName to kPopupWidth
   set the rect of field "completions" of stack kPopupName to \
         0, 0, kPopupWidth, tPopupHeight

   set the text of field "completions" of stack kPopupName to pMatches
   set the hilitedLine of field "completions" of stack kPopupName to 1

   -- Calculate screen position below the current caret line
   local tX, tY
   ideAutocomplete_GetCaretScreenPos pEditorId, tX, tY

   -- Keep the popup on screen
   local tScreenRect
   put the screenRect into tScreenRect
   if tX + kPopupWidth > item 3 of tScreenRect then
      put item 3 of tScreenRect - kPopupWidth into tX
   end if
   if tY + tPopupHeight > item 4 of tScreenRect then
      -- Flip above the current line
      subtract tPopupHeight + kItemHeight from tY
   end if

   set the topleft of stack kPopupName to tX, tY

   if not sPopupShowing then
      show stack kPopupName
      put true into sPopupShowing
   end if
end ideAutocomplete_ShowPopup

private command ideAutocomplete_HidePopup
   if sPopupShowing then
      hide stack kPopupName
      put false into sPopupShowing
   end if
   put empty into sCurrentEditorId
end ideAutocomplete_HidePopup

--------------------------------------------------------------------------------
-- Private: caret screen position
--------------------------------------------------------------------------------

private command ideAutocomplete_GetCaretScreenPos pEditorId, @rX, @rY
   dispatch function "getScriptField" to pEditorId
   local tField
   put the result into tField

   if tField is empty or not (there is a tField) then
      put item 1 of the rect of pEditorId + 20 into rX
      put item 4 of the rect of pEditorId - 30 into rY
      exit ideAutocomplete_GetCaretScreenPos
   end if

   local tLineNum
   put word 2 of the selectedLine of tField into tLineNum
   if tLineNum < 1 then
      put 1 into tLineNum
   end if

   local tFieldRect
   put the rect of tField into tFieldRect

   local tVScroll
   put the vScroll of tField into tVScroll

   -- Cumulative height of all lines above the current one
   local tAboveHeight
   if tLineNum > 1 then
      put the formattedHeight of line 1 to (tLineNum - 1) of tField into tAboveHeight
   else
      put 0 into tAboveHeight
   end if

   -- Height of the current line
   local tLineHeight
   put the formattedHeight of line tLineNum of tField into tLineHeight
   if tLineHeight < 1 then
      put kItemHeight into tLineHeight
   end if

   put item 1 of tFieldRect + 4 into rX
   put item 2 of tFieldRect + tAboveHeight + tLineHeight - tVScroll into rY
end ideAutocomplete_GetCaretScreenPos

--------------------------------------------------------------------------------
-- Private: accept completion
--------------------------------------------------------------------------------

private command ideAutocomplete_AcceptCompletion pEditorId
   local tCompletion
   put line (the hilitedLine of field "completions" of stack kPopupName) \
         of the text of field "completions" of stack kPopupName into tCompletion

   if tCompletion is empty then
      ideAutocomplete_HidePopup
      exit ideAutocomplete_AcceptCompletion
   end if

   -- Get the partial token to replace
   dispatch "getCaretToken" to pEditorId
   local tToken
   put the result into tToken

   if tToken is empty then
      ideAutocomplete_HidePopup
      exit ideAutocomplete_AcceptCompletion
   end if

   -- Find the cursor position and calculate where the token starts
   dispatch function "getScriptField" to pEditorId
   local tField
   put the result into tField

   local tCursor
   put word 2 of the selectedChunk of tField into tCursor

   local tTokenStart
   put tCursor - the number of chars of tToken into tTokenStart

   -- Use the editor's own textReplace so undo/redo and colorization work
   dispatch "textReplace" to pEditorId with tTokenStart, tToken, tCompletion

   ideAutocomplete_HidePopup
end ideAutocomplete_AcceptCompletion

--------------------------------------------------------------------------------
-- Private: list navigation
--------------------------------------------------------------------------------

private command ideAutocomplete_Navigate pDelta
   local tField
   put field "completions" of stack kPopupName into tField
   local tCurrent
   put the hilitedLine of tField into tCurrent
   local tCount
   put the number of lines of the text of tField into tCount
   set the hilitedLine of tField to max(1, min(tCount, tCurrent + pDelta))
end ideAutocomplete_Navigate

private function ideAutocomplete_SelectedWord
   return line (the hilitedLine of field "completions" of stack kPopupName) \
         of the text of field "completions" of stack kPopupName
end ideAutocomplete_SelectedWord

--------------------------------------------------------------------------------
-- Popup click handler (dispatched from the popup field's script)
--------------------------------------------------------------------------------

on ideAutocomplete_PopupClicked
   set the hilitedLine of field "completions" of stack kPopupName to the clickLine
   ideAutocomplete_AcceptCompletion sCurrentEditorId
end ideAutocomplete_PopupClicked
