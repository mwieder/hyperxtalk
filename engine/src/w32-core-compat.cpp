/* Copyright (C) 2016 LiveCode Ltd.

This file is part of LiveCode.

LiveCode is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License v3 as published by the Free
Software Foundation.

LiveCode is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
for more details.

You should have received a copy of the GNU General Public License
along with LiveCode.  If not see <http://www.gnu.org/licenses/>.  */

#include "prefix.h"

#include "globals.h"
#include "uidc.h"
#include "platform.h"

// ── ISpellChecker COM interfaces (Windows 8+) ────────────────────────────────
//
// <spellcheck.h> is gated on NTDDI_WIN8, but the project targets _WIN32_WINNT
// 0x0601 (Windows 7) for graceful degradation.  We therefore declare the
// interfaces inline with explicit GUIDs — the same technique used by
// w32-notification.cpp for WinRT interfaces.
//
// GUIDs match the published Windows SDK (all SDK versions 8.0+):
//   CLSID_SpellCheckerFactory  {7AB36653-1796-484B-BDFA-E74F1DB7C1DC}
//   ISpellCheckerFactory       {8E018A9D-2415-4677-BF08-794EA61F94BB}
//   ISpellChecker              {B6FD0B71-E2BC-4653-8D05-F197E412770B}
//   IEnumSpellingError         {803E3BD4-2828-4410-8290-418D1D73C762}
//   ISpellingError             {B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3}
//
// Only the vtable slots we actually call need to be declared; later slots in
// the real implementation are not affected.

static const CLSID s_CLSID_SpellCheckerFactory =
    {0x7ab36653, 0x1796, 0x484b, {0xbd, 0xfa, 0xe7, 0x4f, 0x1d, 0xb7, 0xc1, 0xdc}};

// Forward declarations for types referenced by interface methods we skip.
struct IEnumString;
struct ISpellCheckerChangedEventHandler;
struct IOptionDescription;

// CORRECTIVE_ACTION — only the enum tag is needed (vtable placeholder param).
typedef enum CORRECTIVE_ACTION
{
    CORRECTIVE_ACTION_NONE              = 0,
    CORRECTIVE_ACTION_GET_SUGGESTIONS   = 1,
    CORRECTIVE_ACTION_REPLACE           = 2,
    CORRECTIVE_ACTION_DELETE            = 3,
} CORRECTIVE_ACTION;

struct ISpellingError;
struct IEnumSpellingError;
struct ISpellChecker;

// ISpellingError — vtable layout (IUnknown + 4 own methods):
//   [3] get_StartIndex, [4] get_Length, [5] get_CorrectiveAction, [6] get_Replacement
MIDL_INTERFACE("B7C82D61-FBE8-4B47-9B27-6C0D2E0DE0A3")
ISpellingError : public IUnknown
{
public:
    virtual HRESULT STDMETHODCALLTYPE get_StartIndex(
        /* [out] */ ULONG *value) = 0;

    virtual HRESULT STDMETHODCALLTYPE get_Length(
        /* [out] */ ULONG *value) = 0;

    virtual HRESULT STDMETHODCALLTYPE get_CorrectiveAction(
        /* [out] */ CORRECTIVE_ACTION *value) = 0;

    virtual HRESULT STDMETHODCALLTYPE get_Replacement(
        /* [out] */ LPWSTR *value) = 0;
};

// IEnumSpellingError — vtable layout (IUnknown + 1 own method):
//   [3] Next  — returns S_OK (got one) or S_FALSE (exhausted)
MIDL_INTERFACE("803E3BD4-2828-4410-8290-418D1D73C762")
IEnumSpellingError : public IUnknown
{
public:
    virtual HRESULT STDMETHODCALLTYPE Next(
        /* [out] */ ISpellingError **value) = 0;
};

// ISpellChecker — we declare only through Check() (slot [4]).
// The real interface has ~14 methods; slots beyond [4] are unused here.
//   [3] get_LanguageTag, [4] Check
MIDL_INTERFACE("B6FD0B71-E2BC-4653-8D05-F197E412770B")
ISpellChecker : public IUnknown
{
public:
    virtual HRESULT STDMETHODCALLTYPE get_LanguageTag(
        /* [out] */ LPWSTR *value) = 0;

    virtual HRESULT STDMETHODCALLTYPE Check(
        /* [in]  */ LPCWSTR             text,
        /* [out] */ IEnumSpellingError **value) = 0;
};

// ISpellCheckerFactory — full declaration (3 own methods used: IsSupported,
// CreateSpellChecker; get_SupportedLanguages must be declared first to keep
// vtable offsets correct).
//   [3] get_SupportedLanguages, [4] IsSupported, [5] CreateSpellChecker
MIDL_INTERFACE("8E018A9D-2415-4677-BF08-794EA61F94BB")
ISpellCheckerFactory : public IUnknown
{
public:
    virtual HRESULT STDMETHODCALLTYPE get_SupportedLanguages(
        /* [out] */ IEnumString **value) = 0;

    virtual HRESULT STDMETHODCALLTYPE IsSupported(
        /* [in]  */ LPCWSTR languageTag,
        /* [out] */ BOOL   *value) = 0;

    virtual HRESULT STDMETHODCALLTYPE CreateSpellChecker(
        /* [in]  */ LPCWSTR       languageTag,
        /* [out] */ ISpellChecker **value) = 0;
};

