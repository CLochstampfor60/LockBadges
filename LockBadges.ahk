#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; =====================================================================
;  LockBadges - movable, translucent lock-key indicators for Windows
;
;  Copyright (c) 2026 Carl Lochstampfor
;  Released under the MIT License.
;  https://github.com/CLochstampfor60/LockBadges
;
;  For keyboards with no lock-key indicator lights. Caps Lock, Num Lock
;  and Scroll Lock each get an independent, movable, translucent badge.
;
;  Fn Lock is deliberately not supported. It is handled by the keyboard's
;  embedded controller, which must work before any OS loads (Fn+F2 for
;  setup, brightness during POST), so it never reaches Windows and no API
;  reports it. It also changes what the F-row does rather than what you
;  type, so a wrong guess is self-correcting. Do not add a badge for it.
;
;  Tray icon (left-click) or Ctrl+Alt+Shift+C opens Settings.
;  Config: %APPDATA%\LockBadges\config.ini, one section per key.
;
;  ------------------------------------------------------------------
;  SECURITY DESIGN CONSTRAINTS - do not relax these without thought
;  ------------------------------------------------------------------
;  This program watches lock-key STATE. It must never observe content.
;
;   * No keyboard hook. State is read with GetKeyState(..., "T"), which
;     asks Windows for a toggle bit. Keystrokes are never intercepted,
;     buffered or seen. There is no hook to leak, subvert or reorder.
;   * Nothing inside another process is inspected. No control handles,
;     no control styles, no control text. An earlier build detected
;     password fields by reading the focused control's style bits; it
;     was removed because browsers and modern apps already warn about
;     caps lock, and no feature is worth reaching into other windows.
;   * Never call ControlGetText / ControlGetFocus / EditGetLine, and
;     never read window titles - titles leak document names and URLs.
;     The only foreign-window data used is the foreground window's
;     class, style and rectangle, solely to spot fullscreen apps.
;   * No file logging of any kind. A debug log that records window
;     classes or focus changes becomes a behavioral record of the
;     user's session. If you must debug, log booleans.
;   * No network access, no telemetry, no update check.
;  ------------------------------------------------------------------
; =====================================================================

; Block the AutoHotkey main window (variable/line inspection UI).
; Defense in depth only - the source is plain text and readable anyway.
A_AllowMainWindow := false

APP_NAME := "LockBadges"
APP_VER := "v1.6.1"
APP_AUTHOR := "Carl Lochstampfor"
APP_REPO := "github.com/CLochstampfor60/LockBadges"
APP_LICENSE := "MIT License"

CfgDir := A_AppData "\LockBadges"
if !DirExist(CfgDir)
    DirCreate(CfgDir)
IniFile := CfgDir "\config.ini"
; Carry settings over from the old CapsBadge name, once.
OldIni := A_AppData "\CapsBadge\config.ini"
if (!FileExist(IniFile) && FileExist(OldIni))
    try FileCopy(OldIni, IniFile)

LinkPath := A_Startup "\LockBadges.lnk"
OldLink := A_Startup "\CapsBadge.lnk"

Keys := ["Caps", "Num", "Scroll", "Mute"]
KeyVK := Map("Caps", "CapsLock", "Num", "NumLock", "Scroll", "ScrollLock")
KeyNice := Map("Caps", "Caps Lock", "Num", "Num Lock", "Scroll", "Scroll Lock"
             , "Mute", "Mute")

Ctl := Map()          ; settings controls, nested per key
SG := ""              ; settings Gui
St := Map()           ; runtime state per key
DragMode := false
DragKey := ""
PreviewMode := false
Resizing := false
Dirty := false
LastKeyTab := "Caps"
RszX := 0, RszY := 0, RszW := 96, RszH := 30
PollTick := 0
LastCueTick := 0
Suppressed := false
FollowMon := 0

; Preview panel geometry
PVX := 397
PVY_ON := 86
PVY_OFF := 204
CANVAS_W := 300
CAP_H_ON := 110
CAP_H_OFF := 74

Backdrops := Map("Light page", "FFFFFF", "Dark editor", "1F1F1F"
               , "Mid gray", "808080", "Web page gray", "D9D9D9")
BackdropNames := ["Light page", "Dark editor", "Mid gray", "Web page gray"]

FontList := ["Segoe UI", "Segoe UI Semibold", "Segoe UI Black", "Bahnschrift"
    , "Arial", "Arial Black", "Calibri", "Cambria", "Candara", "Cascadia Mono"
    , "Consolas", "Constantia", "Corbel", "Courier New", "Ebrima"
    , "Franklin Gothic Medium", "Gabriola", "Georgia", "Impact"
    , "Lucida Console", "Lucida Sans Unicode", "Microsoft Sans Serif"
    , "Palatino Linotype", "Segoe Print", "Segoe Script", "Sitka Text"
    , "Tahoma", "Times New Roman", "Trebuchet MS", "Verdana"]

Palette := [
    ["FFFFFF","F2F2F2","D9D9D9","BFBFBF","A6A6A6","808080","595959","404040","262626","000000"],
    ["FFF6E0","FFE599","FFD966","FFC24B","E8A33D","D2691E","FF8A5B","E03131","B02A2A","7A1F1F"],
    ["EAF7EE","C6EFCE","9BE29B","4BD4A0","2FA36B","19692C","E6F2FF","8CC8FF","3B9EFF","1552B0"],
    ["F6EEFF","D9B8FF","B07CFF","8B44FF","5B21B6","FFE1EF","FF9CC8","F062A6","C2185B","7A0F3D"]]

; Sound cue options. "*N" specs are Windows system sounds played through
; SoundPlay, which is asynchronous and respects the user's sound scheme and
; mute state. Synthesized tones (SoundBeep/Beep) are deliberately not used:
; they block the single AHK thread and would stall the fade animation.
SoundChoices := ["None", "System beep", "Information", "Warning", "Question"
    , "Error", "Custom WAV file..."]
SoundSpecs := ["", "*-1", "*64", "*48", "*32", "*16"]

Presets := Map(
    "Small",  [72, 24, 9],
    "Medium", [96, 30, 11],
    "Large",  [132, 40, 15],
    "XL",     [184, 54, 21])

LoadCfg()
InitState()
for i, k in Keys {
    if (Cfg[k]["x"] = -1)
        ResetPosition(k, i - 1)
}

; --- tray menu -------------------------------------------------------
A_TrayMenu.Delete()
A_TrayMenu.Add("Settings", (*) => ShowSettings())
A_TrayMenu.Add("Test all badges", (*) => TestAll())
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", (*) => ExitApp())
A_TrayMenu.Default := "Settings"
A_TrayMenu.ClickCount := 1
A_IconTip := APP_NAME " " APP_VER

OnMessage(0x201, OnLButtonDown)

for k in Keys
    St[k]["last"] := ReadLockState(k)
for k in Keys {
    if (Cfg[k]["enabled"] && St[k]["last"] && Cfg[k]["mode"] = "persistent")
        ShowBadge(k, 1)
}
LayoutVisible()
SetTimer(Poll, 100)

^!+C::ShowSettings()

; =====================================================================
;  CONFIG
; =====================================================================
DefaultsFor(k) {
    d := Map(
        "enabled",   1,
        "labelOn",   "CAPS ON",
        "labelOff",  "caps off",
        "font",      "Segoe UI",
        "bold",      1,
        "italic",    0,
        "notifyOff", 1,
        "mode",      "flash",
        "duration",  900,
        "w",         96,
        "h",         30,
        "fontSize",  11,
        "scaleFont", 1,
        "soundOn",   "",          ; "" = silent, "*N" = system sound, or a path
        "soundOff",  "",
        "bg",        "1B1B1B",
        "fgOn",      "FFC24B",
        "fgOff",     "8A8A8A",
        "alpha",     205,
        "ghost",     0,
        "round",     1,
        "x",         -1,
        "y",         -1)
    if (k = "Num") {
        d["labelOn"] := "NUM ON"
        d["labelOff"] := "num off"
        d["fgOn"] := "4BD4A0"
    } else if (k = "Mute") {
        d["labelOn"] := "MUTED"
        d["labelOff"] := "sound on"
        d["fgOn"] := "FF5B5B"
        d["mode"] := "persistent"    ; a mute state you cannot see is the point
    } else if (k = "Scroll") {
        d["labelOn"] := "SCROLL ON"
        d["labelOff"] := "scroll off"
        d["fgOn"] := "8CC8FF"
        d["enabled"] := 0        ; rarely wanted, off until asked for
    }
    return d
}

