script "com.hyperxtalk.library.hxtpm"
/*
Copyright (C) 2026 HyperXTalk

This file is part of HyperXTalk.

HyperXTalk is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License v3 as published by the Free
Software Foundation.

HyperXTalk is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
HyperXTalk. If not, see <http://www.gnu.org/licenses/>.
*/

-- ---------------------------------------------------------------------------
-- Script-local state
-- ---------------------------------------------------------------------------

-- In-memory cache of the sources list.  Loaded lazily from disk on first use.
-- Each element is an array with keys: name, url|path, pinned (optional bool).
-- The official HyperXTalk source is always element 1 and is pinned.
local sSources

-- ---------------------------------------------------------------------------
-- Extension lifecycle
-- ---------------------------------------------------------------------------

on extensionInitialize
   if the target is not me then
      pass extensionInitialize
   end if

   insert the script of me into back

   if the environment contains "development" then
      set the _ideoverride of me to true
   end if
end extensionInitialize

on extensionFinalize
   if the target is not me then
      pass extensionFinalize
   end if

   remove the script of me from back
end extensionFinalize

/**

Title: HyperXTalk Package Manager Library

Author: HyperXTalk

Type: library

Version: 1.1.0

Description:
Script library for installing, updating, and removing HyperXTalk packages
from the hxtpm registry.

Packages are hosted on GitHub or stored locally. Script libraries (type "lcs")
are installed to the user libraries folder and become available immediately via
start using stack. LCB extensions (type "lcb") are installed to the user
extensions folder.

Multiple package sources are supported. A source can be a remote GitHub-hosted
registry or a local folder on disk. The official HyperXTalk source is always
present and cannot be removed; additional sources can be added by developers
or users. Packages are resolved in source order; the first source that
provides a package wins.

The sources list is stored in a JSON file at:
   <UserLibraries>/.hxtpm/sources.json

All commands return empty on success or an error message on failure via the
result.

Usage:
   -- Browse all packages available across all sources
   put hxtpmAvailable() into tAll
   repeat for each key tName in tAll
      put tName && tAll[tName]["latest"] & return after field "packageList"
   end repeat

   -- Install the latest version of a package (resolved from all sources)
   hxtpmInstall "com.example.library.myutils"
   if the result is not empty then answer error the result

   -- Install a specific version
   hxtpmInstall "com.example.library.myutils", "1.2.0"

   -- Manage sources
   hxtpmSourceAdd "Acme Corp", "https://raw.githubusercontent.com/acme/hxtpm-packages/main"
   hxtpmSourceAdd "Local Dev", "/Users/me/dev/my-packages"
   hxtpmSourceRemove "Acme Corp"
   put hxtpmSourceList() into tSources

   -- Check what is installed
   put hxtpmInstalled() into tInstalled
   repeat for each key tName in tInstalled
      put tName && tInstalled[tName]["version"] & return after field "packageList"
   end repeat

   -- Uninstall / update
   hxtpmUninstall "com.example.library.myutils"
   hxtpmUpdate "com.example.library.myutils"

*/

-- ---------------------------------------------------------------------------
-- Public API — source management
-- ---------------------------------------------------------------------------

