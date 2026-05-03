script "mathWorker"

-- Worker script: runs in an isolated script-only stack.
-- Receives work via 'dispatch ... to worker "mathWorker"'
-- and replies via 'dispatch ... to caller'.

on computeSquares pMax
   -- Build a comma-delimited list of squares from 1 to pMax.
   local tResults
   repeat with i = 1 to pMax
      put i * i & comma after tResults
   end repeat
   delete the last char of tResults -- trim trailing comma

   -- Send the result back to whoever dispatched into us.
   dispatch "onComputeSquaresResult" to caller with tResults
end computeSquares

on reverseWords pSentence
   local tWords, tReversed
   put the number of words in pSentence into tWords
   repeat with i = tWords down to 1
      put word i of pSentence & space after tReversed
   end repeat
   put character 1 to -2 of tReversed into tReversed -- trim trailing space

   dispatch "onReverseWordsResult" to caller with tReversed
end reverseWords