LoadCfg() {
    global Cfg, Gcfg, Keys, IniFile
    Cfg := Map()
    for k in Keys {
        m := Map()
        for kk, vv in DefaultsFor(k)
            m[kk] := IniRead(IniFile, k, kk, vv)
        Cfg[k] := m
    }
    Gcfg := Map()
    for kk, vv in Map("backdrop", "Light page", "stack", "Off", "gap", 8
                    , "follow", 0, "hideFullscreen", 1, "noCapture", 0
                    , "previewAll", 1, "anchor", "Caps"
                    , "soundInFullscreen", 1)
        Gcfg[kk] := IniRead(IniFile, "General", kk, vv)
}

SaveCfg() {
    global Cfg, Gcfg, Keys, IniFile
    for k in Keys {
        for kk, vv in Cfg[k]
            IniWrite(vv, IniFile, k, kk)
    }
    for kk, vv in Gcfg
        IniWrite(vv, IniFile, "General", kk)
}

InitState() {
    global St, Keys
    St := Map()
    for k in Keys {
        St[k] := Map(
            "gui", "", "txt", "", "cur", 0, "dir", 0, "last", 0,
            "shown", false,
            "fadeFn", FadeStep.Bind(k),      ; one bound copy per key, so
            "hideFn", FadeOutNow.Bind(k))    ; SetTimer can cancel it later
    }
}

; Staggered defaults so two badges never land on top of each other.
ResetPosition(k, slot) {
    global Cfg
    ; MonitorGetWorkArea, NOT MonitorGet: the work area excludes the taskbar,
    ; so a reset never parks a badge underneath it. Note that
    ; IsFullscreenActive() deliberately makes the opposite choice - see the
    ; comment there. The two functions want different rectangles, and neither
    ; call is a mistake.
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    hh := SafeNum(Cfg[k]["h"], 12, 600, 30)
    Cfg[k]["x"] := r - SafeNum(Cfg[k]["w"], 20, 2000, 96) - 28
    Cfg[k]["y"] := t + (b - t) // 2 - hh // 2 + slot * (hh + 8)
}

KeyIndex(k) {
    global Keys
    for i, v in Keys {
        if (v = k)
            return i
    }
    return 1
}

; Not every badge reads a keyboard toggle. Caps, Num and Scroll are keyboard
; toggle bits; Mute is a property of the Windows audio endpoint, which the
; volume keys, the flyout, and any app can change. One reader keeps the poll
; loop from caring which is which.
ReadLockState(k) {
    global KeyVK
    if (k = "Mute") {
        try
            return SoundGetMute() ? 1 : 0
        catch
            return 0            ; no audio endpoint available
    }
    return GetKeyState(KeyVK[k], "T") ? 1 : 0
}

; --- guards, because live preview reads half-typed values -------------
SafeHex(v, fallback) {
    v := StrReplace(StrReplace(v, "#"), " ")
    return RegExMatch(v, "^[0-9a-fA-F]{6}$") ? v : fallback
}

SafeNum(v, lo, hi, def) {
    if !IsNumber(v)
        return def
    n := Integer(v)
    return (n < lo) ? lo : (n > hi) ? hi : n
}

SafeFont(v) {
    return Trim(v) = "" ? "Segoe UI" : Trim(v)
}

FontStyleStr(k, colorHex) {
    global Cfg
    s := "norm s" SafeNum(Cfg[k]["fontSize"], 6, 72, 11)
    if (Cfg[k]["bold"])
        s .= " Bold"
    if (Cfg[k]["italic"])
        s .= " Italic"
    return s " c" colorHex
}

; Alpha-composite fg over bg: the same maths Windows applies to a layered
; window, so a blended flat color is an honest preview.
Blend(fgHex, bgHex, alpha) {
    f := Integer("0x" SafeHex(fgHex, "FFFFFF"))
    b := Integer("0x" SafeHex(bgHex, "FFFFFF"))
    a := SafeNum(alpha, 0, 255, 255) / 255
    r := Round(((f >> 16) & 0xFF) * a + ((b >> 16) & 0xFF) * (1 - a))
    g := Round(((f >> 8) & 0xFF) * a + ((b >> 8) & 0xFF) * (1 - a))
    bl := Round((f & 0xFF) * a + (b & 0xFF) * (1 - a))
    return Format("{:02X}{:02X}{:02X}", r, g, bl)
}

; =====================================================================
;  MONITORS
; =====================================================================
MonitorIndexAt(x, y) {
    n := MonitorGetCount()
    loop n {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return A_Index
    }
    return MonitorGetPrimary()
}