/**

Summary: Add a new package source.

Parameters:
pName: A short human-readable name for the source, e.g. "Acme Corp Packages".
pURLOrPath: Either a base URL for a remote source (e.g.
   "https://raw.githubusercontent.com/acme/hxtpm-packages/main") or an
   absolute local folder path (e.g. "/Users/me/dev/my-packages").
   The source must expose an index.json at its root.

Description:
Validates the source by fetching its index.json, then appends it to the
sources list. Local paths are implicitly trusted. Remote sources added by
the user are trusted by act of adding them. The result is empty on success
or an error message on failure.

Example:
   hxtpmSourceAdd "Acme Corp", "https://raw.githubusercontent.com/acme/hxtpm-pkgs/main"
   if the result is not empty then answer error the result

   hxtpmSourceAdd "Local Dev", "/Users/me/dev/local-repo"
   if the result is not empty then answer error the result

*/
command hxtpmSourceAdd pName, pURLOrPath
   if pName is empty or pURLOrPath is empty then
      return "Both a name and a URL or path are required"
   end if

   local tSources
   put _loadSources() into tSources

   -- Reject duplicates
   repeat for each key tIdx in tSources
      if tSources[tIdx]["name"] is pName then
         return "A source named '" & pName & "' already exists"
      end if
   end repeat

   -- Build source entry and determine base for index fetch
   local tNewSource, tBase
   if pURLOrPath begins with "/" or char 2 of pURLOrPath is ":" then
      -- Looks like a local absolute path (Unix /… or Windows C:\…)
      if there is not a folder pURLOrPath then
         return "Local path does not exist: " & pURLOrPath
      end if
      put pURLOrPath into tNewSource["path"]
      put "file:" & pURLOrPath into tBase
   else
      put pURLOrPath into tNewSource["url"]
      put pURLOrPath into tBase
   end if
   put pName into tNewSource["name"]

   -- Validate: the source must serve a readable index.json
   local tTestRaw
   put URL (tBase & "/index.json") into tTestRaw
   if the result is not empty or tTestRaw is empty then
      return "Could not fetch index.json from source." && \
            "Check the URL or path and try again."
   end if
   local tTestIndex
   put JsonImport(tTestRaw) into tTestIndex
   if tTestIndex is not an array or tTestIndex["packages"] is empty then
      return "Source index.json is not a valid hxtpm index"
   end if

   -- Append and persist
   local tNext
   put the number of elements of tSources + 1 into tNext
   put tNewSource into tSources[tNext]
   put tSources into sSources
   _saveSources

   return empty
end hxtpmSourceAdd

/**

Summary: Remove a previously added source.

Parameters:
pName: The name of the source to remove (as it was given to hxtpmSourceAdd).

Description:
Removes the named source from the list. The official HyperXTalk source is
pinned and cannot be removed. Removing a source does not uninstall packages
that were installed from it. The result is empty on success or an error
message on failure.

Example:
   hxtpmSourceRemove "Acme Corp"
   if the result is not empty then answer error the result

*/
command hxtpmSourceRemove pName
   local tSources
   put _loadSources() into tSources

   local tNewSources, tCount, tFound
   put 1 into tCount
   repeat for each key tIdx in tSources
      if tSources[tIdx]["name"] is pName then
         put true into tFound
         if tSources[tIdx]["pinned"] then
            return "Cannot remove the pinned source '" & pName & "'"
         end if
         -- Skip: don't copy into tNewSources
      else
         put tSources[tIdx] into tNewSources[tCount]
         add 1 to tCount
      end if
   end repeat

   if not tFound then
      return "Source not found: " & pName
   end if

   put tNewSources into sSources
   _saveSources
   return empty
end hxtpmSourceRemove

/**

Summary: Return the current list of package sources.

Returns:
A numerically-keyed array. Each element contains: name, url or path,
and optionally pinned (true for the official source).

Example:
   put hxtpmSourceList() into tSources
   repeat for each key tIdx in tSources
      put tSources[tIdx]["name"] & return after field "sourceList"
   end repeat

*/
function hxtpmSourceList
   return _loadSources()
end hxtpmSourceList

-- ---------------------------------------------------------------------------
-- Public API — packages (commands)
-- ---------------------------------------------------------------------------

/**

Summary: Install a package.

Parameters:
pName: The package name, e.g. "com.example.library.myutils".
pVersion: A specific version string. If omitted, the latest version is installed.

Description:
Searches all configured sources in order and installs the package from the
first source that provides it. Script libraries (type "lcs") are installed
to the user libraries folder and loaded immediately. The result is empty on
success or an error message on failure.

Example:
   hxtpmInstall "com.example.library.myutils"
   if the result is not empty then answer error the result

   hxtpmInstall "com.example.library.myutils", "1.2.0"

*/
command hxtpmInstall pName, pVersion
   local tPackage
   put _fetchPackageInfo(pName) into tPackage
   if tPackage is empty then
      return "Package not found in any configured source: " & pName
   end if

   if pVersion is empty then
      put _latestVersion(tPackage) into pVersion
   end if

   if tPackage["versions"][pVersion] is empty then
      return "Version" && pVersion && "not found for" && pName
   end if

   local tType
   put tPackage["type"] into tType

   if tType is "lcs" then
      return _installLCS(pName, pVersion, tPackage["versions"][pVersion], tPackage["source"], tPackage["sourceBase"])
   else if tType is "lcb" then
      return _installLCB(pName, pVersion, tPackage["versions"][pVersion])
   else
      return "Unknown package type: " & tType
   end if
