// ui/update.h - update checker (startup + manual): reads a
// custom JSON feed. Notification offers Update Now / Later /
// Don't Ask Again. Unity-build include: pulled into main.c after the theme helpers and the
// globals it uses (g_hInst, g_hMain, g_reallyExit).
#ifndef PB_UI_UPDATE_H
#define PB_UI_UPDATE_H

#include <winhttp.h>
#include "../profile/json.h"
#pragma comment(lib, "winhttp.lib")

#define UPD_FEED_URL  L"https://download.interceptsuite.com/proxybridge.json"

#define WM_APP_UPDATE  (WM_APP + 6)   // check worker -> main window (result)
#define WM_APP_DLPROG  (WM_APP + 7)   // download worker -> dialog (percent)
#define WM_APP_DLDONE  (WM_APP + 8)   // download worker -> dialog (success + job)

typedef struct {
    BOOL    available;
    wchar_t latest[32];
    wchar_t download[512];
    wchar_t notes[512];
    wchar_t date[32];
} UpdInfo;

static void U8W(const char* s, wchar_t* out, int cch)
{
    MultiByteToWideChar(CP_UTF8, 0, s ? s : "", -1, out, cch);
}

// Parse the first three dot-separated integers, ignoring a leading 'v' and any suffix ("-Beta").
static void UpdParseVer(const wchar_t* s, int out[3])
{
    out[0] = out[1] = out[2] = 0;
    int i = 0;
    while (*s && (*s < L'0' || *s > L'9')) s++;   // skip 'v' / leading junk
    while (*s && i < 3)
    {
        if (*s >= L'0' && *s <= L'9') { int n = 0; while (*s >= L'0' && *s <= L'9') { n = n * 10 + (*s - L'0'); s++; } out[i++] = n; }
        else if (*s == L'.') s++;
        else break;                                // stop at '-Beta' etc.
    }
}
static int UpdVerCmp(const int a[3], const int b[3])
{
    for (int i = 0; i < 3; i++) if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return 0;
}

