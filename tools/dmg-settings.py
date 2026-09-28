# dmgbuild settings for Kitesail's drag-to-install disk image.
# Used by make-dmg.sh:  dmgbuild -s tools/dmg-settings.py -D app=build/Kitesail.app "Kitesail" out.dmg
import os.path

app = defines.get("app", "build/Kitesail.app")  # noqa: F821 (injected by dmgbuild)
appname = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "build/AppIcon.icns"              # volume icon on the desktop
background = "build/dmg-bg.tiff"         # 1x + 2x, drawn by tools/make-dmg-background.swift

window_rect = ((200, 140), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {appname: (180, 190), "Applications": (480, 190)}   # either side of the arrow
