// ui/logview.h - log panel storage + connection-log filtering.
//
// Unity-build include: pulled into main.c after the globals (LogStore, g_connStore/
// g_actStore, g_autoClear, g_flt/g_fltCount, g_profile) it operates on. Not standalone.
#ifndef PB_UI_LOGVIEW_H
#define PB_UI_LOGVIEW_H

static void GetTimePrefix(wchar_t* buf, int cch)
{
    SYSTEMTIME st; GetLocalTime(&st);
    _snwprintf_s(buf, cch, _TRUNCATE, L"[%02d:%02d:%02d] ", st.wHour, st.wMinute, st.wSecond);
}

static void AppendToEdit(HWND edit, const wchar_t* line)
{
    int len = GetWindowTextLengthW(edit);
    if (len > MAX_LOG_CHARS)
    {
        SendMessageW(edit, EM_SETSEL, 0, len / 2);
        SendMessageW(edit, EM_REPLACESEL, FALSE, (LPARAM)L"");
        len = GetWindowTextLengthW(edit);
    }
    SendMessageW(edit, EM_SETSEL, len, len);
    SendMessageW(edit, EM_REPLACESEL, FALSE, (LPARAM)line);
}

// Case-insensitive substring test (avoids a shlwapi dependency).
static BOOL ContainsCI(const wchar_t* hay, const wchar_t* needle)
{
    if (!needle || !needle[0]) return TRUE;
    size_t nl = wcslen(needle);
    for (const wchar_t* p = hay; *p; p++)
        if (_wcsnicmp(p, needle, nl) == 0) return TRUE;
    return FALSE;
}
static BOOL LogLineMatches(const LogStore* s, const wchar_t* line)
{
    return s->filter[0] ? ContainsCI(line, s->filter) : TRUE;
}

// connection-log filters (include/exclude rules)
static const wchar_t* StrStrCI(const wchar_t* hay, const wchar_t* needle, size_t nlen)
{
    for (; *hay; hay++) if (_wcsnicmp(hay, needle, nlen) == 0) return hay;
    return NULL;
}
static BOOL GlobMatch(const wchar_t* text, const wchar_t* pattern)
{
    if (!pattern[0] || wcscmp(pattern, L"*") == 0) return TRUE;
    if (!wcschr(pattern, L'*')) return ContainsCI(text, pattern);   // non-glob = contains
    size_t tlen = wcslen(text), plen = wcslen(pattern);
    BOOL leadStar = (pattern[0] == L'*'), trailStar = (pattern[plen - 1] == L'*');
    const wchar_t* tpos = text; const wchar_t* p = pattern;
    BOOL firstPart = TRUE; const wchar_t* lastPtr = NULL; size_t lastLen = 0;
    while (*p)
    {
        if (*p == L'*') { p++; continue; }
        const wchar_t* e = p; while (*e && *e != L'*') e++;
        size_t len = (size_t)(e - p);
        const wchar_t* found = StrStrCI(tpos, p, len);
        if (!found) return FALSE;
        if (firstPart && !leadStar && found != text) return FALSE;   // must start with first part
        lastPtr = p; lastLen = len; tpos = found + len; firstPart = FALSE; p = e;
    }
    if (!trailStar && lastLen > 0)
        if (tlen < lastLen || _wcsnicmp(text + tlen - lastLen, lastPtr, lastLen) != 0) return FALSE;
    return TRUE;
}
static BOOL FTextMatch(const wchar_t* actual, const wchar_t* pattern)
{
    if (!pattern[0] || _wcsicmp(pattern, L"*") == 0 || _wcsicmp(pattern, L"All") == 0) return TRUE;
    return GlobMatch(actual, pattern);
}
static BOOL FilterEq(const wchar_t* field, const wchar_t* actual)   // combo fields (proto/action)
{
    return (!field[0] || _wcsicmp(field, L"All") == 0) ? TRUE : (_wcsicmp(field, actual) == 0);
}
static BOOL FilterRuleMatches(const PBFilter* f, const wchar_t* proc, const wchar_t* ip,
                              const wchar_t* port, const wchar_t* proto, const wchar_t* action)
{
    return FTextMatch(proc, f->proc) && FTextMatch(ip, f->ip) && FTextMatch(port, f->port) &&
           FilterEq(f->proto, proto) && FilterEq(f->action, action);
}
// Excludes run first (any match hides). Then includes: if any exist, at least one must match.
static BOOL PassesLogFilters(const wchar_t* proc, const wchar_t* ip, const wchar_t* port,
                             const wchar_t* proto, const wchar_t* action)
{
    if (g_fltCount == 0) return TRUE;
    for (int i = 0; i < g_fltCount; i++)
        if (_wcsicmp(g_flt[i].mode, L"Exclude") == 0 &&
            FilterRuleMatches(&g_flt[i], proc, ip, port, proto, action)) return FALSE;
    BOOL hasInc = FALSE;
    for (int i = 0; i < g_fltCount; i++)
        if (_wcsicmp(g_flt[i].mode, L"Include") == 0)
        { hasInc = TRUE; if (FilterRuleMatches(&g_flt[i], proc, ip, port, proto, action)) return TRUE; }
    return !hasInc;
}
static void ApplyFilterSnapshot(void)
{
    g_fltCount = g_profile.filterCount;
    for (int i = 0; i < g_fltCount; i++) g_flt[i] = g_profile.filter[i];
}
static void LogStoreAdd(LogStore* s, const wchar_t* line)
{
    wchar_t* copy = _wcsdup(line);
    if (!copy) return;
    if (s->count >= LOG_MAX_LINES)                  // drop the oldest to stay bounded
    {
        free(s->lines[0]);
        memmove(&s->lines[0], &s->lines[1], (LOG_MAX_LINES - 1) * sizeof(wchar_t*));
        s->count--;
    }
    s->lines[s->count++] = copy;
    if (LogLineMatches(s, line)) AppendToEdit(s->edit, line);
    // Auto Clear: once a log grows past the threshold, wipe it to keep memory bounded.
    if (g_autoClear && s->count > AUTO_CLEAR_LINES)
    {
        for (int i = 0; i < s->count; i++) free(s->lines[i]);
        s->count = 0;
        SetWindowTextW(s->edit, L"");
    }
}
static void LogStoreRebuild(LogStore* s)          // re-render the edit for the current filter
{
    SetWindowTextW(s->edit, L"");
    for (int i = 0; i < s->count; i++)
        if (LogLineMatches(s, s->lines[i])) AppendToEdit(s->edit, s->lines[i]);
}
static void LogStoreClear(LogStore* s)
{
    for (int i = 0; i < s->count; i++) free(s->lines[i]);
    s->count = 0;
    SetWindowTextW(s->edit, L"");
}

#endif // PB_UI_LOGVIEW_H