// Open a GET request and read the response headers. On success returns the request handle
// and hands back the session/connection handles for cleanup; NULL on any failure.
static HINTERNET UpdOpenGet(const wchar_t* url, HINTERNET* sOut, HINTERNET* cOut)
{
    *sOut = *cOut = NULL;
    URL_COMPONENTS uc; wchar_t host[256] = {0}, path[2048] = {0};
    ZeroMemory(&uc, sizeof(uc)); uc.dwStructSize = sizeof(uc);
    uc.lpszHostName = host; uc.dwHostNameLength = 255;
    uc.lpszUrlPath = path; uc.dwUrlPathLength = 2047;
    if (!WinHttpCrackUrl(url, 0, 0, &uc)) return NULL;
    BOOL https = (uc.nScheme == INTERNET_SCHEME_HTTPS);
    HINTERNET s = WinHttpOpen(L"ProxyBridge-UpdateChecker", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!s) return NULL;
    HINTERNET c = WinHttpConnect(s, host, uc.nPort, 0);
    if (!c) { WinHttpCloseHandle(s); return NULL; }
    HINTERNET r = WinHttpOpenRequest(c, L"GET", path, NULL, WINHTTP_NO_REFERER,
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, https ? WINHTTP_FLAG_SECURE : 0);
    if (!r ||
        !WinHttpSendRequest(r, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(r, NULL))
    {
        if (r) WinHttpCloseHandle(r);
        WinHttpCloseHandle(c); WinHttpCloseHandle(s);
        return NULL;
    }
    *sOut = s; *cOut = c;
    return r;
}
static void UpdCloseGet(HINTERNET s, HINTERNET c, HINTERNET r)
{
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
}

// GET a URL into a malloc'd NUL-terminated buffer (caller frees). Follows redirects.
static char* UpdHttpGet(const wchar_t* url, DWORD* outLen)
{
    HINTERNET s, c, r = UpdOpenGet(url, &s, &c);
    if (!r) return NULL;
    char* buf = NULL; DWORD cap = 0, len = 0, avail;
    for (;;)
    {
        if (!WinHttpQueryDataAvailable(r, &avail) || avail == 0) break;
        if (len + avail + 1 > cap)
        {
            DWORD ncap = (len + avail + 1) * 2;
            char* nb = (char*)realloc(buf, ncap);
            if (!nb) { free(buf); buf = NULL; break; }
            buf = nb; cap = ncap;
        }
        DWORD read = 0;
        if (!WinHttpReadData(r, buf + len, avail, &read) || read == 0) break;
        len += read;
    }
    if (buf) buf[len] = 0;
    UpdCloseGet(s, c, r);
    if (buf && outLen) *outLen = len;
    return buf;
}

// Download url -> dest file, posting percent to dlg via WM_APP_DLPROG.
static BOOL UpdDownload(const wchar_t* url, const wchar_t* dest, HWND dlg)
{
    HINTERNET s, c, r = UpdOpenGet(url, &s, &c);
    if (!r) return FALSE;
    BOOL ok = FALSE;
    DWORD total = 0, tsz = sizeof(total);
    WinHttpQueryHeaders(r, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &total, &tsz, WINHTTP_NO_HEADER_INDEX);
    HANDLE f = CreateFileW(dest, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE)
    {
        BYTE buf[16384]; DWORD got = 0, avail; ok = TRUE;
        for (;;)
        {
            if (!WinHttpQueryDataAvailable(r, &avail)) { ok = FALSE; break; }
            if (avail == 0) break;
            DWORD toread = avail > sizeof(buf) ? sizeof(buf) : avail, read = 0;
            if (!WinHttpReadData(r, buf, toread, &read) || read == 0) { ok = FALSE; break; }
            DWORD written; WriteFile(f, buf, read, &written, NULL);
            got += read;
            if (total > 0) PostMessageW(dlg, WM_APP_DLPROG, (WPARAM)((got * 100) / total), 0);
        }
        CloseHandle(f);
    }
    UpdCloseGet(s, c, r);
    return ok;
}

// Fetch + parse the feed. Fills *out; returns FALSE only on network/parse failure.
static BOOL UpdCheck(UpdInfo* out)
{
    ZeroMemory(out, sizeof(*out));
    DWORD len = 0;
    char* body = UpdHttpGet(UPD_FEED_URL, &len);
    if (!body) return FALSE;
    JVal* root = json_parse(body, len);
    free(body);
    if (!root) return FALSE;
    BOOL ok = FALSE;
    JVal* win = json_get(root, "windows");
    if (win)
    {
        const char* ver   = json_str(win, "version", NULL);
        const char* dl    = json_str(win, "download", NULL);
        const char* notes = json_str(win, "release_notes", NULL);
        const char* date  = json_str(win, "release_date", NULL);
        if (ver)   U8W(ver,   out->latest,   32);
        if (dl)    U8W(dl,     out->download, 512);
        if (notes) U8W(notes,  out->notes,    512);
        if (date)  U8W(date,   out->date,     32);
        int cur[3], lat[3];
        UpdParseVer(APP_VERSION, cur);
        UpdParseVer(out->latest, lat);
        out->available = (out->download[0] != 0) && (UpdVerCmp(lat, cur) > 0);
        ok = TRUE;
    }
    json_free(root);
    return ok;
}

// notification dialog
typedef struct { HWND dlg; wchar_t url[512]; wchar_t dest[MAX_PATH]; } UpdDl;
static DWORD WINAPI UpdDlThread(LPVOID p)
{
    UpdDl* d = (UpdDl*)p;
    BOOL ok = UpdDownload(d->url, d->dest, d->dlg);
    PostMessageW(d->dlg, WM_APP_DLDONE, (WPARAM)(ok ? 1 : 0), (LPARAM)d);   // handler frees d
    return 0;
}
INT_PTR CALLBACK UpdateDlgProc(HWND dlg, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_INITDIALOG:
    {
        SetWindowLongPtrW(dlg, GWLP_USERDATA, (LONG_PTR)lp);
        UpdInfo* info = (UpdInfo*)lp;
        SetWindowTextW(dlg, T(S_UPD_TITLE));
        SetDlgItemTextW(dlg, IDC_UP_TEXT, T(S_UPD_AVAIL));
        wchar_t v[160]; _snwprintf_s(v, 160, _TRUNCATE, L"%s  \x2192  %s", APP_VERSION, info->latest);
        SetDlgItemTextW(dlg, IDC_UP_VERS, v);
        if (info->date[0]) { wchar_t d[64]; _snwprintf_s(d, 64, _TRUNCATE, L"(%s)", info->date); SetDlgItemTextW(dlg, IDC_UP_DATE, d); }
        if (info->notes[0]) { wchar_t n[640]; _snwprintf_s(n, 640, _TRUNCATE, L"<a href=\"%s\">%s</a>", info->notes, T(S_UPD_NOTES)); SetDlgItemTextW(dlg, IDC_UP_NOTES, n); }
        else ShowWindow(GetDlgItem(dlg, IDC_UP_NOTES), SW_HIDE);
        SetDlgItemTextW(dlg, IDC_UP_NOW,     T(S_UPD_NOW));
        SetDlgItemTextW(dlg, IDCANCEL,       T(S_UPD_LATER));
        SetDlgItemTextW(dlg, IDC_UP_DONTASK, T(S_UPD_DONTASK));
        ShowWindow(GetDlgItem(dlg, IDC_UP_PROGRESS), SW_HIDE);
        InitDarkMode(dlg);
        return TRUE;
    }
    PB_DARK_CTLCOLORS;
    case WM_NOTIFY:
    {
        LPNMHDR nh = (LPNMHDR)lp;
        if ((nh->code == NM_CLICK || nh->code == NM_RETURN) && nh->idFrom == IDC_UP_NOTES)
        { PNMLINK link = (PNMLINK)lp; ShellExecuteW(dlg, L"open", link->item.szUrl, NULL, NULL, SW_SHOWNORMAL); }
        return TRUE;
    }
    case WM_APP_DLPROG:
        SendDlgItemMessageW(dlg, IDC_UP_PROGRESS, PBM_SETPOS, (WPARAM)wp, 0);
        return TRUE;
    case WM_APP_DLDONE:
    {
        UpdDl* d = (UpdDl*)lp;
        if (wp)   // success: launch the installer and quit so it can replace files
        {
            ShellExecuteW(dlg, L"open", d->dest, NULL, NULL, SW_SHOWNORMAL);
            free(d);
            g_reallyExit = TRUE;
            DestroyWindow(g_hMain);
            return TRUE;
        }
        SetDlgItemTextW(dlg, IDC_UP_STATUS, T(S_UPD_DLFAIL));
        EnableWindow(GetDlgItem(dlg, IDC_UP_NOW), TRUE);
        free(d);
        return TRUE;
    }
    case WM_COMMAND:
        switch (LOWORD(wp))
        {
        case IDC_UP_NOW:
        {
            UpdInfo* info = (UpdInfo*)GetWindowLongPtrW(dlg, GWLP_USERDATA);
            UpdDl* d = (UpdDl*)calloc(1, sizeof(UpdDl));
            if (!d) return TRUE;
            d->dlg = dlg; lstrcpynW(d->url, info->download, 512);
            const wchar_t* fn = info->download;
            for (const wchar_t* p = info->download; *p; p++) if (*p == L'/') fn = p + 1;
            wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);
            _snwprintf_s(d->dest, MAX_PATH, _TRUNCATE, L"%s%s", tmp, fn[0] ? fn : L"ProxyBridge-Setup.exe");
            EnableWindow(GetDlgItem(dlg, IDC_UP_NOW), FALSE);
            ShowWindow(GetDlgItem(dlg, IDC_UP_PROGRESS), SW_SHOW);
            SendDlgItemMessageW(dlg, IDC_UP_PROGRESS, PBM_SETRANGE, 0, MAKELPARAM(0, 100));
            SetDlgItemTextW(dlg, IDC_UP_STATUS, T(S_UPD_DLING));
            HANDLE t = CreateThread(NULL, 0, UpdDlThread, d, 0, NULL);
            if (t) CloseHandle(t); else { free(d); EnableWindow(GetDlgItem(dlg, IDC_UP_NOW), TRUE); }
            return TRUE;
        }
        case IDC_UP_DONTASK: PB_SetCheckUpdates(FALSE); EndDialog(dlg, 0); return TRUE;
        case IDCANCEL:       EndDialog(dlg, 0); return TRUE;
        }
        return FALSE;
    }
    return FALSE;
}

// orchestration
typedef struct { HWND owner; BOOL manual; } UpdJob;
static DWORD WINAPI UpdCheckThread(LPVOID p)
{
    UpdJob* j = (UpdJob*)p;
    UpdInfo* info = (UpdInfo*)malloc(sizeof(UpdInfo));
    BOOL ok = FALSE;
    if (info) { ok = UpdCheck(info); if (!ok) ZeroMemory(info, sizeof(*info)); }
    WPARAM flags = (ok ? 1u : 0u) | (j->manual ? 2u : 0u);
    PostMessageW(j->owner, WM_APP_UPDATE, flags, (LPARAM)info);
    free(j);
    return 0;
}
// Kick off a check on a worker thread. manual=TRUE also reports "up to date" / errors.
static void UpdStartCheck(HWND owner, BOOL manual)
{
    UpdJob* j = (UpdJob*)calloc(1, sizeof(UpdJob));
    if (!j) return;
    j->owner = owner; j->manual = manual;
    HANDLE t = CreateThread(NULL, 0, UpdCheckThread, j, 0, NULL);
    if (t) CloseHandle(t); else free(j);
}

#endif // PB_UI_UPDATE_H