end hxtpmInstall

/**

Summary: Uninstall an installed package.

Parameters:
pName: The package name to remove.

Description:
Stops using the library and removes its files from the user libraries or
user extensions folder. The result is empty on success or an error message
on failure.

Example:
   hxtpmUninstall "com.example.library.myutils"
   if the result is not empty then answer error the result

*/
command hxtpmUninstall pName
   if not hxtpmIsInstalled(pName) then
      return "Package not installed: " & pName
   end if

   local tMeta
   put _readInstalledMeta(pName) into tMeta

   if tMeta["type"] is "lcs" then
      return _uninstallLCS(pName)
   else if tMeta["type"] is "lcb" then
      return _uninstallLCB(pName)
   else
      return "Unknown installed package type: " & tMeta["type"]
   end if
end hxtpmUninstall

/**

Summary: Update an installed package to the latest version from its source.

Parameters:
pName: The package name to update.

Description:
Fetches the latest version from whichever source originally provided the
package, uninstalls the current version, and installs the latest. If already
at the latest version, nothing happens and the result is empty. The result
is empty on success or an error message on failure.

Example:
   hxtpmUpdate "com.example.library.myutils"
   if the result is not empty then answer error the result

*/
command hxtpmUpdate pName
   if not hxtpmIsInstalled(pName) then
      return "Package not installed: " & pName
   end if

   local tLatest
   put hxtpmLatestVersion(pName) into tLatest
   if tLatest is empty then
      return "Could not fetch registry info for: " & pName
   end if

   if tLatest is hxtpmInstalledVersion(pName) then
      return empty -- already at latest, not an error
   end if

   hxtpmUninstall pName
   if the result is not empty then return the result

   hxtpmInstall pName, tLatest
   return the result
end hxtpmUpdate

-- ---------------------------------------------------------------------------
-- Public API — packages (functions)
-- ---------------------------------------------------------------------------

/**

Summary: Return registry metadata for a package.

Parameters:
pName: The package name.

Returns:
An array with keys: name, title, description, author, license, repository,
type, source (source name), versions. Returns empty if not found in any source.

Example:
   put hxtpmInfo("com.example.library.myutils") into tInfo
   put tInfo["title"] into field "packageTitle"
   put tInfo["source"] into field "packageSource"

*/
function hxtpmInfo pName
   return _fetchPackageInfo(pName)
end hxtpmInfo

/**

Summary: Return an array of all packages available across all sources.

Returns:
An array keyed by package name. Each entry contains: title, description,
author, type, license, repository, latest (version string), versions (list),
source (source name). When the same package exists in multiple sources, the
first source in the list wins. Returns empty if no source index could be
fetched.

Example:
   put hxtpmAvailable() into tAll
   repeat for each key tName in tAll
      put tName && tAll[tName]["latest"] && "(" & tAll[tName]["source"] & ")" \
            & return after field "packageList"
   end repeat

*/
function hxtpmAvailable
   local tSources, tAll
   put _loadSources() into tSources

   repeat for each key tIdx in tSources
      local tBase, tRaw, tIndex
      put _sourceBase(tSources[tIdx]) into tBase
      if tBase is empty then next repeat

      put URL (tBase & "/index.json") into tRaw
      if the result is not empty or tRaw is empty then next repeat

      put JsonImport(tRaw) into tIndex
      if tIndex is not an array then next repeat

      -- First source that lists a package name wins
      repeat for each key tPkgName in tIndex["packages"]
         if tAll[tPkgName] is empty then
            put tIndex["packages"][tPkgName] into tAll[tPkgName]
            put tSources[tIdx]["name"] into tAll[tPkgName]["source"]
         end if
      end repeat
   end repeat

   return tAll
end hxtpmAvailable

/**

Summary: Return the available versions for a package, newest first.

Parameters:
pName: The package name.

Returns:
A line-delimited list of version strings sorted newest-first, or empty if
the package is not found in any source.

Example:
   put hxtpmVersions("com.example.library.myutils") into tVersions

*/
function hxtpmVersions pName
   local tPackage
   put _fetchPackageInfo(pName) into tPackage
   if tPackage is empty then return empty

   local tVersions
   put the keys of tPackage["versions"] into tVersions
   sort tVersions descending
   return tVersions
end hxtpmVersions

