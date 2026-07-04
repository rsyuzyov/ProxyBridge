// ui/theme.h - dark-theme helpers for the GUI.
//
// Unity-build include: pulled into main.c after the colour macros (C_*), brush globals
// (g_br*), the UAH menu structs and the uxtheme ordinal typedefs are declared, so this
// file relies on those already being visible. Not a standalone header.
#ifndef PB_UI_THEME_H
#define PB_UI_THEME_H

static void CreateDarkBrushes(void)
{
    g_brBg     = CreateSolidBrush(C_BG);
    g_brPanel  = CreateSolidBrush(C_PANEL);
    g_brTab    = CreateSolidBrush(C_TAB);
    g_brTabSel = CreateSolidBrush(C_TABSEL);
    g_brTabHot = CreateSolidBrush(C_TABHOT);
    g_brAccent = CreateSolidBrush(C_ACCENT);
    g_brMenu   = CreateSolidBrush(C_MENU);
    g_brMenuHot= CreateSolidBrush(C_MENUHOT);
}

// Group boxes (BS_GROUPBOX) draw their own caption; the themed button keeps it black on
// dark. Owner-paint the frame + caption in light so they match the rest of the dialog.
static LRESULT CALLBACK GroupSubProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR ref)
{
    (void)id; (void)ref;
    if (m == WM_PAINT)
    {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        wchar_t txt[64] = {0}; GetWindowTextW(h, txt, 64);
        FillRect(dc, &rc, g_brBg);
        HFONT f = (HFONT)SendMessageW(h, WM_GETFONT, 0, 0);
        HFONT of = f ? (HFONT)SelectObject(dc, f) : NULL;
        SIZE ts; GetTextExtentPoint32W(dc, txt, lstrlenW(txt), &ts);
        HPEN pen = CreatePen(PS_SOLID, 1, C_LINE), op = (HPEN)SelectObject(dc, pen);
        HBRUSH ob = (HBRUSH)SelectObject(dc, GetStockObject(NULL_BRUSH));
        RoundRect(dc, rc.left, rc.top + ts.cy / 2, rc.right - 1, rc.bottom - 1, 6, 6);
        SelectObject(dc, ob); SelectObject(dc, op); DeleteObject(pen);
        RECT tr = { rc.left + 8, rc.top, rc.left + 14 + ts.cx, rc.top + ts.cy };
        FillRect(dc, &tr, g_brBg);                       // break the frame line behind the caption
        SetBkMode(dc, TRANSPARENT); SetTextColor(dc, C_TEXT);
        TextOutW(dc, rc.left + 11, rc.top, txt, lstrlenW(txt));
        if (of) SelectObject(dc, of);
        EndPaint(h, &ps);
        return 0;
    }
    return DefSubclassProc(h, m, w, l);
}

// Apply the matching dark theme to a child control by class. Immersive dark mode only
// themes the top-level window; edits/combos/buttons stay light until themed individually.
static BOOL CALLBACK DarkThemeChild(HWND h, LPARAM lp)
{
    (void)lp;
    wchar_t cls[48]; GetClassNameW(h, cls, 48);
    if (!_wcsicmp(cls, L"Edit") || !_wcsicmp(cls, L"ComboBox"))
        SetWindowTheme(h, L"DarkMode_CFD", NULL);          // dark edit/combo field
    else if (!_wcsicmp(cls, L"Button"))
    {
        if ((GetWindowLongW(h, GWL_STYLE) & BS_TYPEMASK) == BS_GROUPBOX)
            SetWindowSubclass(h, GroupSubProc, 7, 0);      // owner-paint the caption/frame
        else
            SetWindowTheme(h, L"DarkMode_Explorer", NULL);
    }
    else if (!_wcsicmp(cls, L"ListBox"))
        SetWindowTheme(h, L"DarkMode_Explorer", NULL);
    else if (!_wcsicmp(cls, L"SysListView32") || !_wcsicmp(cls, WC_TABCONTROLW))
        SetWindowTheme(h, L"DarkMode_Explorer", NULL);
    return TRUE;
}