ActiveMonitorIndex() {
    try {
        hwnd := WinExist("A")
        if (hwnd) {
            WinGetPos(&wx, &wy, &ww, &wh, hwnd)
            if (ww > 0 && wh > 0)
                return MonitorIndexAt(wx + ww // 2, wy + wh // 2)
        }
    }
    return MonitorGetPrimary()
}

; Where a badge should actually appear. With "follow" off this is simply the
; saved position. With it on, the saved position's offset within its own
; monitor is re-applied to the monitor holding the focused window.
EffectivePos(k, &px, &py) {
    global Cfg, Gcfg
    bw := SafeNum(Cfg[k]["w"], 20, 2000, 96)
    bh := SafeNum(Cfg[k]["h"], 12, 600, 30)
    px := SafeNum(Cfg[k]["x"], -20000, 20000, 100)
    py := SafeNum(Cfg[k]["y"], -20000, 20000, 100)
    if !Gcfg["follow"]
        return
    src := MonitorIndexAt(px + bw // 2, py + bh // 2)
    tgt := ActiveMonitorIndex()
    if (src = tgt)
        return
    MonitorGet(src, &sl, &st, &sr, &sb)
    MonitorGet(tgt, &tl, &tt, &tr, &tb)
    nx := tl + (px - sl)
    ny := tt + (py - st)
    ; Monitors differ in size, so keep the badge inside the target.
    if (nx + bw > tr)
        nx := tr - bw
    if (ny + bh > tb)
        ny := tb - bh
    px := (nx < tl) ? tl : nx
    py := (ny < tt) ? tt : ny
}

; A borderless window covering an entire monitor: games, video, slideshows.
; Windows exposes no "is this window fullscreen?" API, so infer it from two
; tests: no title bar, and covering the monitor's ENTIRE bounds.
;
; The second test is the load-bearing one. Windows reports two rectangles per
; monitor:
;
;   work area      - the usable region, EXCLUDING the taskbar
;   monitor bounds - the whole screen, INCLUDING the taskbar's strip
;
; A maximized window fills the work area and stops above the taskbar. A
; fullscreen window covers the full bounds and paints over it. Comparing
; against bounds is therefore what separates "maximized Chrome" from "game in
; fullscreen"; comparing against the work area would fire on every maximized
; window and hide the badges constantly.
;
; It also means borderless-windowed mode - what most modern games actually use
; - is caught with no special handling, because borderless is a caption-less
; popup sized exactly to monitor bounds and so satisfies both tests.
IsFullscreenActive() {
    try {
        hwnd := WinExist("A")
        if !hwnd
            return false
        cls := WinGetClass(hwnd)
        ; The desktop and shell would otherwise qualify as fullscreen.
        if (cls = "WorkerW" || cls = "Progman" || cls = "Shell_TrayWnd")
            return false
        style := WinGetStyle(hwnd)
        if (style & 0xC00000)          ; WS_CAPTION: an ordinary window
            return false
        WinGetPos(&wx, &wy, &ww, &wh, hwnd)
        if (ww < 200 || wh < 200)      ; splash screens, tooltips, slivers
            return false
        ; Resolve the monitor from the window's center, not the primary
        ; display, so a fullscreen game on a second screen is detected.
        mi := MonitorIndexAt(wx + ww // 2, wy + wh // 2)
        MonitorGet(mi, &ml, &mt, &mr, &mb)      ; full bounds, not work area
        if (wx <= ml && wy <= mt && ww >= (mr - ml) && wh >= (mb - mt))
            return true
    }
    return false
}

; =====================================================================
;  SOUND CUES
; =====================================================================
; Returns true if something was actually played, so callers can tell the
; difference between "silent by choice" and "silently broken".
PlayCue(spec) {
    global LastCueTick
    if (spec = "")
        return false
    ; Two locks toggling together would otherwise talk over each other.
    if (A_TickCount - LastCueTick < 120)
        return true
    LastCueTick := A_TickCount

    if (SubStr(spec, 1, 1) = "*") {
        ; MessageBeep directly rather than SoundPlay: it is documented,
        ; asynchronous, and honors the user's sound scheme. Codes match
        ; MB_ICONHAND 0x10, QUESTION 0x20, EXCLAMATION 0x30, ASTERISK 0x40,
        ; and 0xFFFFFFFF for the plain default beep.
        n := SubStr(spec, 2)
        code := (n = "-1") ? 0xFFFFFFFF : SafeNum(n, 0, 255, 0x40)
        try {
            if (DllCall("user32\MessageBeep", "uint", code))
                return true
        }
        ; Sound scheme set to "No Sounds" swallows MessageBeep, so fall back
        ; to a short synthesized tone. Blocking, but only on this path.
        try {
            DllCall("Beep", "uint", 800, "uint", 90)
            return true
        }
        return false
    }

    if !FileExist(spec)
        return false
    try {
        SoundPlay(spec)
        return true
    }
    return false
}

; The Play button must never look broken: report why nothing was heard.
AuditionCue(spec) {
    global LastCueTick
    LastCueTick := 0                      ; bypass the rate limit for auditions
    if (spec = "") {
        ToolTip("No sound selected for this state. Pick one from the list.")
        SetTimer(() => ToolTip(), -2500)
        return
    }
    if (!PlayCue(spec)) {
        ToolTip("Could not play it. If this is a system sound, check"
              . "`nSettings > System > Sound > More sound settings > Sounds,"
              . "`nand that the scheme is not set to No Sounds.")
        SetTimer(() => ToolTip(), -5000)
    }
}

SoundIndexFromSpec(spec) {
    global SoundSpecs
    if (spec = "")
        return 1
    for i, v in SoundSpecs {
        if (v != "" && v = spec)
            return i
    }
    return 7                          ; a file path
}

SpecFromSoundIndex(idx) {
    global SoundSpecs
    return (idx >= 1 && idx <= 6) ? SoundSpecs[idx] : ""
}

; =====================================================================
;  THE BADGES
; =====================================================================
BuildBadge(k, on) {
    global Cfg, St
    if IsObject(St[k]["gui"])
        try St[k]["gui"].Destroy()

    bw := SafeNum(Cfg[k]["w"], 20, 2000, 96)
    bh := SafeNum(Cfg[k]["h"], 12, 600, 30)
    bg := SafeHex(Cfg[k]["bg"], "1B1B1B")
    col := on ? SafeHex(Cfg[k]["fgOn"], "FFC24B")
              : SafeHex(Cfg[k]["fgOff"], "8A8A8A")
    EffectivePos(k, &px, &py)

    ; +E0x20 is WS_EX_TRANSPARENT: clicks pass through, so a badge can
    ; never block or steal what you are clicking on underneath it.
    g := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x20")
    g.BackColor := bg
    g.MarginX := 0
    g.MarginY := 0
    g.SetFont(FontStyleStr(k, col), SafeFont(Cfg[k]["font"]))
    ; 0x200 = vertical center, 0x100 = SS_NOTIFY so drag mode sees clicks
    t := g.Add("Text", "w" bw " h" bh " Center 0x200 0x100"
             , on ? Cfg[k]["labelOn"] : Cfg[k]["labelOff"])
    g.Show("x" px " y" py " w" bw " h" bh " NoActivate Hide")

    if (Cfg[k]["round"])   ; DWMWA_WINDOW_CORNER_PREFERENCE = 33, ROUND = 2
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd
                  , "uint", 33, "int*", 2, "uint", 4)

    St[k]["gui"] := g
    St[k]["txt"] := t
    ApplyCaptureProtection(g.Hwnd)
    ApplyAlpha(k, 0)
}

; WDA_EXCLUDEFROMCAPTURE (0x11), Windows 10 2004 and later. The window stays
; visible to you but is omitted from screen captures, recordings and shares.
; Fails harmlessly on older builds.
ApplyCaptureProtection(hwnd) {
    global Gcfg
    if !Gcfg["noCapture"]
        return
    try DllCall("SetWindowDisplayAffinity", "ptr", hwnd, "uint", 0x11)
}

ShowBadge(k, on) {
    global Cfg, St
    StopTimers(k)
    St[k]["cur"] := 0
    BuildBadge(k, on)
    St[k]["gui"].Show("NoActivate")
    St[k]["shown"] := true
    LayoutVisible()
    BeginFade(k, 1)
    if (Cfg[k]["mode"] = "flash" || !on)
        SetTimer(St[k]["hideFn"]
               , -(SafeNum(Cfg[k]["duration"], 100, 60000, 900) + 150))
}

HideNow(k) {
    global St
    StopTimers(k)
    St[k]["cur"] := 0
    St[k]["shown"] := false
    if IsObject(St[k]["gui"])
        try St[k]["gui"].Hide()
    LayoutVisible()
}

StopTimers(k) {
    global St
    SetTimer(St[k]["fadeFn"], 0)
    SetTimer(St[k]["hideFn"], 0)
}

FadeOutNow(k) {
    BeginFade(k, -1)
}

BeginFade(k, dir) {
    global St
    St[k]["dir"] := dir
    SetTimer(St[k]["fadeFn"], 15)
}

FadeStep(k) {
    global Cfg, St
    target := SafeNum(Cfg[k]["alpha"], 20, 255, 205)
    St[k]["cur"] += St[k]["dir"] * 22
    if (St[k]["dir"] > 0 && St[k]["cur"] >= target) {
        St[k]["cur"] := target
        SetTimer(St[k]["fadeFn"], 0)
    } else if (St[k]["dir"] < 0 && St[k]["cur"] <= 0) {
        SetTimer(St[k]["fadeFn"], 0)
        HideNow(k)
        return
    }
    ApplyAlpha(k, St[k]["cur"])
}

; Two flavors of see-through:
;   normal - the whole box is translucent, text included
;   ghost  - the background color is keyed out, leaving only the text
ApplyAlpha(k, a) {
    global Cfg, St
    if !IsObject(St[k]["gui"])
        return
    try {
        if (Cfg[k]["ghost"])
            WinSetTransColor(SafeHex(Cfg[k]["bg"], "1B1B1B") " " a
                           , St[k]["gui"])
        else
            WinSetTransparent(a, St[k]["gui"])
    }
}

; Old configs stored this as 0/1; normalize whatever is on disk.
AnchorKey() {
    global Gcfg, Keys
    a := Gcfg.Has("anchor") ? Gcfg["anchor"] : "Caps"
    for k in Keys {
        if (k = a)
            return a
    }
    return "Caps"
}

StackMode() {
    global Gcfg
    v := Gcfg["stack"]
    if (v = "Horizontal")
        return "Horizontal"
    if (v = "Vertical" || v = 1)
        return "Vertical"
    return "Off"
}

; When stacking is on, visible badges are laid out from the anchor badge's
; saved position, anchor first, so they never collide. Every other badge's
; own saved position is deliberately ignored while this is active.
LayoutVisible() {
    global Cfg, Gcfg, St, Keys, DragMode
    mode := StackMode()
    ; Re-anchoring mid-drag would yank the badge out from under the mouse.
    if (mode = "Off" || DragMode)
        return
    anchor := AnchorKey()
    EffectivePos(anchor, &ax, &ay)
    gap := SafeNum(Gcfg["gap"], 0, 200, 8)
    ; The anchor sits at the saved spot; everyone else queues off it.
    order := [anchor]
    for k in Keys {
        if (k != anchor)
            order.Push(k)
    }
    for k in order {
        if !St[k]["shown"]
            continue
        try St[k]["gui"].Move(ax, ay)
        if (mode = "Horizontal")
            ax += SafeNum(Cfg[k]["w"], 20, 2000, 96) + gap
        else
            ay += SafeNum(Cfg[k]["h"], 12, 600, 30) + gap
    }
}

; =====================================================================
;  STATE POLLING
; =====================================================================
Poll() {
    global Cfg, Gcfg, Keys, KeyVK, St, DragMode, PreviewMode, Resizing
    global PollTick, Suppressed, FollowMon
    if (DragMode || PreviewMode || Resizing)
        return

    PollTick++

    ; --- fullscreen suppression (checked twice a second) ---
    if (Mod(PollTick, 5) = 0) {
        wantSuppress := Gcfg["hideFullscreen"] && IsFullscreenActive()
        if (wantSuppress && !Suppressed) {
            Suppressed := true
            for k in Keys {
                St[k]["last"] := ReadLockState(k)
                if St[k]["shown"]
                    HideNow(k)
            }
        } else if (!wantSuppress && Suppressed) {
            Suppressed := false
            for k in Keys {
                St[k]["last"] := ReadLockState(k)
                if (Cfg[k]["enabled"] && St[k]["last"]
                    && Cfg[k]["mode"] = "persistent")
                    ShowBadge(k, 1)
            }
            LayoutVisible()
        }
    }
    if (Suppressed) {
        ; Keep tracking state so nothing flashes on the way out. Sound is the
        ; only channel left while badges are hidden, which is precisely when
        ; it matters most - full-screen games.
        for k in Keys {
            on := ReadLockState(k)
            if (on = St[k]["last"])
                continue
            St[k]["last"] := on
            if (Gcfg["soundInFullscreen"] && Cfg[k]["enabled"])
                PlayCue(on ? Cfg[k]["soundOn"] : Cfg[k]["soundOff"])
        }
        return
    }

    ; --- watchdog: keep persistent badges alive ---
    ; This loop only reacts to state CHANGES, so a badge meant to sit there
    ; indefinitely has nothing re-checking it. A screensaver, display sleep,
    ; a session lock or a shell window rising above ours can hide or bury it.
    if (Mod(PollTick, 10) = 0)
        WatchPersistent()

    ; --- follow the focused monitor ---
    if (Gcfg["follow"] && Mod(PollTick, 5) = 0) {
        mi := ActiveMonitorIndex()
        if (mi != FollowMon) {
            FollowMon := mi
            for k in Keys {
                if St[k]["shown"] {
                    EffectivePos(k, &px, &py)
                    try St[k]["gui"].Move(px, py)
                }
            }
            LayoutVisible()
        }
    }

    for k in Keys {
        if !Cfg[k]["enabled"] {
            if St[k]["shown"]
                HideNow(k)
            continue
        }
        on := ReadLockState(k)

        if (on = St[k]["last"])
            continue
        St[k]["last"] := on
        PlayCue(on ? Cfg[k]["soundOn"] : Cfg[k]["soundOff"])

        if (!on && (Cfg[k]["mode"] = "persistent" || !Cfg[k]["notifyOff"])) {
            if St[k]["shown"]
                BeginFade(k, -1)
            continue
        }
        ShowBadge(k, on)
    }
}

WatchPersistent() {
    global Cfg, Keys, St, PollTick
    for k in Keys {
        if (!Cfg[k]["enabled"] || Cfg[k]["mode"] != "persistent")
            continue
        if (!St[k]["last"])
            continue
        if (!IsObject(St[k]["gui"])) {
            ShowBadge(k, 1)
            continue
        }
        visible := false
        try visible := DllCall("IsWindowVisible", "ptr", St[k]["gui"].Hwnd)
        if (!visible) {
            ShowBadge(k, 1)
            continue
        }
        ; Taskbar and shell are topmost too; re-assert so they cannot bury it.
        if (Mod(PollTick, 20) = 0)
            try WinSetAlwaysOnTop(1, St[k]["gui"])
    }
}

TestAll() {    global Keys, Cfg
    for k in Keys {
        if Cfg[k]["enabled"]
            ShowBadge(k, 1)
    }
}

; =====================================================================
;  DRAG TO PLACE (on the desktop)
; =====================================================================
EnterDrag(k) {
    global Cfg, Gcfg, St, Keys, DragMode, DragKey, KeyNice
    DragMode := true
    DragKey := k
    ; Other badges stay up as click-through reference points, so you can line
    ; one up against its neighbors instead of guessing.
    if (Gcfg["previewAll"]) {
        for other in Keys {
            if (other != k && Cfg[other]["enabled"])
                ShowStatic(other)
        }
    }
    StopTimers(k)
    BuildBadge(k, 1)
    St[k]["gui"].Opt("-E0x20")     ; temporarily accept clicks so it can move
    St[k]["gui"].Show("NoActivate")
    St[k]["shown"] := true
    ApplyAlpha(k, SafeNum(Cfg[k]["alpha"], 20, 255, 205))
    msg := "Drag the " KeyNice[k] " badge, then click `"Done placing`"."
    if (StackMode() != "Off" && k != "Caps")
        msg .= "`nStacking is on, so only the Caps Lock position is used"
             . " as`nthe anchor - this badge will snap back into the row."
    ToolTip(msg)
    SetTimer(() => ToolTip(), -6000)
}

ExitDrag() {
    global Cfg, Ctl, St, DragMode, DragKey, PreviewMode
    if !DragMode
        return
    k := DragKey
    try {
        WinGetPos(&px, &py, , , St[k]["gui"])
        Cfg[k]["x"] := px
        Cfg[k]["y"] := py
        if (Ctl.Has(k) && Ctl[k].Has("x")) {
            Ctl[k]["x"].Value := px
            Ctl[k]["y"].Value := py
        }
        St[k]["gui"].Opt("+E0x20")
    }
    DragMode := false
    DragKey := ""
    ToolTip()
    if (PreviewMode)
        ShowLive()
    else
        HideNow(k)
}

OnLButtonDown(wParam, lParam, msg, hwnd) {
    global St, Ctl, DragMode, DragKey, SG
    ; --- resize handle / preview badge in the settings panel ---
    if (Ctl.Has("grip") && IsObject(SG)) {
        try {
            target := hwnd
            if (hwnd = SG.Hwnd) {
                MouseGetPos(, , , &underHwnd, 2)
                target := underHwnd
            }
            if (target = Ctl["grip"].Hwnd || target = Ctl["pvOn"].Hwnd) {
                StartResize()
                return
            }
        }
    }
    if (!DragMode || DragKey = "")
        return
    try {
        g := St[DragKey]["gui"]
        if (hwnd = g.Hwnd || hwnd = St[DragKey]["txt"].Hwnd)
            PostMessage(0xA1, 2, , , "ahk_id " g.Hwnd)   ; fake title-bar drag
    }
}

; =====================================================================
;  DRAG TO RESIZE (in the preview panel)
;  A timer, not a while-loop: blocking inside a message handler stalls the
;  dialog's own message pump.
; =====================================================================
StartResize() {
    global Ctl, Resizing, RszX, RszY, RszW, RszH
    if (Resizing)
        return
    k := ActiveKey()
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    RszX := mx
    RszY := my
    RszW := SafeNum(Ctl[k]["w"].Value, 20, 2000, 96)
    RszH := SafeNum(Ctl[k]["h"].Value, 12, 600, 30)
    Resizing := true
    SetTimer(ResizeStep, 15)
}

ResizeStep() {
    global Ctl, Resizing, RszX, RszY, RszW, RszH
    if (!GetKeyState("LButton", "P")) {
        SetTimer(ResizeStep, 0)
        Resizing := false
        ApplyLive()
        return
    }
    k := ActiveKey()
    CoordMode "Mouse", "Screen"          ; timers get their own settings
    MouseGetPos(&mx, &my)
    nw := SafeNum(RszW + (mx - RszX), 30, 600, 96)
    nh := SafeNum(RszH + (my - RszY), 16, 220, 30)
    Ctl[k]["w"].Value := nw
    Ctl[k]["h"].Value := nh
    if (Ctl[k]["scaleFont"].Value)
        Ctl[k]["fontSize"].Value := SafeNum(Round(nh * 0.42), 6, 72, 11)
    ApplyFromSettings()
    UpdatePreview()
}

ApplyPreset(k, name, *) {
    global Ctl, Presets
    p := Presets[name]
    Ctl[k]["w"].Value := p[1]
    Ctl[k]["h"].Value := p[2]
    Ctl[k]["fontSize"].Value := p[3]
    ApplyLive()
}

ActiveKey() {
    global Ctl, Keys, LastKeyTab
    try {
        v := Ctl["tab"].Value
        if (v >= 1 && v <= Keys.Length)
            LastKeyTab := Keys[v]
    }
    return LastKeyTab
}

; =====================================================================
;  SETTINGS WINDOW
; =====================================================================
ShowSettings() {
    global Cfg, Gcfg, Ctl, SG, LinkPath, Keys, KeyNice, PreviewMode
    global BackdropNames, PVX, PVY_ON, PVY_OFF, CANVAS_W, CAP_H_ON, CAP_H_OFF
    global APP_NAME, APP_VER, APP_AUTHOR, APP_REPO, APP_LICENSE
    if IsObject(SG) {
        try {
            SG.Show()
            return
        }
    }
    Ctl := Map()
    SG := Gui("+AlwaysOnTop", APP_NAME " " APP_VER " - Settings")
    SG.SetFont("s9", "Segoe UI")
    SG.OnEvent("Close", (*) => CloseSettings())

    ; -Wrap forbids a second row of tabs. A wrapped strip is two rows tall
    ; and silently shifts every page's content up behind it, clipping the
    ; first control. With -Wrap an overflow shows scroll arrows instead and
    ; the page geometry stays put.
    ; Captions shortened and the strip widened so six tabs stay on one row.
    ; -Wrap forbids a second row: a wrapped strip is two rows tall and shifts
    ; every page's content up behind it, clipping the first control.
    Ctl["tab"] := SG.Add("Tab3", "x10 y10 w364 h646 -Wrap"
        , ["Caps", "Num", "Scroll", "Mute", "General", "About"])
    Ctl["tab"].OnEvent("Change", TabChanged)

    for i, k in Keys {
        Ctl["tab"].UseTab(i)
        AddKeyControls(k)
    }

    ; ---------------- General tab ----------------
    Ctl["tab"].UseTab(5)
    SG.Add("Text", "x24 y48 w110", "Preview backdrop")
    Ctl["backdrop"] := SG.Add("DropDownList", "x140 yp-3 w180", BackdropNames)
    Ctl["backdrop"].Text := Gcfg["backdrop"]
    if (Ctl["backdrop"].Value = 0)
        Ctl["backdrop"].Value := 1
    Ctl["backdrop"].OnEvent("Change", Touch)

    SG.Add("Text", "x24 y+16 w110", "Stack badges")
    Ctl["stack"] := SG.Add("DropDownList", "x140 yp-3 w180 Choose"
        . (StackMode() = "Vertical" ? 2 : StackMode() = "Horizontal" ? 3 : 1)
        , ["Off - place each separately", "Vertically (top to bottom)"
         , "Horizontally (left to right)"])
    Ctl["stack"].OnEvent("Change", Touch)
    SG.Add("Text", "x24 y+8 w300 cGray"
        , "Locks lit at the same time queue off the anchor badge instead "
        . "of overlapping. While stacking is on, only the anchor's saved "
        . "position is used - the others are placed for you, in the order "
        . "anchor, Caps, Num, Scroll. Set this to Off to keep the position "
        . "you saved for each badge.")

    SG.Add("Text", "x24 y+14 w110", "Anchor badge")
    Ctl["anchor"] := SG.Add("DropDownList", "x140 yp-3 w180 Choose"
        . KeyIndex(AnchorKey())
        , ["Caps Lock", "Num Lock", "Scroll Lock", "Mute"])
    Ctl["anchor"].OnEvent("Change", Touch)

    SG.Add("Text", "x24 y+14 w110", "Gap between (px)")
    Ctl["gap"] := SG.Add("Edit", "x140 yp-3 w60", Gcfg["gap"])
    Ctl["gap"].OnEvent("Change", Touch)

    Ctl["follow"] := SG.Add("Checkbox", "x24 y+18 w300 Checked" Gcfg["follow"]
        , "Follow the monitor holding the focused window")
    Ctl["follow"].OnEvent("Click", Touch)
    SG.Add("Text", "x42 y+4 w282 cGray"
        , "Leave off to pin every badge to one display.")

    Ctl["hideFullscreen"] := SG.Add("Checkbox", "x24 y+14 w300 Checked"
        . Gcfg["hideFullscreen"], "Hide badges while a fullscreen app is active")
    Ctl["hideFullscreen"].OnEvent("Click", Touch)
    SG.Add("Text", "x42 y+4 w282 cGray"
        , "Keeps the overlay out of games, video and slideshows. State is "
        . "still tracked, so nothing flashes at you on the way out.")

    Ctl["soundInFullscreen"] := SG.Add("Checkbox", "x42 y+8 w282 Checked"
        . Gcfg["soundInFullscreen"], "Still play sound cues while hidden")
    Ctl["soundInFullscreen"].OnEvent("Click", Touch)
    SG.Add("Text", "x60 y+4 w264 cGray"
        , "Recommended: in a full-screen game the badge is hidden, so audio "
        . "is the only way to know a lock changed.")

    Ctl["noCapture"] := SG.Add("Checkbox", "x24 y+14 w300 Checked"
        . Gcfg["noCapture"], "Exclude badges from screen capture")
    Ctl["noCapture"].OnEvent("Click", Touch)
    SG.Add("Text", "x42 y+4 w282 cGray"
        , "Hides the badge from recordings and Teams/Zoom shares. Your own "
        . "screenshots will not show it either, so turn this off while "
        . "documenting the app.")

    Ctl["auto"] := SG.Add("Checkbox", "x24 y+16 w300 Checked"
        . (FileExist(LinkPath) ? 1 : 0), "Start automatically with Windows")
    SG.Add("Text", "x42 y+4 w282 cGray"
        , "Re-tick this after moving or renaming the script - the Startup "
        . "shortcut points at the old path.")

    ; ---------------- About tab ----------------
    Ctl["tab"].UseTab(6)
    SG.SetFont("s11 Bold")
    SG.Add("Text", "x24 y48 w300", APP_NAME)
    SG.SetFont("s9 norm")
    SG.Add("Text", "x24 y+2 w300", APP_VER)
    SG.Add("Text", "x24 y+14 w300", "Created by " APP_AUTHOR)
    SG.Add("Text", "x24 y+6 w300", APP_REPO)
    SG.Add("Text", "x24 y+6 w300", APP_LICENSE)

    SG.Add("Text", "x24 y+16 w300 h1 0x10")
    SG.SetFont("s9 Bold")
    SG.Add("Text", "x24 y+12 w300", "Privacy and security")
    SG.SetFont("s9 norm")
    SG.Add("Text", "x24 y+8 w300"
        , "Reads lock-key state only, via a Windows toggle bit. No "
        . "keyboard hook: keystrokes are never intercepted, buffered or "
        . "read. Nothing inside another process is inspected. No network "
        . "access, no telemetry, no logging.")

    SG.Add("Text", "x24 y+16 w300 h1 0x10")
    SG.SetFont("s9 Bold")
    SG.Add("Text", "x24 y+12 w300", "Files")
    SG.SetFont("s9 norm")
    SG.Add("Text", "x24 y+8 w300"
        , "Settings: %APPDATA%\LockBadges\config.ini`n"
        . "The program folder is never written to.")
    ob := SG.Add("Button", "x24 y+12 w170 h28", "Open config folder")
    ob.OnEvent("Click", (*) => Run(A_AppData "\LockBadges"))

    Ctl["tab"].UseTab(0)

    ; ---------------- bottom buttons, outside the tabs ----------------
    b4 := SG.Add("Button", "x10 y666 w110 h26", "Test this badge")
    b4.OnEvent("Click", (*) => TestFlash())
    b5 := SG.Add("Button", "x126 y666 w110 h26 Default", "Save")
    b5.OnEvent("Click", (*) => DoSave())
    b6 := SG.Add("Button", "x242 y666 w108 h26", "Close")
    b6.OnEvent("Click", (*) => CloseSettings())
    b7 := SG.Add("Button", "x384 y666 w118 h26", "Test all badges")
    b7.OnEvent("Click", (*) => TestAllFlash())
    Ctl["status"] := SG.Add("Text", "x510 y672 w200 cGray", "")

    ; ---------------- right column: live preview ----------------
    SG.Add("GroupBox", "x384 y10 w330 h400", "Preview")
    Ctl["pvWhich"] := SG.Add("Text", "x" PVX " y34 w300", "")
    SG.Add("Text", "x" PVX " y60 w80", "Shown over")
    Ctl["pvBack"] := SG.Add("Text", "x481 y60 w220 cGray", "")

    ; Backdrop panels first, so badge swatches paint on top of them.
    Ctl["canvasOn"] := SG.Add("Text", "x" PVX " y" PVY_ON
        . " w" CANVAS_W " h" CAP_H_ON " Border")
    Ctl["canvasOff"] := SG.Add("Text", "x" PVX " y" PVY_OFF
        . " w" CANVAS_W " h" CAP_H_OFF " Border")
    Ctl["pvOn"] := SG.Add("Text", "x" PVX " y" PVY_ON
        . " w96 h30 Center 0x200 0x100", "")
    Ctl["pvOff"] := SG.Add("Text", "x" PVX " y" PVY_OFF
        . " w96 h30 Center 0x200", "")
    ; 0x100 is SS_NOTIFY. Without it a static control never reports a
    ; click; the message falls through to the parent window instead.
    Ctl["grip"] := SG.Add("Text", "x" (PVX + 98) " y" (PVY_ON + 32)
        . " w15 h15 0x100 Border Background3B9EFF")

    Ctl["pvInfo"] := SG.Add("Text", "x" PVX " y286 w300 h32", "")
    Ctl["previewAll"] := SG.Add("Checkbox", "x" PVX " y320 w300 Checked"
        . Gcfg["previewAll"], "Show every enabled badge while editing")
    Ctl["previewAll"].OnEvent("Click", Touch)
    SG.Add("Text", "x" PVX " y346 w310 cGray"
        , "Drag the blue handle, or anywhere on the ON badge, to resize."
        . "`nColors shown are the true blended result at this opacity."
        . "`nThe real badge on your desktop also updates as you type.")

    PreviewMode := true
    SG.Show()
    ApplyLive()
}

; One identical control set per lock, built into whichever tab is active.
AddKeyControls(k) {
    global SG, Ctl, Cfg, FontList, KeyNice, SoundChoices
    Ctl[k] := Map()
    c := Ctl[k]
    lx := 24        ; label x
    cx := 128       ; control x
    px := 246       ; Pick button x
    y := 44
    step := 26

    c["enabled"] := SG.Add("Checkbox", "x" lx " y" y " w300 Checked"
        . Cfg[k]["enabled"], "Show a badge for " KeyNice[k])
    y += 28

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Text when ON")
    c["labelOn"] := SG.Add("Edit", "x" cx " y" y " w110", Cfg[k]["labelOn"])
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Text when OFF")
    c["labelOff"] := SG.Add("Edit", "x" cx " y" y " w110", Cfg[k]["labelOff"])
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Font")
    c["font"] := SG.Add("ComboBox", "x" cx " y" y " w110", FontList)
    c["font"].Text := SafeFont(Cfg[k]["font"])
    y += step

    c["bold"] := SG.Add("Checkbox", "x" cx " y" y " Checked" Cfg[k]["bold"]
        , "Bold")
    c["italic"] := SG.Add("Checkbox", "x+14 yp Checked" Cfg[k]["italic"]
        , "Italic")
    y += 24

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Font size")
    c["fontSize"] := SG.Add("Edit", "x" cx " y" y " w52", Cfg[k]["fontSize"])
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Box size (W x H)")
    c["w"] := SG.Add("Edit", "x" cx " y" y " w52", Cfg[k]["w"])
    c["h"] := SG.Add("Edit", "x+4 yp w52", Cfg[k]["h"])
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Position (X, Y)")
    c["x"] := SG.Add("Edit", "x" cx " y" y " w52", Cfg[k]["x"])
    c["y"] := SG.Add("Edit", "x+4 yp w52", Cfg[k]["y"])
    y += step + 2

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Background")
    c["bg"] := SG.Add("Edit", "x" cx " y" y " w110", Cfg[k]["bg"])
    pb1 := SG.Add("Button", "x" px " y" (y - 1) " w48 h23", "Pick")
    pb1.OnEvent("Click", PickColor.Bind(k, "bg"))
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Text (ON)")
    c["fgOn"] := SG.Add("Edit", "x" cx " y" y " w110", Cfg[k]["fgOn"])
    pb2 := SG.Add("Button", "x" px " y" (y - 1) " w48 h23", "Pick")
    pb2.OnEvent("Click", PickColor.Bind(k, "fgOn"))
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Text (OFF)")
    c["fgOff"] := SG.Add("Edit", "x" cx " y" y " w110", Cfg[k]["fgOff"])
    pb3 := SG.Add("Button", "x" px " y" (y - 1) " w48 h23", "Pick")
    pb3.OnEvent("Click", PickColor.Bind(k, "fgOff"))
    y += step + 2

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Opacity")
    c["alpha"] := SG.Add("Slider", "x" cx " y" y " w170 Range20-255"
        , SafeNum(Cfg[k]["alpha"], 20, 255, 205))
    y += step + 4

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Flash time (ms)")
    c["duration"] := SG.Add("Edit", "x" cx " y" y " w70", Cfg[k]["duration"])
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Behavior")
    c["mode"] := SG.Add("DropDownList", "x" cx " y" y " w170 Choose"
        . (Cfg[k]["mode"] = "persistent" ? 2 : 1)
        , ["Flash briefly on change", "Stay visible until toggled off"])
    y += step + 4

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Sound when ON")
    c["soundOn"] := SG.Add("DropDownList", "x" cx " y" y " w150 Choose"
        . SoundIndexFromSpec(Cfg[k]["soundOn"]), SoundChoices)
    c["soundOn"].OnEvent("Change", PickSound.Bind(k, "soundOn"))
    pOn := SG.Add("Button", "x282 y" (y - 1) " w48 h23", "Play")
    pOn.OnEvent("Click", (*) => AuditionCue(Cfg[k]["soundOn"]))
    y += step

    SG.Add("Text", "x" lx " y" (y + 4) " w100", "Sound when OFF")
    c["soundOff"] := SG.Add("DropDownList", "x" cx " y" y " w150 Choose"
        . SoundIndexFromSpec(Cfg[k]["soundOff"]), SoundChoices)
    c["soundOff"].OnEvent("Change", PickSound.Bind(k, "soundOff"))
    pOff := SG.Add("Button", "x282 y" (y - 1) " w48 h23", "Play")
    pOff.OnEvent("Click", (*) => AuditionCue(Cfg[k]["soundOff"]))
    y += step + 4

    c["notifyOff"] := SG.Add("Checkbox", "x" lx " y" y " w300 Checked"
        . Cfg[k]["notifyOff"], "Also pop up when this lock turns OFF")
    y += 22
    c["ghost"] := SG.Add("Checkbox", "x" lx " y" y " w300 Checked"
        . Cfg[k]["ghost"], "No box - floating text only (most readable)")
    y += 22
    c["round"] := SG.Add("Checkbox", "x" lx " y" y " w300 Checked"
        . Cfg[k]["round"], "Rounded corners (Windows 11)")
    y += 22
    c["scaleFont"] := SG.Add("Checkbox", "x" lx " y" y " w300 Checked"
        . Cfg[k]["scaleFont"], "Scale font size with the box while resizing")
    y += 28

    SG.Add("Text", "x" lx " y" (y + 5) " w70", "Size presets")
    for name in ["Small", "Medium", "Large", "XL"] {
        wpx := (name = "Medium") ? 62 : (name = "XL") ? 36 : 52
        xopt := (name = "Small") ? "x100 y" y : "x+4 yp"
        pbtn := SG.Add("Button", xopt " w" wpx " h24", name)
        pbtn.OnEvent("Click", ApplyPreset.Bind(k, name))
    }
    y += 30

    c["drag"] := SG.Add("Button", "x" lx " y" y " w100 h26", "Drag to place")
    c["drag"].OnEvent("Click", (*) => (ApplyFromSettings(), EnterDrag(k)))
    d2 := SG.Add("Button", "x+6 yp w100 h26", "Done placing")
    d2.OnEvent("Click", (*) => ExitDrag())
    c["reset"] := SG.Add("Button", "x+6 yp w80 h26", "Reset pos")
    c["reset"].OnEvent("Click", (*) => DoResetPos(k))

    ; live updates
    for kk in ["labelOn", "labelOff", "fontSize", "w", "h", "x", "y"
             , "bg", "fgOn", "fgOff", "duration"]
        c[kk].OnEvent("Change", Touch)
    c["font"].OnEvent("Change", Touch)
    c["mode"].OnEvent("Change", Touch)
    c["alpha"].OnEvent("Change", Touch)
    for kk in ["enabled", "bold", "italic", "notifyOff", "ghost"
             , "round", "scaleFont"]
        c[kk].OnEvent("Click", Touch)
}

; Choosing "Custom WAV file..." opens a picker. Cancelling reverts the
; dropdown rather than silently leaving it on a selection with no file.
PickSound(k, field, ctrl, *) {
    global Cfg
    if (ctrl.Value = 7) {
        f := FileSelect(3, , "Choose a WAV file for " k " " field
                      , "Audio (*.wav; *.mp3)")
        if (f != "")
            Cfg[k][field] := f
        else
            ctrl.Value := SoundIndexFromSpec(Cfg[k][field])
    }
    Touch()
}

Touch(*) {
    global Dirty
    Dirty := true
    SetTimer(ApplyLive, -120)      ; debounce so typing does not thrash
}

; Switching tabs is navigation, not an edit, so it must not set Dirty.
TabChanged(*) {
    SetTimer(ApplyLive, -60)
}

ApplyLive() {
    global PreviewMode, DragMode, Resizing
    ApplyFromSettings()
    UpdatePositionControls()
    UpdatePreview()
    if (PreviewMode && !DragMode && !Resizing)
        ShowLive()
}

; While Settings is open, show the badge for the tab you are editing - and,
; unless asked not to, every other enabled badge alongside it. Placement is
; a relative judgment; you cannot make it against invisible neighbors.
ShowLive() {
    global Cfg, Gcfg, St, Keys
    k := ActiveKey()
    for other in Keys {
        if (other = k)
            continue
        if (Gcfg["previewAll"] && Cfg[other]["enabled"])
            ShowStatic(other)
        else if (St[other]["shown"])
            HideNow(other)
    }
    ShowStatic(k)          ; the edited badge shows even when disabled
    LayoutVisible()
}

; A control that silently does nothing is worse than a missing one: while
; stacking is on, every badge except the anchor has its position computed,
; so those fields and buttons are disabled rather than quietly ignored.
UpdatePositionControls() {
    global Ctl, Keys
    mode := StackMode()
    anchor := AnchorKey()
    for k in Keys {
        if !Ctl.Has(k)
            continue
        free := (mode = "Off" || k = anchor)
        for kk in ["x", "y", "drag", "reset"] {
            try Ctl[k][kk].Enabled := free
        }
        ; Flash time is read only in flash mode; persistent has no timer.
        try Ctl[k]["duration"].Enabled := (Ctl[k]["mode"].Value != 2)
    }
}

; Put a badge on screen at full opacity, with no fade and no auto-hide.
ShowStatic(k) {
    global Cfg, St
    StopTimers(k)
    BuildBadge(k, 1)
    St[k]["gui"].Show("NoActivate")
    St[k]["shown"] := true
    ApplyAlpha(k, SafeNum(Cfg[k]["alpha"], 20, 255, 205))
}

UpdatePreview() {
    global Cfg, Gcfg, Ctl, SG, Backdrops, KeyNice
    global PVX, PVY_ON, PVY_OFF, CANVAS_W, CAP_H_ON, CAP_H_OFF
    if !Ctl.Has("pvOn")
        return
    k := ActiveKey()

    backName := Gcfg["backdrop"]
    back := Backdrops.Has(backName) ? Backdrops[backName] : "FFFFFF"
    alpha := SafeNum(Cfg[k]["alpha"], 20, 255, 205)

    ; In ghost mode the box is fully keyed out, so the box area IS the
    ; backdrop and only the glyphs are composited.
    boxShown := Cfg[k]["ghost"] ? back : Blend(Cfg[k]["bg"], back, alpha)
    onShown := Blend(Cfg[k]["fgOn"], back, alpha)
    offShown := Blend(Cfg[k]["fgOff"], back, alpha)

    fn := SafeFont(Cfg[k]["font"])
    fs := SafeNum(Cfg[k]["fontSize"], 6, 72, 11)
    bw := SafeNum(Cfg[k]["w"], 20, 2000, 96)
    bh := SafeNum(Cfg[k]["h"], 12, 600, 30)
    pw := bw > CANVAS_W ? CANVAS_W : bw
    phOn := bh > CAP_H_ON ? CAP_H_ON : bh
    phOff := bh > CAP_H_OFF ? CAP_H_OFF : bh

    try {
        note := ""
        if (!Cfg[k]["enabled"])
            note := "   (badge disabled)"
        else if (StackMode() != "Off" && k != AnchorKey())
            note := "   (position set by the " KeyNice[AnchorKey()] " anchor)"
        Ctl["pvWhich"].Text := "Editing: " KeyNice[k] note
        Ctl["pvBack"].Text := backName "  -  set on the General tab"

        Ctl["canvasOn"].Opt("+Background" back)
        Ctl["canvasOff"].Opt("+Background" back)

        Ctl["pvOn"].Move(, , pw, phOn)
        Ctl["pvOn"].Opt("+Background" boxShown)
        Ctl["pvOn"].SetFont(FontStyleStr(k, onShown), fn)
        Ctl["pvOn"].Text := Cfg[k]["labelOn"]

        Ctl["pvOff"].Move(, , pw, phOff)
        Ctl["pvOff"].Opt("+Background" boxShown)
        Ctl["pvOff"].SetFont(FontStyleStr(k, offShown), fn)
        Ctl["pvOff"].Text := Cfg[k]["labelOff"]

        Ctl["grip"].Move(PVX + pw + 2, PVY_ON + phOn + 2)

        clipped := (bw > CANVAS_W || bh > CAP_H_ON)
        Ctl["pvInfo"].Text := "Actual box: " bw " x " bh " px    Font: " fn
            . ", " fs " pt`nOpacity " alpha "/255 over " backName
            . (clipped ? "    (preview clipped)" : "")

        DllCall("InvalidateRect", "ptr", SG.Hwnd, "ptr", 0, "int", 1)
    }
}

ApplyFromSettings() {
    global Cfg, Gcfg, Ctl, Keys
    for k in Keys {
        if !Ctl.Has(k)
            continue
        c := Ctl[k]
        for kk in ["labelOn", "labelOff", "w", "h", "x", "y", "fontSize"
                 , "bg", "fgOn", "fgOff", "duration"]
            Cfg[k][kk] := c[kk].Value
        Cfg[k]["font"] := SafeFont(c["font"].Text)
        Cfg[k]["alpha"] := c["alpha"].Value
        Cfg[k]["enabled"] := c["enabled"].Value
        Cfg[k]["bold"] := c["bold"].Value
        Cfg[k]["italic"] := c["italic"].Value
        Cfg[k]["notifyOff"] := c["notifyOff"].Value
        Cfg[k]["ghost"] := c["ghost"].Value
        Cfg[k]["round"] := c["round"].Value
        Cfg[k]["scaleFont"] := c["scaleFont"].Value
        for fld in ["soundOn", "soundOff"] {
            idx := c[fld].Value
            if (idx != 7)                       ; 7 keeps the chosen file path
                Cfg[k][fld] := SpecFromSoundIndex(idx)
            else if (SubStr(Cfg[k][fld], 1, 1) = "*")
                Cfg[k][fld] := ""               ; picker was canceled
        }
        Cfg[k]["mode"] := (c["mode"].Value = 2) ? "persistent" : "flash"
        Cfg[k]["bg"] := SafeHex(Cfg[k]["bg"], "1B1B1B")
        Cfg[k]["fgOn"] := SafeHex(Cfg[k]["fgOn"], "FFC24B")
        Cfg[k]["fgOff"] := SafeHex(Cfg[k]["fgOff"], "8A8A8A")
    }
    if Ctl.Has("backdrop") {
        Gcfg["backdrop"] := Ctl["backdrop"].Text
        sv := Ctl["stack"].Value
        Gcfg["stack"] := (sv = 2) ? "Vertical" : (sv = 3) ? "Horizontal" : "Off"
        Gcfg["gap"] := Ctl["gap"].Value
        Gcfg["follow"] := Ctl["follow"].Value
        Gcfg["hideFullscreen"] := Ctl["hideFullscreen"].Value
        Gcfg["noCapture"] := Ctl["noCapture"].Value
        Gcfg["soundInFullscreen"] := Ctl["soundInFullscreen"].Value
        Gcfg["previewAll"] := Ctl["previewAll"].Value
        Gcfg["anchor"] := Keys[SafeNum(Ctl["anchor"].Value, 1, 3, 1)]
    }
}

DoResetPos(k) {
    global Cfg, Ctl
    ApplyFromSettings()
    ResetPosition(k, KeyIndex(k) - 1)
    Ctl[k]["x"].Value := Cfg[k]["x"]
    Ctl[k]["y"].Value := Cfg[k]["y"]
    ApplyLive()
}

; Briefly leave preview mode so the real fade-in/fade-out can be judged.
TestFlash() {
    global PreviewMode, Cfg
    ApplyFromSettings()
    k := ActiveKey()
    PreviewMode := false
    HideNow(k)
    ShowBadge(k, 1)
    SetTimer(EndTestFlash
           , -(SafeNum(Cfg[k]["duration"], 100, 60000, 900) + 900))
}

; Flash all enabled badges together, so the stack can be judged for real.
TestAllFlash() {
    global PreviewMode, Cfg, Keys
    ApplyFromSettings()
    PreviewMode := false
    for k in Keys
        HideNow(k)
    longest := 900
    for k in Keys {
        if Cfg[k]["enabled"] {
            ShowBadge(k, 1)
            d := SafeNum(Cfg[k]["duration"], 100, 60000, 900)
            if (d > longest)
                longest := d
        }
    }
    SetTimer(EndTestFlash, -(longest + 900))
}

EndTestFlash() {
    global PreviewMode, SG
    if IsObject(SG) {
        PreviewMode := true
        ShowLive()
    }
}

DoSave() {
    global Ctl, Dirty
    ApplyFromSettings()
    SetAutostart(Ctl["auto"].Value)
    SaveCfg()
    Dirty := false
    try Ctl["status"].Text := "Saved at " FormatTime(A_Now, "HH:mm:ss")
        . " - the window stays open, keep tweaking."
    SetTimer(ClearStatus, -6000)
}

ClearStatus() {
    global Ctl
    try Ctl["status"].Text := ""
}

SetAutostart(on) {
    global LinkPath, OldLink
    try {
        if (FileExist(OldLink))       ; clear the pre-rename shortcut
            FileDelete(OldLink)
    }
    try {
        if (on)
            FileCreateShortcut(A_ScriptFullPath, LinkPath, A_ScriptDir)
        else if FileExist(LinkPath)
            FileDelete(LinkPath)
    }
}

CloseSettings(force := false) {
    global SG, Ctl, Cfg, St, Keys, KeyVK, DragMode, PreviewMode, Dirty
    global APP_NAME
    if (Dirty && !force && IsObject(SG)) {
        opt := "YesNo Icon! Owner" SG.Hwnd
        if (MsgBox("You have unsaved changes.`n`nClose without saving?"
                 , APP_NAME, opt) != "Yes")
            return
    }
    if DragMode
        ExitDrag()
    PreviewMode := false
    Dirty := false
    for k in Keys
        HideNow(k)
    try SG.Destroy()
    SG := ""
    Ctl := Map()
    for k in Keys {
        St[k]["last"] := ReadLockState(k)
        if (Cfg[k]["enabled"] && St[k]["last"] && Cfg[k]["mode"] = "persistent")
            ShowBadge(k, 1)
    }
    LayoutVisible()
}

; =====================================================================
;  COLOR PICKER
;  A swatch grid for people, plus the real Windows dialog for precision.
; =====================================================================
PickColor(key, field, *) {
    global Palette
    p := Gui("+AlwaysOnTop +ToolWindow", "Choose a color")
    p.SetFont("s9", "Segoe UI")

    cell := 22
    gap := 3
    row := 0
    for rowColors in Palette {
        col := 0
        for cc in rowColors {
            xx := 12 + col * (cell + gap)
            yy := 12 + row * (cell + gap)
            sw := p.Add("Text", "x" xx " y" yy " w" cell " h" cell
                      . " 0x100 Border Background" cc)
            sw.OnEvent("Click", ApplySwatch.Bind(cc, key, field, p))
            col++
        }
        row++
    }
    gridBottom := 12 + row * (cell + gap) + 6

    more := p.Add("Button", "x12 y" gridBottom " w120 h26", "More colors...")
    more.OnEvent("Click", MoreColors.Bind(key, field, p))
    cancel := p.Add("Button", "x+8 yp w80 h26", "Cancel")
    cancel.OnEvent("Click", (*) => p.Destroy())

    p.Show()
}

ApplySwatch(cc, key, field, p, *) {
    global Ctl
    try Ctl[key][field].Value := cc
    try p.Destroy()
    ApplyLive()
}

MoreColors(key, field, p, *) {
    global Ctl
    init := 0xFFFFFF
    try init := Integer("0x" SafeHex(Ctl[key][field].Value, "FFFFFF"))
    res := ChooseColorDlg(p.Hwnd, SwapRB(init))
    if (res != "") {
        try Ctl[key][field].Value := Format("{:06X}", SwapRB(res))
        try p.Destroy()
        ApplyLive()
    }
}

; Windows COLORREF is 0x00BBGGRR; hex colors are RRGGBB. Same swap both ways.
SwapRB(v) {
    return ((v & 0xFF) << 16) | (v & 0xFF00) | ((v >> 16) & 0xFF)
}

; The native CHOOSECOLOR dialog. Returns a COLORREF, or "" if canceled.
ChooseColorDlg(ownerHwnd, initBgr) {
    static custom := Buffer(64, 0)          ; 16 custom-color slots, persists
    size := (A_PtrSize = 8) ? 72 : 36
    rgbOff := (A_PtrSize = 8) ? 24 : 12
    cc := Buffer(size, 0)
    NumPut("uint", size, cc, 0)
    NumPut("ptr", ownerHwnd, cc, (A_PtrSize = 8) ? 8 : 4)
    NumPut("uint", initBgr, cc, rgbOff)
    NumPut("ptr", custom.Ptr, cc, (A_PtrSize = 8) ? 32 : 16)
    ; CC_RGBINIT (0x1) | CC_FULLOPEN (0x2)
    NumPut("uint", 0x3, cc, (A_PtrSize = 8) ? 40 : 20)
    if !DllCall("comdlg32\ChooseColorW", "ptr", cc, "uint")
        return ""
    return NumGet(cc, rgbOff, "uint")
}