////////////////////////////////////////////////////////////////////////////////
// MCPlatform* compatability functions
//   Implementation of MCPlatform* functions required for MCPlatformPlayer implementation.

void MCPlatformBreakWait(void)
{
	MCscreen->pingwait();
}

// ── Windows spell checking via ISpellChecker ─────────────────────────────────
//
// Strategy mirrors mac-core.mm / NSSpellChecker:
//   1. Lazily create one ISpellChecker instance for the user's default locale
//      and cache it for the lifetime of the process.
//   2. For each call, convert the MCStringRef to a LPCWSTR and pass it to
//      ISpellChecker::Check(), which returns an IEnumSpellingError.
//   3. Walk the error enumerator, collecting (start, length) pairs that
//      correspond directly to UTF-16 code-unit positions — the same unit that
//      MCStringRef uses on Windows — so no position conversion is needed.
//   4. Return a heap-allocated MCRange[] that the caller owns (and frees with
//      delete[], matching the Mac side).
//
// Failure modes:
//   • If the user's locale has no registered spell-check provider, IsSupported
//     returns FALSE and we fall back to r_count == 0.
//   • If COM is not yet initialized on the calling thread, CoCreateInstance
//     will fail and we fall back silently.

void MCPlatformSpellCheckText(MCStringRef p_text, MCRange*& r_errors, uindex_t& r_count)
{
    r_errors = nil;
    r_count  = 0;

    if (!p_text || MCStringIsEmpty(p_text))
        return;

    // Lazy-init: create one ISpellChecker for the user's default locale.
    static ISpellChecker *s_checker   = NULL;
    static bool           s_init_done = false;

    if (!s_init_done)
    {
        s_init_done = true;

        ISpellCheckerFactory *t_factory = NULL;
        HRESULT t_hr = CoCreateInstance(s_CLSID_SpellCheckerFactory,
                                        NULL, CLSCTX_INPROC_SERVER,
                                        __uuidof(ISpellCheckerFactory),
                                        (void **)&t_factory);
        if (SUCCEEDED(t_hr) && t_factory != NULL)
        {
            wchar_t t_locale[LOCALE_NAME_MAX_LENGTH] = {};
            if (GetUserDefaultLocaleName(t_locale, LOCALE_NAME_MAX_LENGTH) > 0)
            {
                BOOL t_supported = FALSE;
                t_hr = t_factory->IsSupported(t_locale, &t_supported);
                if (SUCCEEDED(t_hr) && t_supported)
                    t_factory->CreateSpellChecker(t_locale, &s_checker);
            }
            t_factory->Release();
        }
    }

    if (s_checker == NULL)
        return;

    // Convert MCStringRef to a NUL-terminated wchar_t string.
    // MCStringConvertToWString allocates a unichar_t (= uint16_t) buffer;
    // on Windows wchar_t is also 16-bit, so the reinterpret_cast below is safe.
    unichar_t *t_wbuf = NULL;
    if (!MCStringConvertToWString(p_text, t_wbuf))
        return;

    IEnumSpellingError *t_enum = NULL;
    HRESULT t_check_hr = s_checker->Check(reinterpret_cast<LPCWSTR>(t_wbuf), &t_enum);
    MCMemoryDeallocate(t_wbuf);

    if (FAILED(t_check_hr) || t_enum == NULL)
        return;

    // Walk the error enumerator into a growable MCRange array.
    uindex_t  t_capacity = 8;
    uindex_t  t_count    = 0;
    MCRange  *t_errors   = new (nothrow) MCRange[t_capacity];
    if (!t_errors)
    {
        t_enum->Release();
        return;
    }

    ISpellingError *t_error = NULL;
    while (t_enum->Next(&t_error) == S_OK)
    {
        ULONG t_start  = 0;
        ULONG t_length = 0;
        t_error->get_StartIndex(&t_start);
        t_error->get_Length(&t_length);
        t_error->Release();
        t_error = NULL;

        // Grow the array if needed (doubling strategy).
        if (t_count == t_capacity)
        {
            uindex_t  t_new_cap = t_capacity * 2;
            MCRange  *t_grown   = new (nothrow) MCRange[t_new_cap];
            if (!t_grown)
                break;
            for (uindex_t i = 0; i < t_count; i++)
                t_grown[i] = t_errors[i];
            delete[] t_errors;
            t_errors   = t_grown;
            t_capacity = t_new_cap;
        }

        t_errors[t_count].offset = (uindex_t)t_start;
        t_errors[t_count].length = (uindex_t)t_length;
        t_count++;
    }
    t_enum->Release();

    if (t_count == 0)
    {
        delete[] t_errors;
        return;
    }

    r_errors = t_errors;
    r_count  = t_count;
}

void MCPlatformShareContent(MCPlatformWindowRef, MCPlatformShareType, MCValueRef, bool, MCRectangle, MCStringRef)
{
    // Not supported on Windows.
}

bool MCPlatformWaitForEvent(double duration, bool blocking)
{
	bool t_dispatch = !blocking;
	return MCscreen->wait(duration, t_dispatch, false);
}

////////////////////////////////////////////////////////////////////////////////