static void InitDarkMode(HWND hwnd)
{
    // Enable the OS immersive dark mode so popup menus, scrollbars and combo dropdowns
    // render dark (undocumented uxtheme ordinals - stable on Win10 1903+ / Win11).
    HMODULE ux = LoadLibraryExW(L"uxtheme.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (ux)
    {
        fnSetPreferredAppMode setMode = (fnSetPreferredAppMode)(void*)GetProcAddress(ux, MAKEINTRESOURCEA(135));
        fnAllowDarkModeForWindow allow = (fnAllowDarkModeForWindow)(void*)GetProcAddress(ux, MAKEINTRESOURCEA(133));
        fnFlushMenuThemes flush = (fnFlushMenuThemes)(void*)GetProcAddress(ux, MAKEINTRESOURCEA(136));
        if (setMode) setMode(APPMODE_FORCEDARK);
        if (allow)   allow(hwnd, TRUE);
        if (flush)   flush();
        FreeLibrary(ux);   // ordinals were called; release our loader ref (called per dialog)
    }
    BOOL dark = TRUE;
    DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &dark, sizeof(dark));
    // Theme every child control so edits/combos/buttons aren't left glaring white.
    EnumChildWindows(hwnd, DarkThemeChild, 0);
}

// Paint over the light 1px line the OS draws under the menu bar.
static void PaintMenuBottomLine(HWND hwnd)
{
    MENUBARINFO mbi; mbi.cbSize = sizeof(mbi);
    if (!GetMenuBarInfo(hwnd, OBJID_MENU, 0, &mbi)) return;
    RECT wr; GetWindowRect(hwnd, &wr);
    RECT r = mbi.rcBar; OffsetRect(&r, -wr.left, -wr.top);
    r.top = r.bottom; r.bottom += 1;
    HDC dc = GetWindowDC(hwnd);
    FillRect(dc, &r, g_brMenu);
    ReleaseDC(hwnd, dc);
}

// Shared dark colouring for dialog controls (dialog procs return the brush directly).
static INT_PTR DlgCtlColor(WPARAM wp)
{
    HDC dc = (HDC)wp;
    SetTextColor(dc, C_TEXT);
    SetBkColor(dc, C_BG);
    return (INT_PTR)g_brBg;
}

// Drop-in dark handling for every WM_CTLCOLOR* a dialog gets. Use inside a dialog proc's
// switch for the common case; dialogs that need per-control colours handle them explicitly.
#define PB_DARK_CTLCOLORS                                                    \
    case WM_CTLCOLORDLG: case WM_CTLCOLOREDIT: case WM_CTLCOLORLISTBOX:      \
    case WM_CTLCOLORBTN: case WM_CTLCOLORSTATIC: return DlgCtlColor(wp)

// Subclass the tab control: dark background fill + hovered-tab tracking (owner-draw needs it).
static LRESULT CALLBACK TabSubProc(HWND h, UINT m, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR ref)
{
    (void)id; (void)ref;
    switch (m)
    {
    case WM_ERASEBKGND:
    {
        RECT rc; GetClientRect(h, &rc);
        FillRect((HDC)w, &rc, g_brPanel);
        return 1;
    }
    case WM_MOUSEMOVE:
    {
        TCHITTESTINFO ht; ht.pt.x = GET_X_LPARAM(l); ht.pt.y = GET_Y_LPARAM(l); ht.flags = 0;
        int hit = TabCtrl_HitTest(h, &ht);
        if (hit != g_tabHot)
        {
            g_tabHot = hit;
            InvalidateRect(h, NULL, FALSE);
            TRACKMOUSEEVENT tme = { sizeof(tme), TME_LEAVE, h, 0 };
            TrackMouseEvent(&tme);
        }
        break;
    }
    case WM_MOUSELEAVE:
        if (g_tabHot != -1) { g_tabHot = -1; InvalidateRect(h, NULL, FALSE); }
        break;
    }
    return DefSubclassProc(h, m, w, l);
}

#endif // PB_UI_THEME_H