/**

Summary: Return the latest available version of a package.

Parameters:
pName: The package name.

Returns:
The latest version string, or empty if the package is not found.

Example:
   put hxtpmLatestVersion("com.example.library.myutils") into tLatest

*/
function hxtpmLatestVersion pName
   local tPackage
   put _fetchPackageInfo(pName) into tPackage
   if tPackage is empty then return empty
   return _latestVersion(tPackage)
end hxtpmLatestVersion

/**

Summary: Return true if a package is currently installed.

Parameters:
pName: The package name.

Returns:
True if the package is installed, false otherwise.

Example:
   if hxtpmIsInstalled("com.example.library.myutils") then
      put "installed" into field "status"
   end if

*/
function hxtpmIsInstalled pName
   if there is a file _metaPath(pName, "lcs") then return true
   if there is a file _metaPath(pName, "lcb") then return true
   return false
end hxtpmIsInstalled

/**

Summary: Return the currently installed version of a package.

Parameters:
pName: The package name.

Returns:
The installed version string, or empty if the package is not installed.

Example:
   put hxtpmInstalledVersion("com.example.library.myutils") into tVersion

*/
function hxtpmInstalledVersion pName
   return _readInstalledMeta(pName)["version"]
end hxtpmInstalledVersion

/**

Summary: Return an array describing all installed packages.

Returns:
An array keyed by package name. Each value is an array with keys: name,
version, type, source (source name), installed (date string).

Example:
   put hxtpmInstalled() into tPackages
   repeat for each key tName in tPackages
      put tName && tPackages[tName]["version"] & return after field "packageList"
   end repeat

*/
function hxtpmInstalled
   local tResult

   local tLibFolder
   put revEnvironmentUserLibraries() into tLibFolder
   _scanInstalledFolder tLibFolder, tResult

   local tExtFolder
   put revEnvironmentUserExtensionsPath() into tExtFolder
   _scanInstalledFolder tExtFolder, tResult

   return tResult
end hxtpmInstalled

-- ---------------------------------------------------------------------------
-- Private: sources management
-- ---------------------------------------------------------------------------

-- Return the in-memory sources array, loading from disk if needed.
private function _loadSources
   if sSources is an array and the number of elements of sSources > 0 then
      return sSources
   end if

   local tPath
   put _sourcesFilePath() into tPath

   if there is a file tPath then
      local tRaw
      put URL ("file:" & tPath) into tRaw
      if tRaw is not empty then
         local tParsed
         put JsonImport(tRaw) into tParsed
         if tParsed is an array and the number of elements of tParsed > 0 then
            -- Ensure the official source is still element 1 and still pinned.
            -- If someone edited the file and removed it, we add it back.
            if tParsed[1]["name"] is not _officialSourceName() then
               local tRepaired, tOld
               put _defaultSources() into tRepaired
               put 1 into tOld
               repeat with tOld = 1 to the number of elements of tParsed
                  if tParsed[tOld]["name"] is not _officialSourceName() then
                     local tNext
                     put the number of elements of tRepaired + 1 into tNext
                     put tParsed[tOld] into tRepaired[tNext]
                  end if
               end repeat
               put tRepaired into tParsed
            end if
            put tParsed into sSources
            return sSources
         end if
      end if
   end if

   -- No file or unreadable: initialise with the official source only
   put _defaultSources() into sSources
   _saveSources
   return sSources
end _loadSources

-- Write the in-memory sources array to disk.
private command _saveSources
   local tPath
   put _sourcesFilePath() into tPath

   -- Ensure the config folder exists
   local tDir
   set the itemDelimiter to slash
   put item 1 to -2 of tPath into tDir
   set the itemDelimiter to comma
   if there is not a folder tDir then create folder tDir

   put JsonExport(sSources) into URL ("file:" & tPath)
end _saveSources

-- Absolute path to the sources.json config file.
private function _sourcesFilePath
   return revEnvironmentUserLibraries() & slash & ".hxtpm" & slash & "sources.json"
end _sourcesFilePath

-- The canonical name for the official pinned source.
private function _officialSourceName
   return "HyperXTalk Official"
end _officialSourceName

-- Return the default single-element sources array (official source only).
private function _defaultSources
   local tSrc
   put _officialSourceName() into tSrc[1]["name"]
   put "https://raw.githubusercontent.com/emily-elizabeth/hxtpm/main" into tSrc[1]["url"]
   put true into tSrc[1]["pinned"]
   return tSrc
