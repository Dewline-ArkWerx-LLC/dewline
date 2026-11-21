# dmgbuild settings for Dewline's disk image: the app on the left, Applications on the right, the art behind them.
#   dmgbuild -s scripts/dmg/settings.py -D app=<Dewline.app> -D bg=scripts/dmg/background.png Dewline <out.dmg>
# dmgbuild folds background@2x.png, beside the file bg names, into one two-size TIFF.
import os.path

app = defines['app']
files = [app]
symlinks = {'Applications': '/Applications'}
format = 'ULMO'
filesystem = 'APFS'
icon = os.path.join(app, 'Contents/Resources/AppIcon.icns')
background = defines['bg']
window_rect = ((200, 120), (660, 400))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
# The dot files sit below the window, so Finder showing hidden files does not drop them on the layout.
icon_locations = {
    os.path.basename(app): (180, 170),
    'Applications': (480, 170),
    '.background.tiff': (180, 560),
    '.VolumeIcon.icns': (480, 560),
}
