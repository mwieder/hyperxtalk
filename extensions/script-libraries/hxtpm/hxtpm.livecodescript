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

-- Base URL of the hxtpm package registry (raw GitHub content)
local sRegistryBase

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

   put "https://raw.githubusercontent.com/emily-elizabeth/hxtpm/main" \
         into sRegistryBase
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

Version: 1.0.0

Description:
Script library for installing, updating, and removing HyperXTalk packages
from the hxtpm registry.

Packages are hosted on GitHub. Script libraries (type "lcs") are installed to
the user libraries folder and become available immediately via start using stack.
LCB extensions (type "lcb") are installed to the user extensions folder.

Developers can build their own package manager UI on top of this library.
All commands return empty on success or an error message on failure via the result.

Usage:
   -- Browse all packages available in the registry
   put hxtpmAvailable() into tAll
   repeat for each key tName in tAll
      put tName && tAll[tName]["latest"] & return after field "packageList"
   end repeat

   -- Install the latest version of a package
   hxtpmInstall "com.example.library.myutils"
   if the result is not empty then answer error the result

   -- Install a specific version
   hxtpmInstall "com.example.library.myutils", "1.2.0"

   -- Check what is installed
   put hxtpmInstalled() into tInstalled
   repeat for each key tName in tInstalled
      put tName && tInstalled[tName]["version"]
   end repeat

   -- Uninstall
   hxtpmUninstall "com.example.library.myutils"

   -- Update to latest
   hxtpmUpdate "com.example.library.myutils"

*/

-- ---------------------------------------------------------------------------
-- Public API — commands
-- ---------------------------------------------------------------------------

/**

Summary: Install a package from the registry.

Parameters:
pName: The package name, e.g. "com.example.library.myutils".
pVersion: A specific version string. If omitted, the latest version is installed.

Description:
Downloads and installs the named package from the hxtpm registry. Script
libraries (type "lcs") are installed to the user libraries folder and loaded
immediately. The result is set to empty on success or an error message on failure.

Example:
   hxtpmInstall "com.example.library.myutils"
   if the result is not empty then
      answer error the result
   end if

*/
command hxtpmInstall pName, pVersion
   local tPackage
   put _fetchPackageInfo(pName) into tPackage
   if tPackage is empty then
      return "Package not found in registry: " & pName
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
      return _installLCS(pName, pVersion, tPackage["versions"][pVersion])
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
user extensions folder. The result is set to empty on success or an error
message on failure.

Example:
   hxtpmUninstall "com.example.library.myutils"
   if the result is not empty then
      answer error the result
   end if

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

Summary: Update an installed package to the latest registry version.

Parameters:
pName: The package name to update.

Description:
Fetches the latest version from the registry, uninstalls the current version,
and installs the latest. If the package is already at the latest version,
nothing happens and the result is empty. The result is set to empty on success
or an error message on failure.

Example:
   hxtpmUpdate "com.example.library.myutils"
   if the result is not empty then
      answer error the result
   end if

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
-- Public API — functions
-- ---------------------------------------------------------------------------

/**

Summary: Return registry metadata for a package.

Parameters:
pName: The package name.

Returns:
An array with keys: name, title, description, author, license, repository,
type, versions. Returns empty if the package is not found in the registry.

Example:
   put hxtpmInfo("com.example.library.myutils") into tInfo
   put tInfo["title"] into field "packageTitle"
   put tInfo["description"] into field "packageDescription"

*/
function hxtpmInfo pName
   return _fetchPackageInfo(pName)
end hxtpmInfo

/**

Summary: Return an array of all packages available in the registry.

Returns:
An array keyed by package name. Each entry contains: title, description,
author, type, license, repository, latest (version string), versions (list).
Returns empty if the index could not be fetched.

Example:
   put hxtpmAvailable() into tAll
   repeat for each key tName in tAll
      put tName && tAll[tName]["latest"] & return after field "packageList"
   end repeat

*/
function hxtpmAvailable
   local tRaw
   put URL (sRegistryBase & "/index.json") into tRaw
   if the result is not empty or tRaw is empty then return empty
   local tJsonImportRaw
   put JsonImport(tRaw) into tJsonImportRaw
   
   return tJsonImportRaw["packages"]
end hxtpmAvailable

/**

Summary: Return the available versions for a package, newest first.

Parameters:
pName: The package name.

Returns:
A line-delimited list of version strings sorted newest-first, or empty if
the package is not found in the registry.

Example:
   put hxtpmVersions("com.example.library.myutils") into tVersions
   -- tVersions is "2.0.0\n1.1.0\n1.0.0"

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
   local tInstalledMeta
   put _readInstalledMeta(pName) into tInstalledMeta
   return tInstalledMeta["version"]
end hxtpmInstalledVersion

/**

Summary: Return an array describing all installed packages.

Returns:
An array keyed by package name. Each value is an array with keys: name,
version, type, installed (date string).

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
-- Private: install helpers
-- ---------------------------------------------------------------------------

private function _installLCS pName, pVersion, pVersionData
   -- Download the source file to a temp location
   local tTempPath
   put revEnvironmentUserLibraries() & slash & ".hxtpm_download_tmp" into tTempPath
   put URL (pVersionData["source"]) into URL ("file:" & tTempPath)
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
   put _filenameFromURL(pVersionData["source"]) into tFilename
   local tDestPath
   put tDestFolder & slash & tFilename into tDestPath
   rename file tTempPath to tDestPath
   if the result is not empty then
      delete file tTempPath
      return "Could not save package file:" && the result
   end if

   -- Write hxtpm metadata
   put _writeMeta(tDestFolder, pName, pVersion, "lcs") into tErr
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
   -- It requires either pre-built platform LCE binaries in the registry
   -- or a local lc-compile step.
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
-- Private: registry
-- ---------------------------------------------------------------------------

private function _fetchPackageInfo pName
   local tURL, tRaw
   put sRegistryBase & "/packages/" & pName & "/package.json" into tURL
   put URL tURL into tRaw
   if the result is not empty or tRaw is empty then return empty
   return JsonImport(tRaw)
end _fetchPackageInfo

private function _latestVersion pPackageArray
   local tVersions
   put the keys of pPackageArray["versions"] into tVersions
   sort tVersions descending
   return line 1 of tVersions
end _latestVersion

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

private function _writeMeta pFolder, pName, pVersion, pType
   local tMeta
   put pName    into tMeta["name"]
   put pVersion into tMeta["version"]
   put pType    into tMeta["type"]
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