end _defaultSources

-- Return the base URL string used to construct resource URLs for a source.
-- For remote sources this is the url field; for local sources it is file:<path>.
private function _sourceBase pSource
   if pSource["url"] is not empty then
      return pSource["url"]
   else if pSource["path"] is not empty then
      -- Normalise: ensure no trailing slash
      local tPath
      put pSource["path"] into tPath
      if the last char of tPath is "/" or the last char of tPath is "\" then
         delete the last char of tPath
      end if
      return "file:" & tPath
   end if
   return empty
end _sourceBase

-- ---------------------------------------------------------------------------
-- Private: registry resolution (multi-source)
-- ---------------------------------------------------------------------------

-- Search all sources in order for pName. Returns the package info array from
-- the first source that has it, with extra keys "source" (source name) and
-- "sourceBase" (base URL string) added for use by the installer.
private function _fetchPackageInfo pName
   local tSources
   put _loadSources() into tSources

   repeat for each key tIdx in tSources
      local tBase, tRaw
      put _sourceBase(tSources[tIdx]) into tBase
      if tBase is empty then next repeat

      put URL (tBase & "/packages/" & pName & "/package.json") into tRaw
      if the result is not empty or tRaw is empty then next repeat

      local tPackage
      put JsonImport(tRaw) into tPackage
      if tPackage is an array then
         put tSources[tIdx]["name"] into tPackage["source"]
         put tBase into tPackage["sourceBase"]
         return tPackage
      end if
   end repeat

   return empty
end _fetchPackageInfo

private function _latestVersion pPackageArray
   local tVersions
   put the keys of pPackageArray["versions"] into tVersions
   sort tVersions descending
   return line 1 of tVersions
end _latestVersion

-- ---------------------------------------------------------------------------
-- Private: install helpers
-- ---------------------------------------------------------------------------

-- Resolve a package file URL: if pFileRef is already an absolute URL or
-- file: path, use it as-is. Otherwise treat it as relative to pSourceBase.
private function _resolveFileURL pFileRef, pSourceBase
   if pFileRef begins with "http://" or \
         pFileRef begins with "https://" or \
         pFileRef begins with "file:" then
      return pFileRef
   end if
   -- Relative reference: append to source base
   if the last char of pSourceBase is "/" then
      return pSourceBase & pFileRef
   else
      return pSourceBase & "/" & pFileRef
   end if
end _resolveFileURL

private function _installLCS pName, pVersion, pVersionData, pSourceName, pSourceBase
   -- Resolve the download URL (absolute or relative to source base)
   local tFileURL
   put _resolveFileURL(pVersionData["source"], pSourceBase) into tFileURL

   -- Download to a temp location
   local tTempPath
   put revEnvironmentUserLibraries() & slash & ".hxtpm_download_tmp" into tTempPath
   put URL tFileURL into URL ("file:" & tTempPath)
   if the result is not empty then
      return "Download failed for" && pName & ":" && the result
   end if

   -- Verify checksum
   local tErr
   put _verifyChecksum(tTempPath, pVersionData["checksum"]) into tErr
   if tErr is not empty then
      delete file tTempPath
      return tErr
   end if

   -- Create the package subfolder
   local tDestFolder
   put revEnvironmentUserLibraries() & slash & pName into tDestFolder
   create folder tDestFolder
   if the result is not empty then
      delete file tTempPath
      return "Could not create package folder:" && the result
   end if

   -- Move downloaded file into the package folder
   local tFilename
   put _filenameFromURL(tFileURL) into tFilename
   local tDestPath
   put tDestFolder & slash & tFilename into tDestPath
   rename file tTempPath to tDestPath
   if the result is not empty then
      delete file tTempPath
      return "Could not save package file:" && the result
   end if

   -- Write hxtpm metadata (includes source so updates hit the right repo)
   put _writeMeta(tDestFolder, pName, pVersion, "lcs", pSourceName) into tErr
   if tErr is not empty then return tErr

   -- Load the library immediately
   try
      start using stack tDestPath
   catch tError
      return "Package installed but failed to load:" && tError
   end try

   return empty
end _installLCS

private function _installLCB pName, pVersion, pVersionData
   -- LCB package support is planned for a future release.
   return "LCB package installation is not yet supported"
