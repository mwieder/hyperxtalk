// ARM64 server stubs - placeholder
#if defined(__arm64__) || defined(__aarch64__)
// No stubs needed - osxflst.cpp provides MCFontlist
#endif

#include "prefix.h"
#include "platform.h"

// Spell checking is not available in the server engine.
void MCPlatformSpellCheckText(MCStringRef p_text, MCRange*& r_errors, uindex_t& r_count)
{
    r_errors = nil;
    r_count  = 0;
}
