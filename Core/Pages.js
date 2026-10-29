.pragma library

// Sidebar entries, in display order. `source` is relative to Settings.qml.
// `icon` is a Nerd Font codepoint (the shell font is a Nerd Font).
// `keywords` feed the sidebar search.
var pages = [
  { id: "displays",   title: "Displays",        icon: 0xF0379, source: "pages/DisplaysPage.qml",
    keywords: "monitor screen resolution refresh rate hz scale rotation arrange mirror vrr external" },
  { id: "sound",      title: "Sound",           icon: 0xF057E, source: "pages/SoundPage.qml",
    keywords: "audio volume speaker headphones microphone input output pipewire" },
  { id: "network",    title: "Network",         icon: 0xF05A9, source: "pages/NetworkPage.qml",
    keywords: "wifi wlan internet ethernet dns vpn tailscale hotspot" },
  { id: "bluetooth",  title: "Bluetooth",       icon: 0xF00AF, source: "pages/BluetoothPage.qml",
    keywords: "devices pair headphones mouse keyboard" },
  { id: "appearance", title: "Appearance",      icon: 0xF03D8, source: "pages/AppearancePage.qml",
    keywords: "theme wallpaper background font text size gaps border rounding blur animations night light" },
  { id: "input",      title: "Keyboard & Mouse", icon: 0xF030C, source: "pages/InputPage.qml",
    keywords: "keyboard layout repeat mouse touchpad scroll sensitivity natural tap" },
  { id: "shortcuts",  title: "Shortcuts",       icon: 0xF0633, source: "pages/ShortcutsPage.qml",
    keywords: "keybindings hotkeys bind keys" },
  { id: "power",      title: "Power & Lock",    icon: 0xF0084, source: "pages/PowerPage.qml",
    keywords: "battery power profile idle lock screensaver suspend hibernate sleep" },
  { id: "apps",       title: "Default Apps",    icon: 0xF003B, source: "pages/AppsPage.qml",
    keywords: "browser editor terminal agent default applications" },
  { id: "system",     title: "System",          icon: 0xF02FC, source: "pages/SystemPage.qml",
    keywords: "about version update timezone hostname snapshots channel firmware info" }
]

function find(id) {
  for (var i = 0; i < pages.length; i++) if (pages[i].id === id) return pages[i]
  return null
}

function glyph(page) {
  return page && page.icon ? String.fromCodePoint(page.icon) : ""
}

function matches(page, query) {
  var q = String(query || "").trim().toLowerCase()
  if (!q) return true
  var hay = (page.title + " " + page.keywords).toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) === -1) return false
  return true
}