end _installLCB

private function _uninstallLCS pName
   local tFolder
   put revEnvironmentUserLibraries() & slash & pName into tFolder

   -- Stop using the library before removing files
   repeat for each line tFile in files(tFolder)
      if tFile ends with ".livecodescript" then
         try
            stop using stack (tFolder & slash & tFile)
         catch tError
            -- Not fatal — the file will still be removed
         end try
         exit repeat
      end if
   end repeat

   -- Remove the package folder
   local tErr
   put _deleteFolder(tFolder) into tErr
   if tErr is not empty then
      return "Could not remove package folder:" && tErr
   end if

   return empty
end _uninstallLCS

private function _uninstallLCB pName
   return "LCB package uninstallation is not yet supported"
end _uninstallLCB

-- ---------------------------------------------------------------------------
-- Private: metadata
-- ---------------------------------------------------------------------------

private function _metaPath pName, pType
   if pType is "lcs" then
      return revEnvironmentUserLibraries() & slash & pName & slash & "hxtpm.json"
   end if
   return revEnvironmentUserExtensionsPath() & slash & pName & slash & "hxtpm.json"
end _metaPath

private function _readInstalledMeta pName
   local tPath
   put _metaPath(pName, "lcs") into tPath
   if there is not a file tPath then
      put _metaPath(pName, "lcb") into tPath
   end if
   if there is not a file tPath then return empty
   return JsonImport(URL ("file:" & tPath))
end _readInstalledMeta

private function _writeMeta pFolder, pName, pVersion, pType, pSourceName
   local tMeta
   put pName       into tMeta["name"]
   put pVersion    into tMeta["version"]
   put pType       into tMeta["type"]
   put pSourceName into tMeta["source"]
   put the short date into tMeta["installed"]

   put JsonExport(tMeta) into URL ("file:" & pFolder & slash & "hxtpm.json")
   if the result is not empty then
      return "Could not write package metadata:" && the result
   end if
   return empty
end _writeMeta

private command _scanInstalledFolder pFolder, @xResult
   repeat for each line tSubfolder in folders(pFolder)
      if tSubfolder begins with "." then next repeat
      local tMetaPath
      put pFolder & slash & tSubfolder & slash & "hxtpm.json" into tMetaPath
      if there is a file tMetaPath then
         local tMeta
         put JsonImport(URL ("file:" & tMetaPath)) into tMeta
         if tMeta["name"] is not empty then
            put tMeta into xResult[tMeta["name"]]
         end if
      end if
   end repeat
end _scanInstalledFolder

-- ---------------------------------------------------------------------------
-- Private: utilities
-- ---------------------------------------------------------------------------

private function _verifyChecksum pFilePath, pExpected
   if pExpected is empty or pExpected begins with "sha256:placeholder" then
      return empty -- no checksum to verify
   end if

   local tData, tDigest, tHex, tByte
   put URL ("file:" & pFilePath) into tData
   put messageDigest(tData, "SHA-256") into tDigest

   repeat with i = 1 to the length of tDigest
      put baseConvert(charToNum(char i of tDigest), 10, 16) into tByte
      if the length of tByte is 1 then put "0" before tByte
      put tByte after tHex
   end repeat

   if ("sha256:" & tHex) is not pExpected then
      return "Checksum mismatch: expected" && pExpected & ", got sha256:" & tHex
   end if
   return empty
end _verifyChecksum

private function _filenameFromURL pURL
   local tSaved, tResult
   put the itemDel into tSaved
   set the itemDel to "/"
   put the last item of pURL into tResult
   set the itemDel to tSaved
   return tResult
end _filenameFromURL

-- Recursively delete a folder and all its contents.
private function _deleteFolder pFolder
   repeat for each line tFile in files(pFolder)
      delete file (pFolder & slash & tFile)
      if the result is not empty then
         return "Could not delete file" && tFile & ":" && the result
      end if
   end repeat

   repeat for each line tSub in folders(pFolder)
      if tSub is "." or tSub is ".." then next repeat
      local tErr
      put _deleteFolder(pFolder & slash & tSub) into tErr
      if tErr is not empty then return tErr
   end repeat

   delete folder pFolder
   if the result is not empty then
      return "Could not delete folder" && pFolder & ":" && the result
   end if
   return empty
end _deleteFolder
